import Foundation
import NetworkExtension
import OSLog

final class PacketTunnelProvider: NEPacketTunnelProvider {
    private let logger = Logger(subsystem: "com.uvays.FlowGuard", category: "PacketTunnel")
    private let runtimeController: PacketTunnelProviderRuntimeControlling

    override init() {
        self.runtimeController = PacketTunnelProviderFactory.makeRuntimeController()
        super.init()
    }

    override func startTunnel(
        options: [String: NSObject]?,
        completionHandler: @escaping (Error?) -> Void
    ) {
        Task {
            do {
                try await runtimeController.start(options: options, provider: self, logger: logger)
                completionHandler(nil)
            } catch {
                logger.error("Tunnel startup failed: \(error.localizedDescription, privacy: .public)")
                completionHandler(error)
            }
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        logger.info("Stopping tunnel with reason: \(reason.rawValue, privacy: .public)")
        runtimeController.stop()
        completionHandler()
    }

    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)? = nil) {
        guard let command = try? JSONDecoder().decode(ProviderCommand.self, from: messageData) else {
            let payload = try? JSONEncoder().encode(ProviderMessage.error("invalid-command"))
            completionHandler?(payload)
            return
        }

        let response = runtimeController.handle(command)
        completionHandler?(try? JSONEncoder().encode(response))
    }
}
