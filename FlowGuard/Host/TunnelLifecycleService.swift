import Foundation
import NetworkExtension

@MainActor
final class TunnelLifecycleService {
    private let managerService: TunnelManagerService
    private let configurationService: TunnelConfigurationService

    init(
        managerService: TunnelManagerService,
        configurationService: TunnelConfigurationService
    ) {
        self.managerService = managerService
        self.configurationService = configurationService
    }

    func connect() async throws {
        do {
            let manager = try await managerService.loadInstalledManager(forceRefresh: true)
            try await manager.loadFromPreferencesAsync()
            let profile = try configurationService.loadPersistedProfile()
            try manager.connection.startVPNTunnel(options: ProviderStartOptions.makeDictionary(profile: profile))
            _ = try await waitForConnectedStatus(manager.connection)
            managerService.cache(manager)
        } catch {
            throw TunnelControllerError.map(error)
        }
    }

    func connectionStatus() async throws -> NEVPNStatus {
        let manager = try await managerService.loadInstalledManager()
        return manager.connection.status
    }

    func disconnect() async throws {
        do {
            let manager = try await managerService.loadInstalledManager(forceRefresh: true)
            try await manager.loadFromPreferencesAsync()
            manager.connection.stopVPNTunnel()
        } catch {
            throw TunnelControllerError.map(error)
        }
    }

    private func waitForConnectedStatus(_ connection: NEVPNConnection) async throws -> Bool {
        for _ in 0..<20 {
            switch connection.status {
            case .connected, .reasserting:
                return true
            case .disconnected, .invalid:
                throw TunnelControllerError.startupFailed(connection.status.readableName)
            case .disconnecting, .connecting:
                break
            @unknown default:
                break
            }
            try await Task.sleep(nanoseconds: 500_000_000)
        }

        let tailStatus = connection.status
        if tailStatus == .connecting || tailStatus == .reasserting {
            return false
        }
        throw TunnelControllerError.startupTimedOut(tailStatus.readableName)
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
