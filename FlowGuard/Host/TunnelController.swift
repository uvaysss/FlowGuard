import Foundation
import NetworkExtension

enum TunnelControllerError: LocalizedError {
    case simulatorUnsupported
    case networkExtensionIPCUnavailable
    case networkExtensionPermissionDenied
    case managerNotInstalled
    case invalidSession
    case invalidResponse
    case providerError(String)
    case startupFailed(String)
    case startupTimedOut(String)

    var errorDescription: String? {
        switch self {
        case .simulatorUnsupported:
            return "Packet Tunnel is not supported in iOS Simulator. Run on a physical iPhone/iPad."
        case .networkExtensionIPCUnavailable:
            return "Network Extension IPC failed. Verify a physical device, Packet Tunnel extension target, and signing entitlements/capabilities."
        case .networkExtensionPermissionDenied:
            return "Network Extension permission denied. Verify your Apple Developer team, provisioning profile, and Packet Tunnel entitlements/capabilities."
        case .managerNotInstalled:
            return "Tunnel configuration is not installed. Install configuration first."
        case .invalidSession:
            return "The Network Extension session is unavailable."
        case .invalidResponse:
            return "The tunnel provider returned an invalid response payload."
        case let .providerError(message):
            return "Provider error: \(message)"
        case let .startupFailed(message):
            return "Tunnel failed to start: \(message)"
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

    private let configurationService: TunnelConfigurationService
    private let lifecycleService: TunnelLifecycleService
    private let messagingService: TunnelProviderMessagingService

    init(configurationStore: TunnelConfigurationStore = AppGroupPaths.makeTunnelConfigurationStore()) {
        let managerService = TunnelManagerService()
        self.configurationService = TunnelConfigurationService(
            configurationStore: configurationStore,
            managerService: managerService
        )
        self.lifecycleService = TunnelLifecycleService(
            managerService: managerService,
            configurationService: configurationService
        )
        self.messagingService = TunnelProviderMessagingService(managerService: managerService)
    }

    func loadOrCreateManager() async throws -> NETunnelProviderManager {
        try await configurationService.loadOrCreateManager()
    }

    func install(profile: TunnelProfile) async throws {
        try await configurationService.install(profile: profile)
    }

    func connect() async throws {
        try await lifecycleService.connect()
    }

    func connectionStatus() async throws -> NEVPNStatus {
        try await lifecycleService.connectionStatus()
    }

    func disconnect() async throws {
        try await lifecycleService.disconnect()
    }

    func reloadProfileInProvider() async throws -> ProviderMessage {
        try await messagingService.sendCommand(.init(action: .reloadProfile))
    }

    func requestStats() async throws -> (stats: RuntimeStats, state: ProviderState?) {
        let response = try await messagingService.sendCommand(.init(action: .collectStats))
        guard let stats = response.stats else {
            throw TunnelControllerError.invalidResponse
        }
        return (stats: stats, state: response.state)
    }

    func requestLogs() async throws -> String {
        let response = try await messagingService.sendCommand(.init(action: .exportLogs))
        return response.logs ?? "No provider logs available."
    }
}
