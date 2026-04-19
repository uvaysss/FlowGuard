import Foundation
import NetworkExtension

@MainActor
final class TunnelConfigurationService {
    private let configurationStore: TunnelConfigurationStore
    private let managerService: TunnelManagerService

    init(
        configurationStore: TunnelConfigurationStore,
        managerService: TunnelManagerService
    ) {
        self.configurationStore = configurationStore
        self.managerService = managerService
    }

    func loadOrCreateManager() async throws -> NETunnelProviderManager {
        try await managerService.loadOrCreateManagerForInstall()
    }

    func install(profile: TunnelProfile) async throws {
        do {
            let manager = try await managerService.loadOrCreateManagerForInstall()
            try configurationStore.saveProfile(profile)
            var didMutate = managerService.applyConfiguration(to: manager)
            if !manager.isEnabled {
                manager.isEnabled = true
                didMutate = true
            }

            if didMutate {
                try await manager.saveToPreferencesAsync()
                try await manager.loadFromPreferencesAsync()
            }
            managerService.cache(manager)
        } catch {
            throw TunnelControllerError.map(error)
        }
    }

    func loadPersistedProfile() throws -> TunnelProfile {
        (try configurationStore.loadProfile()) ?? .default
    }
}
