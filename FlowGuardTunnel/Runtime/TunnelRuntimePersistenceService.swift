import Foundation
import OSLog

protocol TunnelRuntimePersisting {
    func loadProfile() throws -> TunnelProfile?
    func persistSnapshot(state: ProviderState, stats: RuntimeStats)
    func appendLog(_ line: String)
    func readLogPreview(maxBytes: Int) -> String
}

final class DefaultTunnelRuntimePersistenceService: TunnelRuntimePersisting {
    private let logger: Logger
    private let configurationStore: TunnelConfigurationStore
    private let snapshotStore: RuntimeSnapshotStore
    private let logStore: RuntimeLogStore
    private let consoleTimestampFormatter = ISO8601DateFormatter()

    init(
        logger: Logger,
        configurationStore: TunnelConfigurationStore,
        snapshotStore: RuntimeSnapshotStore,
        logStore: RuntimeLogStore
    ) {
        self.logger = logger
        self.configurationStore = configurationStore
        self.snapshotStore = snapshotStore
        self.logStore = logStore
    }

    func loadProfile() throws -> TunnelProfile? {
        try configurationStore.loadProfile()
    }

    func persistSnapshot(state: ProviderState, stats: RuntimeStats) {
        do {
            try snapshotStore.persistRuntimeSnapshot(state: state, stats: stats)
        } catch {
            logger.error("Failed to persist runtime snapshot: \(error.localizedDescription, privacy: .public)")
            emitConsole("snapshot-persist-failed: \(error.localizedDescription)")
        }
    }

    func appendLog(_ line: String) {
        logger.notice("FG-TUN \(line, privacy: .public)")
        NSLog("FG-TUN %@", line)
        emitConsole(line)
        do {
            try logStore.appendRuntimeLog(line)
        } catch {
            logger.error("Failed to append runtime log: \(error.localizedDescription, privacy: .public)")
            NSLog("FG-TUN runtime-log-store-write-failed: %@", error.localizedDescription)
            emitConsole("runtime-log-store-write-failed: \(error.localizedDescription)")
        }
    }

    func readLogPreview(maxBytes: Int = 8_192) -> String {
        do {
            return try logStore.readRuntimeLogPreview(maxBytes: maxBytes)
        } catch {
            logger.error("Failed to read runtime logs: \(error.localizedDescription, privacy: .public)")
            emitConsole("runtime-log-read-failed: \(error.localizedDescription)")
            return "No logs yet."
        }
    }

    private func emitConsole(_ line: String) {
        let timestamp = consoleTimestampFormatter.string(from: Date())
        let consoleLine = "[FG-TUN \(timestamp)] \(line)\n"
        guard let data = consoleLine.data(using: .utf8) else {
            return
        }
        FileHandle.standardError.write(data)
    }
}
