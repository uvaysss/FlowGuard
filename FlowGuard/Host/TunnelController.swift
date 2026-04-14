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

    private let managerDescription = "FlowGuard Local Tunnel"
    private let providerBundleIdentifier = "io.jawziyya.flowguard.tunnel"
    private let installedManagerCacheTTL: TimeInterval = 5
    private let configurationStore: TunnelConfigurationStore
    private var cachedInstalledManager: NETunnelProviderManager?
    private var cachedInstalledManagerLoadedAt: Date?

    init(configurationStore: TunnelConfigurationStore = AppGroupPaths.makeTunnelConfigurationStore()) {
        self.configurationStore = configurationStore
    }

    func loadOrCreateManager() async throws -> NETunnelProviderManager {
        try await loadOrCreateManagerForInstall()
    }

    func install(profile: TunnelProfile) async throws {
        do {
            let manager = try await loadOrCreateManagerForInstall()
            try configurationStore.saveProfile(profile)
            var didMutate = applyStandardManagerConfiguration(manager)
            if !manager.isEnabled {
                manager.isEnabled = true
                didMutate = true
            }

            if didMutate {
                try await manager.saveToPreferencesAsync()
                try await manager.loadFromPreferencesAsync()
            }
            cacheInstalledManager(manager)
        } catch {
            throw TunnelControllerError.map(error)
        }
    }

    func connect() async throws {
        do {
            let manager = try await loadInstalledManager(forceRefresh: true)
            try await manager.loadFromPreferencesAsync()
            let profile = (try configurationStore.loadProfile()) ?? .default
            try manager.connection.startVPNTunnel(options: ProviderStartOptions.makeDictionary(profile: profile))
            _ = try await waitForConnectedStatus(manager.connection)
            cacheInstalledManager(manager)
        } catch {
            throw TunnelControllerError.map(error)
        }
    }

    func connectionStatus() async throws -> NEVPNStatus {
        let manager = try await loadInstalledManager()
        return manager.connection.status
    }

    func disconnect() async throws {
        do {
            let manager = try await loadInstalledManager(forceRefresh: true)
            try await manager.loadFromPreferencesAsync()
            manager.connection.stopVPNTunnel()
        } catch {
            throw TunnelControllerError.map(error)
        }
    }

    func reloadProfileInProvider() async throws -> ProviderMessage {
        try await sendCommand(.init(action: .reloadProfile))
    }

    func requestStats() async throws -> (stats: RuntimeStats, state: ProviderState?) {
        let response = try await sendCommand(.init(action: .collectStats))
        guard let stats = response.stats else {
            throw TunnelControllerError.invalidResponse
        }
        return (stats: stats, state: response.state)
    }

    func requestLogs() async throws -> String {
        let response = try await sendCommand(.init(action: .exportLogs))
        return response.logs ?? "No provider logs available."
    }

    private func sendCommand(_ command: ProviderCommand) async throws -> ProviderMessage {
        do {
            let manager = try await loadInstalledManager()

            guard let session = manager.connection as? NETunnelProviderSession else {
                invalidateInstalledManagerCache()
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
            let mapped = TunnelControllerError.map(error)
            if let controllerError = mapped as? TunnelControllerError {
                switch controllerError {
                case .invalidSession, .managerNotInstalled, .networkExtensionIPCUnavailable:
                    invalidateInstalledManagerCache()
                default:
                    break
                }
            }
            throw mapped
        }
    }

    private func ensureSupportedEnvironment() throws {
        #if targetEnvironment(simulator)
        throw TunnelControllerError.simulatorUnsupported
        #endif
    }

    private func loadOrCreateManagerForInstall() async throws -> NETunnelProviderManager {
        try ensureSupportedEnvironment()
        do {
            if let existing = try await loadExistingManager() {
                cacheInstalledManager(existing)
                return existing
            }

            let manager = NETunnelProviderManager()
            _ = applyStandardManagerConfiguration(manager)
            manager.isEnabled = true
            try await manager.saveToPreferencesAsync()
            try await manager.loadFromPreferencesAsync()
            cacheInstalledManager(manager)
            return manager
        } catch {
            throw TunnelControllerError.map(error)
        }
    }

    private func loadInstalledManager(forceRefresh: Bool = false) async throws -> NETunnelProviderManager {
        try ensureSupportedEnvironment()
        if !forceRefresh, let cached = cachedInstalledManager, let loadedAt = cachedInstalledManagerLoadedAt {
            if Date().timeIntervalSince(loadedAt) < installedManagerCacheTTL {
                return cached
            }
        }

        guard let manager = try await loadExistingManager() else {
            invalidateInstalledManagerCache()
            throw TunnelControllerError.managerNotInstalled
        }
        cacheInstalledManager(manager)
        return manager
    }

    private func cacheInstalledManager(_ manager: NETunnelProviderManager) {
        cachedInstalledManager = manager
        cachedInstalledManagerLoadedAt = Date()
    }

    private func invalidateInstalledManagerCache() {
        cachedInstalledManager = nil
        cachedInstalledManagerLoadedAt = nil
    }

    private func loadExistingManager() async throws -> NETunnelProviderManager? {
        let managers = try await NETunnelProviderManager.loadAllFromPreferencesAsync()
        return managers.first(where: { $0.localizedDescription == managerDescription })
    }

    @discardableResult
    private func applyStandardManagerConfiguration(_ manager: NETunnelProviderManager) -> Bool {
        var didMutate = false

        let proto = (manager.protocolConfiguration as? NETunnelProviderProtocol) ?? NETunnelProviderProtocol()
        if manager.protocolConfiguration as? NETunnelProviderProtocol == nil {
            didMutate = true
        }

        if proto.providerBundleIdentifier != providerBundleIdentifier {
            didMutate = true
        }
        proto.providerBundleIdentifier = providerBundleIdentifier

        if proto.serverAddress != "127.0.0.1" {
            didMutate = true
        }
        proto.serverAddress = "127.0.0.1"

        if manager.localizedDescription != managerDescription {
            didMutate = true
        }
        manager.protocolConfiguration = proto
        manager.localizedDescription = managerDescription

        return didMutate
    }

    private func waitForConnectedStatus(_ connection: NEVPNConnection) async throws -> Bool {
        for _ in 0..<20 {
            let status = connection.status
            switch status {
            case .connected, .reasserting:
                return true
            case .disconnected, .invalid:
                throw TunnelControllerError.startupFailed(status.readableName)
            case .disconnecting:
                break
            case .connecting:
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
