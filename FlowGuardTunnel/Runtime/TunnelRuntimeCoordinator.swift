import Foundation
import NetworkExtension
import OSLog

enum TunnelRuntimeError: LocalizedError {
    case invalidTunnelDescriptor
    case networkSettingsFailed
    case socksEndpointUnavailable(Int)
    case socksPortInUse(Int)
    case byeDPIExited(Int32)

    var errorDescription: String? {
        switch self {
        case .invalidTunnelDescriptor:
            return "The tunnel interface file descriptor is invalid."
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
    private let logger = Logger(subsystem: "com.uvays.FlowGuard", category: "TunnelRuntime")
    private let byedpiEngine: ByeDPIEngine
    private let tun2socksEngine: Tun2SocksEngine

    private(set) var providerState: ProviderState = .disconnected
    private var runtimeStats: RuntimeStats = .empty
    private var startedAt: Date?
    private var activeProfile: TunnelProfile = .default
    private var tunInterfaceName: String?
    private var baselineBytesIn: UInt64 = 0
    private var baselineBytesOut: UInt64 = 0

    init(
        byedpiEngine: ByeDPIEngine = NativeByeDPIEngine(),
        tun2socksEngine: Tun2SocksEngine = NativeTun2SocksEngine()
    ) {
        self.byedpiEngine = byedpiEngine
        self.tun2socksEngine = tun2socksEngine
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
        resolveTunFileDescriptor: () throws -> Int32,
        applyNetworkSettings: @escaping (NEPacketTunnelNetworkSettings) async -> Bool
    ) async throws {
        setState(.starting)
        runtimeStats = RuntimeStats(
            uptimeSeconds: 0,
            bytesIn: 0,
            bytesOut: 0,
            selectedPreset: profile.preset,
            lastError: nil
        )

        do {
            guard let selectedPort = resolveAvailableSocksPort(preferred: profile.socksPort) else {
                throw TunnelRuntimeError.socksPortInUse(profile.socksPort)
            }
            var effectiveProfile = profile
            effectiveProfile.socksPort = selectedPort
            activeProfile = effectiveProfile
            if selectedPort != profile.socksPort {
                try appendLog("SOCKS port 127.0.0.1:\(profile.socksPort) is busy, switched to \(selectedPort)")
            }

            let settingsApplied = await applyNetworkSettings(makeNetworkSettings(profile: effectiveProfile))
            guard settingsApplied else {
                throw TunnelRuntimeError.networkSettingsFailed
            }
            try appendLog("Tunnel network settings applied")

            let byedpiExitLock = NSLock()
            var byedpiExitCode: Int32?
            if effectiveProfile.byedpiArguments.isEmpty {
                try appendLog("ByeDPI args: <none>")
            } else {
                try appendLog("ByeDPI args: \(effectiveProfile.byedpiArguments.joined(separator: " "))")
            }
            try byedpiEngine.start(arguments: effectiveProfile.byedpiArguments, socksPort: effectiveProfile.socksPort) { [weak self] exitCode in
                byedpiExitLock.lock()
                byedpiExitCode = exitCode
                byedpiExitLock.unlock()
                guard let self else { return }
                Task {
                    try? self.appendLog("ByeDPI exited with code \(exitCode)")
                }
            }
            try appendLog("ByeDPI started on 127.0.0.1:\(effectiveProfile.socksPort)")
            let socksReady = waitForLocalSocks(port: effectiveProfile.socksPort) {
                byedpiExitLock.lock()
                let code = byedpiExitCode
                byedpiExitLock.unlock()
                return code
            }
            switch socksReady {
            case .ready:
                break
            case let .exited(code):
                throw TunnelRuntimeError.byeDPIExited(code)
            case .timeout:
                throw TunnelRuntimeError.socksEndpointUnavailable(effectiveProfile.socksPort)
            }
            try appendLog("Local SOCKS endpoint is reachable")

            let tunFD = try resolveTunFileDescriptor()
            guard tunFD >= 0 else {
                throw TunnelRuntimeError.invalidTunnelDescriptor
            }
            try appendLog("Resolved TUN descriptor: \(tunFD)")
            if let interfaceName = TunFileDescriptorResolver.utunInterfaceName(from: tunFD) {
                tunInterfaceName = interfaceName
                if let counters = TunFileDescriptorResolver.interfaceTrafficCounters(interfaceName: interfaceName) {
                    baselineBytesIn = counters.bytesIn
                    baselineBytesOut = counters.bytesOut
                }
                try appendLog("Resolved TUN interface: \(interfaceName)")
            } else {
                tunInterfaceName = nil
                baselineBytesIn = 0
                baselineBytesOut = 0
                try appendLog("Failed to resolve TUN interface name from descriptor")
            }

            try tun2socksEngine.start(config: effectiveProfile, tunFD: tunFD) { [weak self] exitCode in
                guard let self else { return }
                Task {
                    try? self.appendLog("tun2socks exited with code \(exitCode)")
                }
            }
            try appendLog("tun2socks started")

            startedAt = Date()
            setState(.running)
            persistSnapshot()
        } catch {
            runtimeStats.lastError = error.localizedDescription
            setState(.failed)
            persistSnapshot()
            try? appendLog("Startup failed: \(error.localizedDescription)")
            rollbackStartup()
            throw error
        }
    }

    func stop() {
        setState(.stopping)
        persistSnapshot()

        do {
            try tun2socksEngine.stop()
            try appendLog("tun2socks stopped")
        } catch {
            runtimeStats.lastError = error.localizedDescription
            logger.error("tun2socks stop failed: \(error.localizedDescription, privacy: .public)")
            try? appendLog("tun2socks stop failed: \(error.localizedDescription)")
        }

        do {
            try byedpiEngine.stop()
            try appendLog("ByeDPI stopped")
        } catch {
            runtimeStats.lastError = error.localizedDescription
            logger.error("ByeDPI stop failed: \(error.localizedDescription, privacy: .public)")
            byedpiEngine.forceStop()
            try? appendLog("ByeDPI force-stopped after error")
        }

        startedAt = nil
        tunInterfaceName = nil
        baselineBytesIn = 0
        baselineBytesOut = 0
        runtimeStats.uptimeSeconds = 0
        setState(.disconnected)
        persistSnapshot()
    }

    func handle(_ command: ProviderCommand) -> ProviderMessage {
        switch command.action {
        case .reloadProfile:
            do {
                activeProfile = try AppGroupPaths.read(TunnelProfile.self, from: try AppGroupPaths.profileURL())
                runtimeStats.selectedPreset = activeProfile.preset
                persistSnapshot()
                try appendLog("Profile reloaded: \(activeProfile.preset.rawValue)")
                return .ok("Profile reloaded")
            } catch {
                runtimeStats.lastError = error.localizedDescription
                persistSnapshot()
                return .error("reloadProfile failed: \(error.localizedDescription)")
            }

        case .collectStats:
            var snapshot = runtimeStats
            if let startedAt {
                snapshot.uptimeSeconds = Date().timeIntervalSince(startedAt)
            }
            if let interfaceName = tunInterfaceName,
               let counters = TunFileDescriptorResolver.interfaceTrafficCounters(interfaceName: interfaceName) {
                let deltaIn = counters.bytesIn >= baselineBytesIn ? counters.bytesIn - baselineBytesIn : 0
                let deltaOut = counters.bytesOut >= baselineBytesOut ? counters.bytesOut - baselineBytesOut : 0
                snapshot.bytesIn = Int64(deltaIn)
                snapshot.bytesOut = Int64(deltaOut)
                runtimeStats.bytesIn = snapshot.bytesIn
                runtimeStats.bytesOut = snapshot.bytesOut
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
                logs: AppGroupPaths.readLogPreview()
            )
        }
    }

    private func rollbackStartup() {
        do {
            try tun2socksEngine.stop()
        } catch {
            logger.error("Rollback tun2socks stop failed: \(error.localizedDescription, privacy: .public)")
        }

        do {
            try byedpiEngine.stop()
        } catch {
            byedpiEngine.forceStop()
        }
    }

    private func setState(_ newState: ProviderState) {
        providerState = newState
    }

    private func persistSnapshot() {
        var snapshot = runtimeStats
        if let startedAt {
            snapshot.uptimeSeconds = Date().timeIntervalSince(startedAt)
        }
        AppGroupPaths.persistState(providerState, stats: snapshot)
    }

    private func appendLog(_ line: String) throws {
        try AppGroupPaths.appendLog(line)
    }

    private enum LocalSocksReadiness {
        case ready
        case timeout
        case exited(Int32)
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
