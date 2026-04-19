import Foundation
import OSLog

final class TunnelRuntimeLifecycleService {
    private static let gracefulStopTimeoutSeconds: TimeInterval = 3
    private static let forcedStopTimeoutSeconds: TimeInterval = 2

    private let logger: Logger
    private let byedpiEngine: ByeDPIEngine
    private let runtimeStateStore: TunnelRuntimeStateStoring
    private let persistenceService: TunnelRuntimePersisting

    init(
        logger: Logger,
        byedpiEngine: ByeDPIEngine,
        runtimeStateStore: TunnelRuntimeStateStoring,
        persistenceService: TunnelRuntimePersisting
    ) {
        self.logger = logger
        self.byedpiEngine = byedpiEngine
        self.runtimeStateStore = runtimeStateStore
        self.persistenceService = persistenceService
    }

    func stop() {
        let stopTargets = runtimeStateStore.withState { ($0.isDataPlaneRunning, $0.isByeDPIRunning) }
        runtimeStateStore.updateState {
            $0.providerState = .stopping
            $0.runtimeStats.lifecycleStopAttempts = ($0.runtimeStats.lifecycleStopAttempts ?? 0) + 1
        }
        persistSnapshotBestEffort()

        var stopErrors: [String] = []
        var dataPlaneDidStop = true

        if stopTargets.0 {
            let result = stopDataPlane(context: "Stop")
            dataPlaneDidStop = result.didStop
            if let message = result.errorMessage {
                stopErrors.append(message)
            }
            runtimeStateStore.updateState { $0.isDataPlaneRunning = !result.didStop }
        }

        if stopTargets.1 {
            let result = stopByeDPIWithTimeouts(context: "Stop")
            if let message = result.errorMessage {
                stopErrors.append(message)
            }
            runtimeStateStore.updateState { $0.isByeDPIRunning = !result.didStop }
        }

        runtimeStateStore.updateState {
            if stopErrors.isEmpty {
                $0.startedAt = nil
                $0.tunInterfaceName = nil
                $0.baselineBytesIn = 0
                $0.baselineBytesOut = 0
                $0.runtimeStats.uptimeSeconds = 0
                $0.providerState = .disconnected
                $0.runtimeStats.lastError = nil
            } else {
                $0.providerState = .failed
                $0.runtimeStats.lastError = stopErrors.joined(separator: " | ")
                $0.runtimeStats.lifecycleStopFailures = ($0.runtimeStats.lifecycleStopFailures ?? 0) + 1
            }
        }
        if stopTargets.0 && dataPlaneDidStop {
            runtimeStateStore.setActiveDataPlane(nil)
        }
        persistSnapshotBestEffort()
    }

    func rollbackStartup(didStartByeDPI: Bool, didStartDataPlane: Bool) {
        var rollbackErrors: Int64 = 0
        runtimeStateStore.updateState {
            $0.runtimeStats.lifecycleRollbackAttempts = ($0.runtimeStats.lifecycleRollbackAttempts ?? 0) + 1
        }
        if didStartDataPlane {
            let result = stopDataPlane(context: "Rollback")
            runtimeStateStore.updateState { $0.isDataPlaneRunning = !result.didStop }
            if result.didStop {
                runtimeStateStore.setActiveDataPlane(nil)
            } else {
                rollbackErrors += 1
            }
        }

        if didStartByeDPI {
            let result = stopByeDPIWithTimeouts(context: "Rollback")
            runtimeStateStore.updateState { $0.isByeDPIRunning = !result.didStop }
            if !result.didStop {
                rollbackErrors += 1
            }
        }

        if rollbackErrors > 0 {
            runtimeStateStore.updateState {
                $0.runtimeStats.lifecycleRollbackFailures = ($0.runtimeStats.lifecycleRollbackFailures ?? 0) + rollbackErrors
            }
        }
    }

    func handleEngineExit(
        engineName: String,
        exitCode: Int32,
        keyPath: WritableKeyPath<TunnelRuntimeState, Bool>
    ) {
        runtimeStateStore.updateState {
            $0[keyPath: keyPath] = false
            if exitCode != 0 {
                $0.runtimeStats.lastError = "\(engineName) exited with code \(exitCode)"
            }
        }
        persistSnapshotBestEffort()
        appendLogBestEffort("\(engineName) exited with code \(exitCode)")
    }

    private struct EngineStopResult {
        let didStop: Bool
        let errorMessage: String?
    }

    private func stopDataPlane(context: String) -> DataPlaneStopResult {
        guard let dataPlane = runtimeStateStore.currentActiveDataPlane() else {
            return DataPlaneStopResult(didStop: true, errorMessage: nil)
        }
        let mode = dataPlane.mode.rawValue
        let result = dataPlane.stop(
            context: context,
            log: { [weak self] line in
                self?.appendLogBestEffort(line)
            }
        )
        if !result.didStop {
            logger.error("\(context, privacy: .public) data-plane stop failed mode=\(mode, privacy: .public)")
            appendLogBestEffort("\(context) data-plane stop failed mode=\(mode)")
            runtimeStateStore.updateState {
                $0.runtimeStats.dataPlaneStopFailures = ($0.runtimeStats.dataPlaneStopFailures ?? 0) + 1
            }
        }
        return result
    }

    private func stopByeDPIWithTimeouts(context: String) -> EngineStopResult {
        do {
            try byedpiEngine.requestStop()
            let stopped = byedpiEngine.waitForExit(timeout: Self.gracefulStopTimeoutSeconds)
            if stopped {
                appendLogBestEffort("ByeDPI stopped")
                return EngineStopResult(didStop: true, errorMessage: nil)
            }

            appendLogBestEffort("ByeDPI did not stop within \(Int(Self.gracefulStopTimeoutSeconds))s, forcing shutdown")
            byedpiEngine.forceStop()
            let forceStopped = byedpiEngine.waitForExit(timeout: Self.forcedStopTimeoutSeconds)
            if forceStopped {
                appendLogBestEffort("ByeDPI stopped after force-stop")
                return EngineStopResult(didStop: true, errorMessage: nil)
            } else {
                let message = "ByeDPI did not exit after force-stop"
                logger.error("\(context, privacy: .public) ByeDPI stop timeout")
                appendLogBestEffort(message)
                return EngineStopResult(didStop: false, errorMessage: message)
            }
        } catch {
            logger.error("\(context, privacy: .public) ByeDPI stop failed: \(error.localizedDescription, privacy: .public)")
            appendLogBestEffort("ByeDPI stop failed: \(error.localizedDescription)")
            byedpiEngine.forceStop()
            if byedpiEngine.waitForExit(timeout: Self.forcedStopTimeoutSeconds) {
                appendLogBestEffort("ByeDPI force-stopped after error")
                return EngineStopResult(didStop: true, errorMessage: nil)
            } else {
                let message = "ByeDPI did not exit after force-stop following stop error"
                appendLogBestEffort(message)
                return EngineStopResult(didStop: false, errorMessage: message)
            }
        }
    }

    private func appendLogBestEffort(_ line: String) {
        persistenceService.appendLog(line)
    }

    private func persistSnapshotBestEffort() {
        let snapshot = runtimeStateStore.makePersistentSnapshot(now: Date())
        persistenceService.persistSnapshot(state: snapshot.state, stats: snapshot.stats)
    }
}
