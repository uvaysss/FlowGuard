import Foundation
import NetworkExtension

enum TunnelControllerError: LocalizedError {
    case simulatorUnsupported
    case networkExtensionIPCUnavailable
    case networkExtensionPermissionDenied
    case invalidSession
    case invalidResponse
    case providerError(String)
    case startupTimedOut(String)

    var errorDescription: String? {
        switch self {
        case .simulatorUnsupported:
            return "Packet Tunnel is not supported in iOS Simulator. Run on a physical iPhone/iPad."
        case .networkExtensionIPCUnavailable:
            return "Network Extension IPC failed. Verify a physical device, Packet Tunnel extension target, and signing entitlements/capabilities."
        case .networkExtensionPermissionDenied:
            return "Network Extension permission denied. Verify your Apple Developer team, provisioning profile, and Packet Tunnel entitlements/capabilities."
        case .invalidSession:
            return "The Network Extension session is unavailable."
        case .invalidResponse:
            return "The tunnel provider returned an invalid response payload."
        case let .providerError(message):
            return "Provider error: \(message)"
        case let .startupTimedOut(message):
            return "Tunnel did not enter connected state: \(message)"
        }
    }

    static func map(_ error: Error) -> Error {
        if error is TunnelControllerError {
            return error
        }

        let nsError = error as NSError
        if (nsError.domain == "NEConfigurationErrorDomain" && nsError.code == 11)
            || (nsError.domain == "NEVPNErrorDomain" && nsError.code == 5) {
            return TunnelControllerError.networkExtensionIPCUnavailable
        }
        if nsError.domain == "NEConfigurationErrorDomain" && nsError.code == 10 {
            return TunnelControllerError.networkExtensionPermissionDenied
        }

        return error
    }
}

@MainActor
final class TunnelController {
    static let shared = TunnelController()

    private let managerDescription = "FlowGuard Local Tunnel"
    private let providerBundleIdentifier = "io.jawziyya.flowguard.tunnel"

    func loadOrCreateManager() async throws -> NETunnelProviderManager {
        try ensureSupportedEnvironment()
        do {
            let managers = try await NETunnelProviderManager.loadAllFromPreferencesAsync()
            if let existing = managers.first(where: { $0.localizedDescription == managerDescription }) {
                return try await normalizeAndPersistManager(existing)
            }

            let manager = NETunnelProviderManager()
            let proto = NETunnelProviderProtocol()
            proto.providerBundleIdentifier = providerBundleIdentifier
            proto.serverAddress = "127.0.0.1"
            manager.protocolConfiguration = proto
            manager.localizedDescription = managerDescription
            manager.isEnabled = true

            return try await normalizeAndPersistManager(manager)
        } catch {
            throw TunnelControllerError.map(error)
        }
    }

    func install(profile: TunnelProfile) async throws {
        do {
            let manager = try await loadOrCreateManager()
            try AppGroupPaths.write(profile, to: try AppGroupPaths.profileURL())
            manager.isEnabled = true
            try await manager.saveToPreferencesAsync()
            try await manager.loadFromPreferencesAsync()
        } catch {
            throw TunnelControllerError.map(error)
        }
    }

    func connect() async throws {
        do {
            let manager = try await loadOrCreateManager()
            try await manager.loadFromPreferencesAsync()
            let profile = (try? AppGroupPaths.read(TunnelProfile.self, from: try AppGroupPaths.profileURL())) ?? .default
            try manager.connection.startVPNTunnel(options: ProviderStartOptions.makeDictionary(profile: profile))
            try await waitForConnectedStatus(manager.connection)
        } catch {
            throw TunnelControllerError.map(error)
        }
    }

    func connectionStatus() async throws -> NEVPNStatus {
        let manager = try await loadOrCreateManager()
        try await manager.loadFromPreferencesAsync()
        return manager.connection.status
    }

    func disconnect() async throws {
        do {
            let manager = try await loadOrCreateManager()
            try await manager.loadFromPreferencesAsync()
            manager.connection.stopVPNTunnel()
        } catch {
            throw TunnelControllerError.map(error)
        }
    }

    func reloadProfileInProvider() async throws -> ProviderMessage {
        try await sendCommand(.init(action: .reloadProfile))
    }

    func requestStats() async throws -> RuntimeStats {
        let response = try await sendCommand(.init(action: .collectStats))
        guard let stats = response.stats else {
            throw TunnelControllerError.invalidResponse
        }
        return stats
    }

    func requestLogs() async throws -> String {
        let response = try await sendCommand(.init(action: .exportLogs))
        return response.logs ?? "No provider logs available."
    }

    private func sendCommand(_ command: ProviderCommand) async throws -> ProviderMessage {
        do {
            let manager = try await loadOrCreateManager()
            try await manager.loadFromPreferencesAsync()

            guard let session = manager.connection as? NETunnelProviderSession else {
                throw TunnelControllerError.invalidSession
            }

            let payload = try JSONEncoder().encode(command)
            let raw = try await session.sendProviderMessage(payload)
            let message = try JSONDecoder().decode(ProviderMessage.self, from: raw)

            if message.kind == .error {
                throw TunnelControllerError.providerError(message.description ?? "Unknown provider error")
            }
            return message
        } catch {
            throw TunnelControllerError.map(error)
        }
    }

    private func ensureSupportedEnvironment() throws {
        #if targetEnvironment(simulator)
        throw TunnelControllerError.simulatorUnsupported
        #endif
    }

    private func normalizeAndPersistManager(_ manager: NETunnelProviderManager) async throws -> NETunnelProviderManager {
        let proto = (manager.protocolConfiguration as? NETunnelProviderProtocol) ?? NETunnelProviderProtocol()
        proto.providerBundleIdentifier = providerBundleIdentifier
        proto.serverAddress = "127.0.0.1"
        manager.protocolConfiguration = proto
        manager.localizedDescription = managerDescription
        manager.isEnabled = true
        try await manager.saveToPreferencesAsync()
        try await manager.loadFromPreferencesAsync()
        return manager
    }

    private func waitForConnectedStatus(_ connection: NEVPNConnection) async throws {
        for _ in 0..<20 {
            switch connection.status {
            case .connected, .reasserting:
                return
            case .disconnecting, .disconnected, .invalid:
                break
            case .connecting:
                break
            @unknown default:
                break
            }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        throw TunnelControllerError.startupTimedOut(connection.status.readableName)
    }
}

private extension NEVPNStatus {
    var readableName: String {
        switch self {
        case .invalid:
            return "invalid"
        case .disconnected:
            return "disconnected"
        case .connecting:
            return "connecting"
        case .connected:
            return "connected"
        case .reasserting:
            return "reasserting"
        case .disconnecting:
            return "disconnecting"
        @unknown default:
            return "unknown"
        }
    }
}

private extension NETunnelProviderManager {
    static func loadAllFromPreferencesAsync() async throws -> [NETunnelProviderManager] {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[NETunnelProviderManager], Error>) in
            NETunnelProviderManager.loadAllFromPreferences { managers, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: managers ?? [])
                }
            }
        }
    }

    func loadFromPreferencesAsync() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            loadFromPreferences { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
    }

    func saveToPreferencesAsync() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            saveToPreferences { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
    }
}

private extension NETunnelProviderSession {
    func sendProviderMessage(_ messageData: Data) async throws -> Data {
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
