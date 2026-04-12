import Foundation
import Combine
import SwiftUI

@MainActor
final class AppViewModel: ObservableObject {
    @Published var profile: TunnelProfile = .default
    @Published var providerState: ProviderState = .disconnected
    @Published var runtimeStats: RuntimeStats = .empty
    @Published var logPreview = "No logs yet."
    @Published var statusMessage = "Idle"
    @Published var isBusy = false

    private let controller: TunnelController
    private var statsPollingTask: Task<Void, Never>?

    init(controller: TunnelController? = nil) {
        self.controller = controller ?? .shared
        loadProfileFromDisk()
        loadSnapshotFromDisk()
        refreshLogsFromDisk()
    }

    func loadProfileFromDisk() {
        do {
            profile = try AppGroupPaths.read(TunnelProfile.self, from: try AppGroupPaths.profileURL())
            statusMessage = "Loaded saved profile."
        } catch {
            profile = .default
            statusMessage = "Using default profile."
        }
    }

    func saveProfile() {
        do {
            try AppGroupPaths.write(profile, to: try AppGroupPaths.profileURL())
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
        runBusyTask { [self] in
            try await self.controller.connect()
            self.providerState = .running
            self.statusMessage = "Tunnel connected."
            self.startStatsPolling()
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
            let stats = try await controller.requestStats()
            runtimeStats = stats
            statusMessage = "Stats updated."
            if let snapshot = AppGroupPaths.readRuntimeSnapshot() {
                providerState = snapshot.state
            }
        } catch {
            statusMessage = "Stats request failed: \(error.localizedDescription)"
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
        logPreview = AppGroupPaths.readLogPreview()
        if logPreview.isEmpty {
            logPreview = "No logs yet."
        }
    }

    func loadSnapshotFromDisk() {
        guard let snapshot = AppGroupPaths.readRuntimeSnapshot() else {
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
                providerState = .failed
                statusMessage = error.localizedDescription
            }
        }
    }

    private func startStatsPolling() {
        stopStatsPolling()
        statsPollingTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { break }
                await self.requestStats()
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    private func stopStatsPolling() {
        statsPollingTask?.cancel()
        statsPollingTask = nil
    }
}
