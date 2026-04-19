import Foundation
import NetworkExtension

struct TunnelManagerConfiguration: Sendable {
    let description: String
    let providerBundleIdentifier: String
    let serverAddress: String

    static let flowGuard = TunnelManagerConfiguration(
        description: "FlowGuard Local Tunnel",
        providerBundleIdentifier: "io.jawziyya.flowguard.tunnel",
        serverAddress: "127.0.0.1"
    )

    @discardableResult
    func apply(to manager: NETunnelProviderManager) -> Bool {
        var didMutate = false

        let proto = (manager.protocolConfiguration as? NETunnelProviderProtocol) ?? NETunnelProviderProtocol()
        if manager.protocolConfiguration as? NETunnelProviderProtocol == nil {
            didMutate = true
        }

        if proto.providerBundleIdentifier != providerBundleIdentifier {
            didMutate = true
        }
        proto.providerBundleIdentifier = providerBundleIdentifier

        if proto.serverAddress != serverAddress {
            didMutate = true
        }
        proto.serverAddress = serverAddress

        if manager.localizedDescription != description {
            didMutate = true
        }
        manager.protocolConfiguration = proto
        manager.localizedDescription = description

        return didMutate
    }
}

@MainActor
final class TunnelManagerService {
    private let configuration: TunnelManagerConfiguration
    private let installedManagerCacheTTL: TimeInterval
    private var cachedInstalledManager: NETunnelProviderManager?
    private var cachedInstalledManagerLoadedAt: Date?

    init(
        configuration: TunnelManagerConfiguration = .flowGuard,
        installedManagerCacheTTL: TimeInterval = 5
    ) {
        self.configuration = configuration
        self.installedManagerCacheTTL = installedManagerCacheTTL
    }

    func loadOrCreateManagerForInstall() async throws -> NETunnelProviderManager {
        try ensureSupportedEnvironment()
        do {
            if let existing = try await loadExistingManager() {
                cache(existing)
                return existing
            }

            let manager = NETunnelProviderManager()
            _ = configuration.apply(to: manager)
            manager.isEnabled = true
            try await manager.saveToPreferencesAsync()
            try await manager.loadFromPreferencesAsync()
            cache(manager)
            return manager
        } catch {
            throw TunnelControllerError.map(error)
        }
    }

    func loadInstalledManager(forceRefresh: Bool = false) async throws -> NETunnelProviderManager {
        try ensureSupportedEnvironment()
        if !forceRefresh,
           let cachedInstalledManager,
           let cachedInstalledManagerLoadedAt,
           Date().timeIntervalSince(cachedInstalledManagerLoadedAt) < installedManagerCacheTTL {
            return cachedInstalledManager
        }

        guard let manager = try await loadExistingManager() else {
            invalidateCache()
            throw TunnelControllerError.managerNotInstalled
        }
        cache(manager)
        return manager
    }

    @discardableResult
    func applyConfiguration(to manager: NETunnelProviderManager) -> Bool {
        configuration.apply(to: manager)
    }

    func cache(_ manager: NETunnelProviderManager) {
        cachedInstalledManager = manager
        cachedInstalledManagerLoadedAt = Date()
    }

    func invalidateCache() {
        cachedInstalledManager = nil
        cachedInstalledManagerLoadedAt = nil
    }

    private func loadExistingManager() async throws -> NETunnelProviderManager? {
        let managers = try await NETunnelProviderManager.loadAllFromPreferencesAsync()
        return managers.first(where: { $0.localizedDescription == configuration.description })
    }

    private func ensureSupportedEnvironment() throws {
        #if targetEnvironment(simulator)
        throw TunnelControllerError.simulatorUnsupported
        #endif
    }
}

extension NETunnelProviderManager {
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
