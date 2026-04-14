import Darwin
import Foundation
import NetworkExtension
import OSLog

enum TunnelRuntimeError: LocalizedError {
    case invalidTunnelDescriptor
    case tunnelDescriptorResolutionFailed(String)
    case networkSettingsFailed
    case socksEndpointUnavailable(Int)
    case socksPortInUse(Int)
    case byeDPIExited(Int32)

    var errorDescription: String? {
        switch self {
        case .invalidTunnelDescriptor:
            return "The tunnel interface file descriptor is invalid."
        case let .tunnelDescriptorResolutionFailed(details):
            return "Failed to resolve tunnel interface file descriptor. \(details)"
        case .networkSettingsFailed:
            return "Failed to apply packet tunnel network settings."
        case let .socksEndpointUnavailable(port):
            return "Local SOCKS endpoint did not become ready on 127.0.0.1:\(port)."
        case let .socksPortInUse(port):
            return "SOCKS port 127.0.0.1:\(port) is already in use by another process."
        case let .byeDPIExited(code):
            return "ByeDPI exited during startup with code \(code)."
        }
    }
}

final class TunnelRuntimeCoordinator {
    private static let gracefulStopTimeoutSeconds: TimeInterval = 3
    private static let forcedStopTimeoutSeconds: TimeInterval = 2

    private let logger = Logger(subsystem: "com.uvays.FlowGuard", category: "TunnelRuntime")
    private let byedpiEngine: ByeDPIEngine
    private let dataPlaneFactory: (TunnelImplementationMode) -> TunnelDataPlane
    private let configurationStore: TunnelConfigurationStore
    private let snapshotStore: RuntimeSnapshotStore
    private let logStore: RuntimeLogStore
    private let stateQueue = DispatchQueue(label: "com.uvays.FlowGuard.tunnel-runtime.state")
    private var state = RuntimeState()
    private var activeDataPlane: TunnelDataPlane?

    init(
        byedpiEngine: ByeDPIEngine = NativeByeDPIEngine(),
        dataPlaneFactory: @escaping (TunnelImplementationMode) -> TunnelDataPlane = { mode in
            LegacyTunFDDataPlane(mode: mode, tun2socksEngine: NativeTun2SocksEngine())
        },
        configurationStore: TunnelConfigurationStore = AppGroupPaths.makeTunnelConfigurationStore(),
        snapshotStore: RuntimeSnapshotStore = AppGroupPaths.makeRuntimeSnapshotStore(),
        logStore: RuntimeLogStore = AppGroupPaths.makeRuntimeLogStore()
    ) {
        self.byedpiEngine = byedpiEngine
        self.dataPlaneFactory = dataPlaneFactory
        self.configurationStore = configurationStore
        self.snapshotStore = snapshotStore
        self.logStore = logStore
    }

    var providerState: ProviderState {
        withState { $0.providerState }
    }

    func makeNetworkSettings(profile: TunnelProfile) -> NEPacketTunnelNetworkSettings {
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "254.1.1.1")
        settings.mtu = 9000

        let ipv4 = NEIPv4Settings(addresses: ["198.18.0.1"], subnetMasks: ["255.255.0.0"])
        ipv4.includedRoutes = [NEIPv4Route.default()]
        settings.ipv4Settings = ipv4

        if profile.ipv6Enabled {
            let ipv6 = NEIPv6Settings(addresses: ["fd6e:a81b:704f:1211::1"], networkPrefixLengths: [64])
            ipv6.includedRoutes = [NEIPv6Route.default()]
            settings.ipv6Settings = ipv6
        }

        settings.dnsSettings = NEDNSSettings(servers: profile.dnsServers)
        return settings
    }

    func start(
        profile: TunnelProfile,
        implementationMode: TunnelImplementationMode,
        packetFlow: NEPacketTunnelFlow? = nil,
        resolveTunFileDescriptor: () throws -> Int32,
        applyNetworkSettings: @escaping (NEPacketTunnelNetworkSettings) async -> Bool
    ) async throws {
        let selectedMode = implementationMode
        updateState {
            $0.providerState = .starting
            $0.runtimeStats = RuntimeStats(
                uptimeSeconds: 0,
                bytesIn: 0,
                bytesOut: 0,
                selectedPreset: profile.preset,
                lastError: nil
            )
            $0.startedAt = nil
            $0.tunInterfaceName = nil
            $0.baselineBytesIn = 0
            $0.baselineBytesOut = 0
            $0.isByeDPIRunning = false
            $0.isTun2SocksRunning = false
            $0.implementationMode = selectedMode
        }
        setActiveDataPlane(nil)

        var didStartByeDPI = false
        var didStartDataPlane = false

        do {
            guard let selectedPort = resolveAvailableSocksPort(preferred: profile.socksPort) else {
                throw TunnelRuntimeError.socksPortInUse(profile.socksPort)
            }
            var effectiveProfile = profile
            effectiveProfile.socksPort = selectedPort
            updateState { $0.activeProfile = effectiveProfile }
            if selectedPort != profile.socksPort {
                appendLogBestEffort("SOCKS port 127.0.0.1:\(profile.socksPort) is busy, switched to \(selectedPort)")
            }

            let settingsApplied = await applyNetworkSettings(makeNetworkSettings(profile: effectiveProfile))
            guard settingsApplied else {
                throw TunnelRuntimeError.networkSettingsFailed
            }
            appendLogBestEffort("Tunnel network settings applied")

            let byedpiExitLock = NSLock()
            var byedpiExitCode: Int32?
            if effectiveProfile.byedpiArguments.isEmpty {
                appendLogBestEffort("ByeDPI args: <none>")
            } else {
                appendLogBestEffort("ByeDPI args: \(effectiveProfile.byedpiArguments.joined(separator: " "))")
            }
            try byedpiEngine.start(
                arguments: effectiveProfile.byedpiArguments,
                socksPort: effectiveProfile.socksPort
            ) { [weak self] exitCode in
                byedpiExitLock.lock()
                byedpiExitCode = exitCode
                byedpiExitLock.unlock()
                self?.handleEngineExit(engineName: "ByeDPI", exitCode: exitCode, keyPath: \.isByeDPIRunning)
            }
            didStartByeDPI = true
            updateState { $0.isByeDPIRunning = true }
            appendLogBestEffort("ByeDPI started on 127.0.0.1:\(effectiveProfile.socksPort)")

            let socksReady = waitForLocalSocks(port: effectiveProfile.socksPort) {
                byedpiExitLock.lock()
                defer { byedpiExitLock.unlock() }
                return byedpiExitCode
            }
            switch socksReady {
            case .ready:
                break
            case let .exited(code):
                throw TunnelRuntimeError.byeDPIExited(code)
            case .timeout:
                throw TunnelRuntimeError.socksEndpointUnavailable(effectiveProfile.socksPort)
            }
            appendLogBestEffort("Local SOCKS endpoint is reachable")

            let dataPlane = makeDataPlane(mode: selectedMode)
            let startResult = try dataPlane.start(
                profile: effectiveProfile,
                packetFlow: packetFlow,
                resolveTunFileDescriptor: resolveTunFileDescriptor,
                onExit: { [weak self] exitCode in
                    self?.handleEngineExit(engineName: "tun2socks", exitCode: exitCode, keyPath: \.isTun2SocksRunning)
                },
                log: { [weak self] line in
                    self?.appendLogBestEffort(line)
                }
            )
            setActiveDataPlane(dataPlane)
            didStartDataPlane = true
            updateState {
                $0.tunInterfaceName = startResult.tunInterfaceName
                $0.baselineBytesIn = startResult.baselineBytesIn
                $0.baselineBytesOut = startResult.baselineBytesOut
                $0.isTun2SocksRunning = true
            }

            updateState {
                $0.startedAt = Date()
                $0.providerState = .running
            }
            persistSnapshotBestEffort()
        } catch {
            updateState {
                $0.runtimeStats.lastError = error.localizedDescription
                $0.providerState = .failed
                $0.startedAt = nil
                $0.tunInterfaceName = nil
                $0.baselineBytesIn = 0
                $0.baselineBytesOut = 0
            }
            persistSnapshotBestEffort()
            appendLogBestEffort("Startup failed: \(error.localizedDescription)")
            rollbackStartup(didStartByeDPI: didStartByeDPI, didStartDataPlane: didStartDataPlane)
            throw error
        }
    }

    func stop() {
        let stopTargets = withState { ($0.isTun2SocksRunning, $0.isByeDPIRunning) }
        updateState { $0.providerState = .stopping }
        persistSnapshotBestEffort()

        var stopErrors: [String] = []

        if stopTargets.0 {
            let result = stopDataPlaneWithTimeouts(context: "Stop")
            if let message = result.errorMessage {
                stopErrors.append(message)
            }
            updateState { $0.isTun2SocksRunning = !result.didStop }
        }

        if stopTargets.1 {
            let result = stopByeDPIWithTimeouts(context: "Stop")
            if let message = result.errorMessage {
                stopErrors.append(message)
            }
            updateState { $0.isByeDPIRunning = !result.didStop }
        }

        updateState {
            $0.startedAt = nil
            $0.tunInterfaceName = nil
            $0.baselineBytesIn = 0
            $0.baselineBytesOut = 0
            $0.runtimeStats.uptimeSeconds = 0
            if stopErrors.isEmpty {
                $0.providerState = .disconnected
                $0.runtimeStats.lastError = nil
            } else {
                $0.providerState = .failed
                $0.runtimeStats.lastError = stopErrors.joined(separator: " | ")
            }
        }
        if stopTargets.0 {
            setActiveDataPlane(nil)
        }
        persistSnapshotBestEffort()
    }

    func handle(_ command: ProviderCommand) -> ProviderMessage {
        switch command.action {
        case .reloadProfile:
            do {
                let profile = try configurationStore.loadProfile() ?? .default
                updateState {
                    $0.activeProfile = profile
                    $0.runtimeStats.selectedPreset = profile.preset
                }
                persistSnapshotBestEffort()
                appendLogBestEffort("Profile reloaded: \(profile.preset.rawValue)")
                return .ok("Profile reloaded")
            } catch {
                updateState { $0.runtimeStats.lastError = error.localizedDescription }
                persistSnapshotBestEffort()
                return .error("reloadProfile failed: \(error.localizedDescription)")
            }

        case .collectStats:
            var snapshot = withState { $0.runtimeStats }
            let startedAt = withState { $0.startedAt }
            if let startedAt {
                snapshot.uptimeSeconds = Date().timeIntervalSince(startedAt)
            }
            if let dataPlaneSnapshot = activeDataPlaneSnapshot() {
                snapshot.bytesIn = dataPlaneSnapshot.bytesIn
                snapshot.bytesOut = dataPlaneSnapshot.bytesOut
                snapshot.packetsIn = dataPlaneSnapshot.packetsIn
                snapshot.packetsOut = dataPlaneSnapshot.packetsOut
                snapshot.parseFailures = dataPlaneSnapshot.parseFailures
                snapshot.tcpConnectAttempts = dataPlaneSnapshot.tcpConnectAttempts
                snapshot.tcpConnectFailures = dataPlaneSnapshot.tcpConnectFailures
                snapshot.tcpSendAttempts = dataPlaneSnapshot.tcpSendAttempts
                snapshot.tcpSendFailures = dataPlaneSnapshot.tcpSendFailures
                snapshot.tcpActiveSessions = dataPlaneSnapshot.tcpActiveSessions
                snapshot.udpAssociateAttempts = dataPlaneSnapshot.udpAssociateAttempts
                snapshot.udpAssociateFailures = dataPlaneSnapshot.udpAssociateFailures
                snapshot.udpTxPackets = dataPlaneSnapshot.udpTxPackets
                snapshot.udpRxPackets = dataPlaneSnapshot.udpRxPackets
                snapshot.udpTxFailures = dataPlaneSnapshot.udpTxFailures
                snapshot.udpActiveSessions = dataPlaneSnapshot.udpActiveSessions
                snapshot.dnsRoutedCount = dataPlaneSnapshot.dnsRoutedCount
                updateState {
                    $0.runtimeStats.bytesIn = snapshot.bytesIn
                    $0.runtimeStats.bytesOut = snapshot.bytesOut
                    $0.runtimeStats.packetsIn = snapshot.packetsIn
                    $0.runtimeStats.packetsOut = snapshot.packetsOut
                    $0.runtimeStats.parseFailures = snapshot.parseFailures
                    $0.runtimeStats.tcpConnectAttempts = snapshot.tcpConnectAttempts
                    $0.runtimeStats.tcpConnectFailures = snapshot.tcpConnectFailures
                    $0.runtimeStats.tcpSendAttempts = snapshot.tcpSendAttempts
                    $0.runtimeStats.tcpSendFailures = snapshot.tcpSendFailures
                    $0.runtimeStats.tcpActiveSessions = snapshot.tcpActiveSessions
                    $0.runtimeStats.udpAssociateAttempts = snapshot.udpAssociateAttempts
                    $0.runtimeStats.udpAssociateFailures = snapshot.udpAssociateFailures
                    $0.runtimeStats.udpTxPackets = snapshot.udpTxPackets
                    $0.runtimeStats.udpRxPackets = snapshot.udpRxPackets
                    $0.runtimeStats.udpTxFailures = snapshot.udpTxFailures
                    $0.runtimeStats.udpActiveSessions = snapshot.udpActiveSessions
                    $0.runtimeStats.dnsRoutedCount = snapshot.dnsRoutedCount
                }
            }

            return ProviderMessage(
                kind: .stats,
                description: nil,
                state: providerState,
                stats: snapshot,
                logs: nil
            )

        case .exportLogs:
            return ProviderMessage(
                kind: .logs,
                description: nil,
                state: providerState,
                stats: nil,
                logs: readLogPreviewBestEffort()
            )
        }
    }

    private enum LocalSocksReadiness {
        case ready
        case timeout
        case exited(Int32)
    }

    private struct EngineStopResult {
        let didStop: Bool
        let errorMessage: String?
    }

    private func rollbackStartup(didStartByeDPI: Bool, didStartDataPlane: Bool) {
        if didStartDataPlane {
            let result = stopDataPlaneWithTimeouts(context: "Rollback")
            updateState { $0.isTun2SocksRunning = !result.didStop }
            if result.didStop {
                setActiveDataPlane(nil)
            }
        }

        if didStartByeDPI {
            let result = stopByeDPIWithTimeouts(context: "Rollback")
            updateState { $0.isByeDPIRunning = !result.didStop }
        }
    }

    private func stopDataPlaneWithTimeouts(context: String) -> DataPlaneStopResult {
        guard let dataPlane = currentActiveDataPlane() else {
            return DataPlaneStopResult(didStop: true, errorMessage: nil)
        }
        let mode = dataPlane.mode.rawValue
        let result = dataPlane.stop(
            context: context,
            gracefulTimeout: Self.gracefulStopTimeoutSeconds,
            forcedTimeout: Self.forcedStopTimeoutSeconds,
            log: { [weak self] line in
                self?.appendLogBestEffort(line)
            }
        )
        if !result.didStop {
            logger.error("\(context, privacy: .public) data-plane stop failed mode=\(mode, privacy: .public)")
            appendLogBestEffort("\(context) data-plane stop failed mode=\(mode)")
        }
        return result
    }

    private func stopByeDPIWithTimeouts(context: String) -> EngineStopResult {
        do {
            try byedpiEngine.requestStop()
            let stopped = byedpiEngine.waitForExit(timeout: Self.gracefulStopTimeoutSeconds)
            if stopped {
                appendLogBestEffort("ByeDPI stopped")
                return EngineStopResult(didStop: true, errorMessage: nil)
            }

            appendLogBestEffort("ByeDPI did not stop within \(Int(Self.gracefulStopTimeoutSeconds))s, forcing shutdown")
            byedpiEngine.forceStop()
            let forceStopped = byedpiEngine.waitForExit(timeout: Self.forcedStopTimeoutSeconds)
            if forceStopped {
                appendLogBestEffort("ByeDPI stopped after force-stop")
                return EngineStopResult(didStop: true, errorMessage: nil)
            } else {
                let message = "ByeDPI did not exit after force-stop"
                logger.error("\(context, privacy: .public) ByeDPI stop timeout")
                appendLogBestEffort(message)
                return EngineStopResult(didStop: false, errorMessage: message)
            }
        } catch {
            logger.error("\(context, privacy: .public) ByeDPI stop failed: \(error.localizedDescription, privacy: .public)")
            appendLogBestEffort("ByeDPI stop failed: \(error.localizedDescription)")
            byedpiEngine.forceStop()
            if byedpiEngine.waitForExit(timeout: Self.forcedStopTimeoutSeconds) {
                appendLogBestEffort("ByeDPI force-stopped after error")
                return EngineStopResult(didStop: true, errorMessage: nil)
            } else {
                let message = "ByeDPI did not exit after force-stop following stop error"
                appendLogBestEffort(message)
                return EngineStopResult(didStop: false, errorMessage: message)
            }
        }
    }

    private func handleEngineExit(
        engineName: String,
        exitCode: Int32,
        keyPath: WritableKeyPath<RuntimeState, Bool>
    ) {
        updateState {
            $0[keyPath: keyPath] = false
            if exitCode != 0 {
                $0.runtimeStats.lastError = "\(engineName) exited with code \(exitCode)"
            }
        }
        persistSnapshotBestEffort()
        appendLogBestEffort("\(engineName) exited with code \(exitCode)")
    }

    private func appendLogBestEffort(_ line: String) {
        do {
            try logStore.appendRuntimeLog(line)
        } catch {
            logger.error("Failed to append runtime log: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func readLogPreviewBestEffort(maxBytes: Int = 8_192) -> String {
        do {
            return try logStore.readRuntimeLogPreview(maxBytes: maxBytes)
        } catch {
            logger.error("Failed to read runtime logs: \(error.localizedDescription, privacy: .public)")
            return "No logs yet."
        }
    }

    private func persistSnapshotBestEffort() {
        let snapshot = withState { currentState -> (ProviderState, RuntimeStats) in
            var stats = currentState.runtimeStats
            if let startedAt = currentState.startedAt {
                stats.uptimeSeconds = Date().timeIntervalSince(startedAt)
            }
            return (currentState.providerState, stats)
        }

        do {
            try snapshotStore.persistRuntimeSnapshot(state: snapshot.0, stats: snapshot.1)
        } catch {
            logger.error("Failed to persist runtime snapshot: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func withState<T>(_ block: (RuntimeState) -> T) -> T {
        stateQueue.sync { block(state) }
    }

    private func updateState(_ block: (inout RuntimeState) -> Void) {
        stateQueue.sync { block(&state) }
    }

    private func setActiveDataPlane(_ dataPlane: TunnelDataPlane?) {
        stateQueue.sync { activeDataPlane = dataPlane }
    }

    private func currentActiveDataPlane() -> TunnelDataPlane? {
        stateQueue.sync { activeDataPlane }
    }

    private func activeDataPlaneSnapshot() -> DataPlaneTrafficSnapshot? {
        stateQueue.sync {
            activeDataPlane?.collectTrafficSnapshot()
        }
    }

    private func makeDataPlane(mode: TunnelImplementationMode) -> TunnelDataPlane {
        switch mode {
        case .legacyTunFD:
            appendLogBestEffort("Tunnel implementation mode: \(mode.rawValue)")
            return dataPlaneFactory(.legacyTunFD)
        case .packetFlowExperimental, .packetFlowPreferred:
            appendLogBestEffort("Tunnel implementation mode: \(mode.rawValue)")
            return PacketFlowDataPlane(mode: mode)
        }
    }

    private func waitForLocalSocks(
        port: Int,
        attempts: Int = 30,
        delayMicroseconds: useconds_t = 100_000,
        exitCode: () -> Int32?
    ) -> LocalSocksReadiness {
        for _ in 0..<attempts {
            if let code = exitCode() {
                return .exited(code)
            }
            if canConnectLocalhost(port: port) {
                return .ready
            }
            usleep(delayMicroseconds)
        }
        return .timeout
    }

    private func resolveAvailableSocksPort(preferred: Int, scanWindow: Int = 32) -> Int? {
        guard (1...65535).contains(preferred) else {
            return nil
        }

        let upperBound = min(65535, preferred + scanWindow)
        for port in preferred...upperBound {
            if isPortAvailable(port: port) {
                return port
            }
        }
        return nil
    }

    private func isPortAvailable(port: Int) -> Bool {
        guard !canConnectLocalhost(port: port) else {
            return false
        }
        return canBindLocalhost(port: port)
    }

    private func canConnectLocalhost(port: Int) -> Bool {
        let sock = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard sock >= 0 else {
            return false
        }
        defer { close(sock) }

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port).bigEndian)
        addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

        var socketAddress = sockaddr()
        memcpy(&socketAddress, &addr, MemoryLayout<sockaddr_in>.size)

        let result = withUnsafePointer(to: &socketAddress) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { pointer in
                connect(sock, pointer, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }

        return result == 0
    }

    private func canBindLocalhost(port: Int) -> Bool {
        let sock = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard sock >= 0 else {
            return false
        }
        defer { close(sock) }

        var reuseAddr: Int32 = 1
        _ = setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &reuseAddr, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port).bigEndian)
        addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

        var socketAddress = sockaddr()
        memcpy(&socketAddress, &addr, MemoryLayout<sockaddr_in>.size)

        let result = withUnsafePointer(to: &socketAddress) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { pointer in
                bind(sock, pointer, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }

        return result == 0
    }
}

private struct RuntimeState {
    var providerState: ProviderState = .disconnected
    var runtimeStats: RuntimeStats = .empty
    var startedAt: Date?
    var activeProfile: TunnelProfile = .default
    var implementationMode: TunnelImplementationMode = .legacyTunFD
    var tunInterfaceName: String?
    var baselineBytesIn: UInt64 = 0
    var baselineBytesOut: UInt64 = 0
    var isByeDPIRunning = false
    var isTun2SocksRunning = false
}
