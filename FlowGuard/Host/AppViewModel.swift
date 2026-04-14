import Foundation
import Combine
import NetworkExtension
import SwiftUI

@MainActor
final class AppViewModel: ObservableObject {
    private static let statsPollingIntervalNanoseconds: UInt64 = 2_000_000_000

    @Published var profile: TunnelProfile = .default
    @Published var providerState: ProviderState = .disconnected
    @Published var runtimeStats: RuntimeStats = .empty
    @Published var logPreview = "No logs yet."
    @Published var statusMessage = "Idle"
    @Published var isBusy = false

    private let controller: TunnelController
    private let configurationStore: TunnelConfigurationStore
    private let snapshotStore: RuntimeSnapshotStore
    private let logStore: RuntimeLogStore
    private var statsPollingTask: Task<Void, Never>?

    init(
        controller: TunnelController? = nil,
        configurationStore: TunnelConfigurationStore = AppGroupPaths.makeTunnelConfigurationStore(),
        snapshotStore: RuntimeSnapshotStore = AppGroupPaths.makeRuntimeSnapshotStore(),
        logStore: RuntimeLogStore = AppGroupPaths.makeRuntimeLogStore()
    ) {
        self.controller = controller ?? .shared
        self.configurationStore = configurationStore
        self.snapshotStore = snapshotStore
        self.logStore = logStore
        loadProfileFromDisk()
        loadSnapshotFromDisk()
        refreshLogsFromDisk()
        Task { [weak self] in
            await self?.reconcileProviderStateWithSystem()
        }
    }

    func loadProfileFromDisk() {
        do {
            if let loadedProfile = try configurationStore.loadProfile() {
                profile = loadedProfile
                statusMessage = "Loaded saved profile."
            } else {
                profile = .default
                statusMessage = "Using default profile."
            }
        } catch {
            profile = .default
            statusMessage = "Using default profile. (\(error.localizedDescription))"
        }
    }

    func saveProfile() {
        do {
            try configurationStore.saveProfile(profile)
            statusMessage = "Profile saved."
        } catch {
            statusMessage = "Failed to save profile: \(error.localizedDescription)"
        }
    }

    func installConfiguration() {
        runBusyTask { [self] in
            try await self.controller.install(profile: self.profile)
            self.statusMessage = "Tunnel configuration installed."
        }
    }

    func connect() {
        providerState = .starting
        startStatsPolling()
        runBusyTask { [self] in
            try await self.controller.connect()
            if self.providerState == .starting {
                self.providerState = .running
            }
            self.statusMessage = "Tunnel start requested."
            await self.requestStats()
        }
    }

    func disconnect() {
        providerState = .stopping
        runBusyTask { [self] in
            try await self.controller.disconnect()
            self.stopStatsPolling()
            self.providerState = .disconnected
            self.statusMessage = "Tunnel stop request sent."
            self.loadSnapshotFromDisk()
        }
    }

    func requestStats() async {
        do {
            let response = try await controller.requestStats()
            runtimeStats = response.stats
            if let liveState = response.state {
                providerState = liveState
            } else if let snapshot = try? snapshotStore.loadRuntimeSnapshot() {
                providerState = snapshot.state
            }
            if statusMessage.hasPrefix("Stats request failed") {
                statusMessage = "Stats updated."
            }
        } catch {
            statusMessage = "Stats request failed: \(error.localizedDescription)"
            await reconcileProviderStateWithSystem()
        }
    }

    func requestStats() {
        Task {
            await requestStats()
        }
    }

    func reloadProfileInProvider() {
        runBusyTask { [self] in
            let response = try await self.controller.reloadProfileInProvider()
            self.statusMessage = response.description ?? "Profile reloaded in provider."
        }
    }

    func refreshLogsFromProvider() {
        runBusyTask { [self] in
            self.logPreview = try await self.controller.requestLogs()
            self.statusMessage = "Fetched logs from provider."
        }
    }

    func refreshLogsFromDisk() {
        logPreview = (try? logStore.readRuntimeLogPreview(maxBytes: 8_192)) ?? "No logs yet."
        if logPreview.isEmpty {
            logPreview = "No logs yet."
        }
    }

    func loadSnapshotFromDisk() {
        guard let snapshot = try? snapshotStore.loadRuntimeSnapshot() else {
            return
        }
        providerState = snapshot.state
        runtimeStats = snapshot.stats
    }

    private func runBusyTask(_ operation: @escaping @MainActor () async throws -> Void) {
        guard !isBusy else {
            return
        }

        isBusy = true
        Task {
            defer { isBusy = false }
            do {
                try await operation()
            } catch {
                stopStatsPolling()
                statusMessage = error.localizedDescription
                await reconcileProviderStateWithSystem()
            }
        }
    }

    private func startStatsPolling() {
        stopStatsPolling()
        statsPollingTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { break }
                await self.requestStats()
                try? await Task.sleep(nanoseconds: Self.statsPollingIntervalNanoseconds)
            }
        }
    }

    private func stopStatsPolling() {
        statsPollingTask?.cancel()
        statsPollingTask = nil
    }

    private func reconcileProviderStateWithSystem() async {
        guard let status = try? await controller.connectionStatus() else {
            return
        }

        let resolved = ProviderState(vpnStatus: status)
        if resolved != providerState {
            providerState = resolved
        }
    }
}

private extension ProviderState {
    init(vpnStatus: NEVPNStatus) {
        switch vpnStatus {
        case .connected, .reasserting:
            self = .running
        case .connecting:
            self = .starting
        case .disconnecting:
            self = .stopping
        case .disconnected:
            self = .disconnected
        case .invalid:
            self = .disconnected
        @unknown default:
            self = .disconnected
        }
    }
}
