import Foundation
import NetworkExtension
import OSLog

final class PacketTunnelProvider: NEPacketTunnelProvider {
    private let logger = Logger(subsystem: "com.uvays.FlowGuard", category: "PacketTunnel")
    private let configurationStore: TunnelConfigurationStore
    private let logStore: RuntimeLogStore
    private let runtimeCoordinator: TunnelRuntimeCoordinator
    private var profile: TunnelProfile = .default

    override init() {
        self.configurationStore = AppGroupPaths.makeTunnelConfigurationStore()
        self.logStore = AppGroupPaths.makeRuntimeLogStore()
        let snapshotStore = AppGroupPaths.makeRuntimeSnapshotStore()
        self.runtimeCoordinator = TunnelRuntimeCoordinator(
            byedpiEngine: NativeByeDPIEngine(),
            dataPlaneFactory: { mode in
                LegacyTunFDDataPlane(mode: mode, tun2socksEngine: NativeTun2SocksEngine())
            },
            configurationStore: self.configurationStore,
            snapshotStore: snapshotStore,
            logStore: self.logStore
        )
        super.init()
    }

    override func startTunnel(
        options: [String: NSObject]?,
        completionHandler: @escaping (Error?) -> Void
    ) {
        Task {
            do {
                let baseProfile = try loadProfile()
                profile = ProviderStartOptions.mergedProfile(from: options, base: baseProfile)
                let implementationMode = TunnelImplementationMode.resolve(fromStartOptions: options)
                logger.info("Selected tunnel implementation mode: \(implementationMode.rawValue, privacy: .public)")

                try await runtimeCoordinator.start(
                    profile: profile,
                    implementationMode: implementationMode,
                    packetFlow: self.packetFlow,
                    resolveTunFileDescriptor: {
                        #if DEBUG
                        let debugFallbackMode: TunFileDescriptorResolver.DebugFallbackMode =
                            ProcessInfo.processInfo.environment["FLOWGUARD_DEBUG_ALLOW_FD_SCAN"] == "1"
                            ? .scanOpenFileDescriptors(maxFD: 4096)
                            : .disabled
                        #else
                        let debugFallbackMode: TunFileDescriptorResolver.DebugFallbackMode = .disabled
                        #endif

                        let result = TunFileDescriptorResolver.resolveUTUNFileDescriptorDetailed(
                            from: self.packetFlow,
                            debugFallback: debugFallbackMode
                        )
                        guard let tunFD = result.fileDescriptor else {
                            let details = result.diagnostics.map {
                                "attempts=\($0.attempts), candidates=\($0.candidateDescriptors), reason=\($0.failure.description)"
                            } ?? "reason=unknown"
                            self.logger.error("Failed to resolve tunnel file descriptor: \(details, privacy: .public)")
                            throw TunnelRuntimeError.tunnelDescriptorResolutionFailed(details)
                        }
                        self.logger.info("Resolved tunnel file descriptor: \(tunFD, privacy: .public)")
                        return tunFD
                    },
                    applyNetworkSettings: { [weak self] settings in
                        await self?.apply(settings: settings) ?? false
                    }
                )
                completionHandler(nil)
            } catch {
                logger.error("Tunnel startup failed: \(error.localizedDescription, privacy: .public)")
                completionHandler(error)
            }
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        logger.info("Stopping tunnel with reason: \(reason.rawValue, privacy: .public)")
        runtimeCoordinator.stop()
        completionHandler()
    }

    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)? = nil) {
        guard let command = try? JSONDecoder().decode(ProviderCommand.self, from: messageData) else {
            let payload = try? JSONEncoder().encode(ProviderMessage.error("invalid-command"))
            completionHandler?(payload)
            return
        }

        let response = runtimeCoordinator.handle(command)
        completionHandler?(try? JSONEncoder().encode(response))
    }

    private func apply(settings: NEPacketTunnelNetworkSettings) async -> Bool {
        let logger = self.logger
        return await withCheckedContinuation { continuation in
            setTunnelNetworkSettings(settings) { error in
                if let error {
                    logger.error("setTunnelNetworkSettings failed: \(error.localizedDescription, privacy: .public)")
                    continuation.resume(returning: false)
                    return
                }
                continuation.resume(returning: true)
            }
        }
    }

    private func loadProfile() throws -> TunnelProfile {
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
}
