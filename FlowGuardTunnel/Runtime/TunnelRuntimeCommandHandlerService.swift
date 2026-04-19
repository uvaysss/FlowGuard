import Foundation

final class TunnelRuntimeCommandHandlerService {
    private let runtimeStateStore: TunnelRuntimeStateStoring
    private let persistenceService: TunnelRuntimePersisting
    private let runtimeStatsService: TunnelRuntimeStatsService

    init(
        runtimeStateStore: TunnelRuntimeStateStoring,
        persistenceService: TunnelRuntimePersisting,
        runtimeStatsService: TunnelRuntimeStatsService
    ) {
        self.runtimeStateStore = runtimeStateStore
        self.persistenceService = persistenceService
        self.runtimeStatsService = runtimeStatsService
    }

    func handleReloadProfile() -> ProviderMessage {
        do {
            let profile = try persistenceService.loadProfile() ?? .default
            runtimeStateStore.updateState {
                $0.activeProfile = profile
                $0.runtimeStats.selectedPreset = profile.preset
            }
            persistSnapshotBestEffort()
            persistenceService.appendLog("Profile reloaded: \(profile.preset.rawValue)")
            return .ok("Profile reloaded")
        } catch {
            runtimeStateStore.updateState { $0.runtimeStats.lastError = error.localizedDescription }
            persistSnapshotBestEffort()
            return .error("reloadProfile failed: \(error.localizedDescription)")
        }
    }

    func handleCollectStats(now: Date = Date()) -> ProviderMessage {
        let snapshot = runtimeStatsService.collectStats(now: now)
        return ProviderMessage(
            kind: .stats,
            description: nil,
            state: runtimeStateStore.providerState,
            stats: snapshot,
            logs: nil
        )
    }

    func makeExportLogsMessage() -> ProviderMessage {
        ProviderMessage(
            kind: .logs,
            description: nil,
            state: runtimeStateStore.providerState,
            stats: nil,
            logs: persistenceService.readLogPreview(maxBytes: 8_192)
        )
    }

    private func persistSnapshotBestEffort() {
        let snapshot = runtimeStateStore.makePersistentSnapshot(now: Date())
        persistenceService.persistSnapshot(state: snapshot.state, stats: snapshot.stats)
    }
}
