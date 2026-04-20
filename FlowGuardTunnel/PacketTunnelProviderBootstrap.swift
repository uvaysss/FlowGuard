import Foundation
import NetworkExtension
import OSLog

protocol PacketTunnelProviderRuntimeControlling {
    func start(
        options: [String: NSObject]?,
        provider: NEPacketTunnelProvider,
        logger: Logger
    ) async throws
    func stop()
    func handle(_ command: ProviderCommand) -> ProviderMessage
}

enum PacketTunnelProviderFactory {
    static func makeRuntimeController() -> PacketTunnelProviderRuntimeControlling {
        let configurationStore = AppGroupPaths.makeTunnelConfigurationStore()
        let logStore = AppGroupPaths.makeRuntimeLogStore()
        let snapshotStore = AppGroupPaths.makeRuntimeSnapshotStore()

        return DefaultPacketTunnelProviderRuntimeController(
            configurationStore: configurationStore,
            logStore: logStore,
            runtimeCoordinator: TunnelRuntimeCoordinator(
                byedpiEngine: NativeByeDPIEngine(),
                dataPlaneFactory: { mode in
                    switch mode {
                    case .legacyTunFD:
                        return LegacyTunFDDataPlane(mode: mode, tun2socksEngine: NativeTun2SocksEngine())
                    case .packetFlowPreferred:
                        return PacketFlowDataPlane(mode: mode)
                    }
                },
                configurationStore: configurationStore,
                snapshotStore: snapshotStore,
                logStore: logStore
            )
        )
    }
}

private final class DefaultPacketTunnelProviderRuntimeController: PacketTunnelProviderRuntimeControlling {
    private let configurationStore: TunnelConfigurationStore
    private let logStore: RuntimeLogStore
    private let runtimeCoordinator: TunnelRuntimeCoordinator

    init(
        configurationStore: TunnelConfigurationStore,
        logStore: RuntimeLogStore,
        runtimeCoordinator: TunnelRuntimeCoordinator
    ) {
        self.configurationStore = configurationStore
        self.logStore = logStore
        self.runtimeCoordinator = runtimeCoordinator
    }

    func start(
        options: [String: NSObject]?,
        provider: NEPacketTunnelProvider,
        logger: Logger
    ) async throws {
        let baseProfile = try loadProfile(logger: logger)
        let profile = ProviderStartOptions.mergedProfile(from: options, base: baseProfile)
        let implementationMode = TunnelImplementationMode.resolve(fromStartOptions: options)
        logger.info("Selected tunnel implementation mode: \(implementationMode.rawValue, privacy: .public)")

        try await runtimeCoordinator.start(
            profile: profile,
            implementationMode: implementationMode,
            packetFlow: provider.packetFlow,
            applyNetworkSettings: { settings in
                await Self.apply(settings: settings, via: provider, logger: logger)
            }
        )
    }

    func stop() {
        runtimeCoordinator.stop()
    }

    func handle(_ command: ProviderCommand) -> ProviderMessage {
        runtimeCoordinator.handle(command)
    }

    private func loadProfile(logger: Logger) throws -> TunnelProfile {
        do {
            if let loaded = try configurationStore.loadProfile() {
                try? logStore.appendRuntimeLog("Loaded profile from local provider storage")
                return loaded
            }

            let fallback = TunnelProfile.default
            try configurationStore.saveProfile(fallback)
            try? logStore.appendRuntimeLog("Loaded profile from local provider storage")
            return fallback
        } catch let error as SharedStoreError {
            logger.error("Profile load failed: \(error.localizedDescription, privacy: .public)")
            throw error
        } catch {
            logger.error("Profile decode/read failed: \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

    private static func apply(
        settings: NEPacketTunnelNetworkSettings,
        via provider: NEPacketTunnelProvider,
        logger: Logger
    ) async -> Bool {
        await withCheckedContinuation { continuation in
            provider.setTunnelNetworkSettings(settings) { error in
                if let error {
                    logger.error("setTunnelNetworkSettings failed: \(error.localizedDescription, privacy: .public)")
                    continuation.resume(returning: false)
                    return
                }

                continuation.resume(returning: true)
            }
        }
    }
}
