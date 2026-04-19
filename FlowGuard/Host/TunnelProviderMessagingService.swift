import Foundation
import NetworkExtension

@MainActor
final class TunnelProviderMessagingService {
    private let managerService: TunnelManagerService
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(managerService: TunnelManagerService) {
        self.managerService = managerService
    }

    func sendCommand(_ command: ProviderCommand) async throws -> ProviderMessage {
        do {
            let manager = try await managerService.loadInstalledManager()

            guard let session = manager.connection as? NETunnelProviderSession else {
                managerService.invalidateCache()
                throw TunnelControllerError.invalidSession
            }

            let payload = try encoder.encode(command)
            let raw = try await session.sendProviderMessageAsync(payload)
            let message = try decoder.decode(ProviderMessage.self, from: raw)

            if message.kind == .error {
                throw TunnelControllerError.providerError(message.description ?? "Unknown provider error")
            }
            return message
        } catch {
            let mapped = TunnelControllerError.map(error)
            if let controllerError = mapped as? TunnelControllerError {
                switch controllerError {
                case .invalidSession, .managerNotInstalled, .networkExtensionIPCUnavailable:
                    managerService.invalidateCache()
                default:
                    break
                }
            }
            throw mapped
        }
    }
}

extension NETunnelProviderSession {
    func sendProviderMessageAsync(_ messageData: Data) async throws -> Data {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            do {
                try sendProviderMessage(messageData) { responseData in
                    guard let responseData else {
                        continuation.resume(throwing: TunnelControllerError.invalidResponse)
                        return
                    }
                    continuation.resume(returning: responseData)
                }
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}
