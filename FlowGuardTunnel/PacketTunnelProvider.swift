import Foundation
import NetworkExtension
import OSLog

final class PacketTunnelProvider: NEPacketTunnelProvider {
    private let logger = Logger(subsystem: "com.uvays.FlowGuard", category: "PacketTunnel")
    private let runtimeCoordinator = TunnelRuntimeCoordinator(
        byedpiEngine: NativeByeDPIEngine(),
        tun2socksEngine: NativeTun2SocksEngine()
    )
    private var profile: TunnelProfile = .default

    override func startTunnel(
        options: [String: NSObject]?,
        completionHandler: @escaping (Error?) -> Void
    ) {
        Task {
            do {
                let baseProfile = try loadProfile()
                profile = ProviderStartOptions.mergedProfile(from: options, base: baseProfile)

                try await runtimeCoordinator.start(
                    profile: profile,
                    resolveTunFileDescriptor: {
                        guard let tunFD = TunFileDescriptorResolver.resolveUTUNFileDescriptor(from: self.packetFlow) else {
                            self.logger.error("Failed to resolve tunnel file descriptor from packetFlow after retries")
                            throw TunnelRuntimeError.invalidTunnelDescriptor
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
            let loaded = try AppGroupPaths.read(TunnelProfile.self, from: try AppGroupPaths.profileURL())
            try? AppGroupPaths.appendLog("Loaded profile from local provider storage")
            return loaded
        } catch {
            logger.error("Using default profile after read failure: \(error.localizedDescription, privacy: .public)")
            try? AppGroupPaths.write(TunnelProfile.default, to: try AppGroupPaths.profileURL())
            return .default
        }
    }
}
