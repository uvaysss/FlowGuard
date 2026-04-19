import Foundation
import NetworkExtension

final class TunnelRuntimeStartupService {
    private let byedpiEngine: ByeDPIEngine
    private let dataPlaneFactory: (TunnelImplementationMode) -> TunnelDataPlane
    private let networkSettingsBuilder: TunnelNetworkSettingsBuilding
    private let portAllocator: LocalhostPortAllocating
    private let socksEndpointMonitor: LocalSocksEndpointMonitoring
    private let runtimeStateStore: TunnelRuntimeStateStoring
    private let lifecycleService: TunnelRuntimeLifecycleService
    private let persistenceService: TunnelRuntimePersisting

    init(
        byedpiEngine: ByeDPIEngine,
        dataPlaneFactory: @escaping (TunnelImplementationMode) -> TunnelDataPlane,
        networkSettingsBuilder: TunnelNetworkSettingsBuilding,
        portAllocator: LocalhostPortAllocating,
        socksEndpointMonitor: LocalSocksEndpointMonitoring,
        runtimeStateStore: TunnelRuntimeStateStoring,
        lifecycleService: TunnelRuntimeLifecycleService,
        persistenceService: TunnelRuntimePersisting
    ) {
        self.byedpiEngine = byedpiEngine
        self.dataPlaneFactory = dataPlaneFactory
        self.networkSettingsBuilder = networkSettingsBuilder
        self.portAllocator = portAllocator
        self.socksEndpointMonitor = socksEndpointMonitor
        self.runtimeStateStore = runtimeStateStore
        self.lifecycleService = lifecycleService
        self.persistenceService = persistenceService
    }

    func start(
        profile: TunnelProfile,
        implementationMode: TunnelImplementationMode,
        packetFlow: NEPacketTunnelFlow? = nil,
        applyNetworkSettingsHandler: @escaping (NEPacketTunnelNetworkSettings) async -> Bool
    ) async throws {
        prepareStartupState(profile: profile, implementationMode: implementationMode)

        var didStartByeDPI = false
        var didStartDataPlane = false

        do {
            let effectiveProfile = try resolveEffectiveProfile(from: profile)
            try await applyNetworkSettings(for: effectiveProfile, using: applyNetworkSettingsHandler)

            let byedpiExitTracker = ByeDPIExitTracker()
            try startByeDPI(profile: effectiveProfile, exitTracker: byedpiExitTracker)
            didStartByeDPI = true

            try waitForSocksReadiness(profile: effectiveProfile, exitTracker: byedpiExitTracker)
            try startDataPlane(
                profile: effectiveProfile,
                implementationMode: implementationMode,
                packetFlow: packetFlow
            )
            didStartDataPlane = true

            finalizeSuccessfulStartup()
        } catch {
            handleStartupFailure(
                error: error,
                didStartByeDPI: didStartByeDPI,
                didStartDataPlane: didStartDataPlane
            )
            throw error
        }
    }

    private func prepareStartupState(profile: TunnelProfile, implementationMode: TunnelImplementationMode) {
        runtimeStateStore.updateState {
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
            $0.isDataPlaneRunning = false
            $0.implementationMode = implementationMode
        }
        runtimeStateStore.setActiveDataPlane(nil)
    }

    private func resolveEffectiveProfile(from profile: TunnelProfile) throws -> TunnelProfile {
        guard let selectedPort = portAllocator.resolveAvailablePort(preferred: profile.socksPort, scanWindow: 32) else {
            throw TunnelRuntimeError.socksPortInUse(profile.socksPort)
        }

        var effectiveProfile = profile
        effectiveProfile.socksPort = selectedPort
        runtimeStateStore.updateState { $0.activeProfile = effectiveProfile }

        if selectedPort != profile.socksPort {
            appendLogBestEffort("SOCKS port 127.0.0.1:\(profile.socksPort) is busy, switched to \(selectedPort)")
        }

        return effectiveProfile
    }

    private func applyNetworkSettings(
        for profile: TunnelProfile,
        using applyNetworkSettings: @escaping (NEPacketTunnelNetworkSettings) async -> Bool
    ) async throws {
        let settings = networkSettingsBuilder.makeNetworkSettings(profile: profile)
        let settingsApplied = await applyNetworkSettings(settings)
        guard settingsApplied else {
            throw TunnelRuntimeError.networkSettingsFailed
        }
        appendLogBestEffort("Tunnel network settings applied")
    }

    private func startByeDPI(profile: TunnelProfile, exitTracker: ByeDPIExitTracker) throws {
        if profile.byedpiArguments.isEmpty {
            appendLogBestEffort("ByeDPI args: <none>")
        } else {
            appendLogBestEffort("ByeDPI args: \(profile.byedpiArguments.joined(separator: " "))")
        }

        try byedpiEngine.start(arguments: profile.byedpiArguments, socksPort: profile.socksPort) { [weak self] exitCode in
            exitTracker.record(exitCode: exitCode)
            self?.lifecycleService.handleEngineExit(
                engineName: "ByeDPI",
                exitCode: exitCode,
                keyPath: \.isByeDPIRunning
            )
        }

        runtimeStateStore.updateState { $0.isByeDPIRunning = true }
        appendLogBestEffort("ByeDPI started on 127.0.0.1:\(profile.socksPort)")
    }

    private func waitForSocksReadiness(profile: TunnelProfile, exitTracker: ByeDPIExitTracker) throws {
        let socksReady = socksEndpointMonitor.waitUntilReady(
            port: profile.socksPort,
            attempts: 30,
            delayMicroseconds: 100_000
        ) {
            exitTracker.exitCode()
        }

        switch socksReady {
        case .ready:
            appendLogBestEffort("Local SOCKS endpoint is reachable")
        case let .exited(code):
            throw TunnelRuntimeError.byeDPIExited(code)
        case .timeout:
            throw TunnelRuntimeError.socksEndpointUnavailable(profile.socksPort)
        }
    }

    private func startDataPlane(
        profile: TunnelProfile,
        implementationMode: TunnelImplementationMode,
        packetFlow: NEPacketTunnelFlow?
    ) throws {
        let dataPlane = makeDataPlane(mode: implementationMode)
        let startResult = try dataPlane.start(
            profile: profile,
            packetFlow: packetFlow,
            onExit: { [weak self] exitCode in
                self?.lifecycleService.handleEngineExit(
                    engineName: "packet-flow data plane",
                    exitCode: exitCode,
                    keyPath: \.isDataPlaneRunning
                )
            },
            log: { [weak self] line in
                self?.appendLogBestEffort(line)
            }
        )

        runtimeStateStore.setActiveDataPlane(dataPlane)
        runtimeStateStore.updateState {
            $0.tunInterfaceName = startResult.tunInterfaceName
            $0.baselineBytesIn = startResult.baselineBytesIn
            $0.baselineBytesOut = startResult.baselineBytesOut
            $0.isDataPlaneRunning = true
        }
    }

    private func finalizeSuccessfulStartup() {
        runtimeStateStore.updateState {
            $0.startedAt = Date()
            $0.providerState = .running
        }
        persistSnapshotBestEffort()
    }

    private func handleStartupFailure(error: Error, didStartByeDPI: Bool, didStartDataPlane: Bool) {
        runtimeStateStore.updateState {
            $0.runtimeStats.lastError = error.localizedDescription
            $0.providerState = .failed
            $0.startedAt = nil
            $0.tunInterfaceName = nil
            $0.baselineBytesIn = 0
            $0.baselineBytesOut = 0
        }
        persistSnapshotBestEffort()
        appendLogBestEffort("Startup failed: \(error.localizedDescription)")
        lifecycleService.rollbackStartup(didStartByeDPI: didStartByeDPI, didStartDataPlane: didStartDataPlane)
    }

    private func makeDataPlane(mode: TunnelImplementationMode) -> TunnelDataPlane {
        appendLogBestEffort("Tunnel implementation mode: \(mode.rawValue)")
        return dataPlaneFactory(mode)
    }

    private func appendLogBestEffort(_ line: String) {
        persistenceService.appendLog(line)
    }

    private func persistSnapshotBestEffort() {
        let snapshot = runtimeStateStore.makePersistentSnapshot(now: Date())
        persistenceService.persistSnapshot(state: snapshot.state, stats: snapshot.stats)
    }
}

private final class ByeDPIExitTracker {
    private let lock = NSLock()
    private var storedExitCode: Int32?

    func record(exitCode: Int32) {
        lock.lock()
        storedExitCode = exitCode
        lock.unlock()
    }

    func exitCode() -> Int32? {
        lock.lock()
        defer { lock.unlock() }
        return storedExitCode
    }
}
