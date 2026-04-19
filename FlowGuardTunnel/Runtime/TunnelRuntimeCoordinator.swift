import Foundation
import NetworkExtension
import OSLog

enum TunnelRuntimeError: LocalizedError {
    case networkSettingsFailed
    case socksEndpointUnavailable(Int)
    case socksPortInUse(Int)
    case byeDPIExited(Int32)

    var errorDescription: String? {
        switch self {
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
    private let runtimeStateStore: TunnelRuntimeStateStoring
    private let startupService: TunnelRuntimeStartupService
    private let lifecycleService: TunnelRuntimeLifecycleService
    private let commandHandlerService: TunnelRuntimeCommandHandlerService
    private let persistenceService: TunnelRuntimePersisting

    init(
        byedpiEngine: ByeDPIEngine = NativeByeDPIEngine(),
        dataPlaneFactory: @escaping (TunnelImplementationMode) -> TunnelDataPlane = { _ in
            PacketFlowDataPlane(mode: .packetFlowPreferred)
        },
        networkSettingsBuilder: TunnelNetworkSettingsBuilding = DefaultTunnelNetworkSettingsBuilder(),
        portAllocator: LocalhostPortAllocating = DefaultLocalhostPortAllocator(),
        socksEndpointMonitor: LocalSocksEndpointMonitoring = DefaultLocalSocksEndpointMonitor(),
        configurationStore: TunnelConfigurationStore = AppGroupPaths.makeTunnelConfigurationStore(),
        snapshotStore: RuntimeSnapshotStore = AppGroupPaths.makeRuntimeSnapshotStore(),
        logStore: RuntimeLogStore = AppGroupPaths.makeRuntimeLogStore(),
        runtimeStateStore: TunnelRuntimeStateStoring = TunnelRuntimeStateRepository(),
        persistenceService: TunnelRuntimePersisting? = nil
    ) {
        self.runtimeStateStore = runtimeStateStore
        let runtimeStatsService = TunnelRuntimeStatsService(runtimeStateStore: runtimeStateStore)
        let logger = Logger(subsystem: "com.uvays.FlowGuard", category: "TunnelRuntime")
        self.persistenceService = persistenceService ?? DefaultTunnelRuntimePersistenceService(
            logger: logger,
            configurationStore: configurationStore,
            snapshotStore: snapshotStore,
            logStore: logStore
        )
        self.lifecycleService = TunnelRuntimeLifecycleService(
            logger: logger,
            byedpiEngine: byedpiEngine,
            runtimeStateStore: runtimeStateStore,
            persistenceService: self.persistenceService
        )
        self.startupService = TunnelRuntimeStartupService(
            byedpiEngine: byedpiEngine,
            dataPlaneFactory: dataPlaneFactory,
            networkSettingsBuilder: networkSettingsBuilder,
            portAllocator: portAllocator,
            socksEndpointMonitor: socksEndpointMonitor,
            runtimeStateStore: runtimeStateStore,
            lifecycleService: self.lifecycleService,
            persistenceService: self.persistenceService
        )
        self.commandHandlerService = TunnelRuntimeCommandHandlerService(
            runtimeStateStore: runtimeStateStore,
            persistenceService: self.persistenceService,
            runtimeStatsService: runtimeStatsService
        )
    }

    var providerState: ProviderState {
        runtimeStateStore.providerState
    }

    func start(
        profile: TunnelProfile,
        implementationMode: TunnelImplementationMode,
        packetFlow: NEPacketTunnelFlow? = nil,
        applyNetworkSettings: @escaping (NEPacketTunnelNetworkSettings) async -> Bool
    ) async throws {
        try await startupService.start(
            profile: profile,
            implementationMode: implementationMode,
            packetFlow: packetFlow,
            applyNetworkSettingsHandler: applyNetworkSettings
        )
    }

    func stop() {
        lifecycleService.stop()
    }

    func handle(_ command: ProviderCommand) -> ProviderMessage {
        switch command.action {
        case .reloadProfile:
            return commandHandlerService.handleReloadProfile()

        case .collectStats:
            return commandHandlerService.handleCollectStats(now: Date())

        case .exportLogs:
            return commandHandlerService.makeExportLogsMessage()
        }
    }
}
