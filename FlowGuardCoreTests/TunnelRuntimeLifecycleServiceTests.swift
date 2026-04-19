import Foundation
import NetworkExtension
import OSLog
import XCTest
@testable import FlowGuardTunnel

final class TunnelRuntimeLifecycleServiceTests: XCTestCase {
    func testStopSuccessfulShutdownSetsDisconnectedAndClearsActiveDataPlane() {
        let dataPlane = LifecycleMockDataPlane(stopResult: DataPlaneStopResult(didStop: true, errorMessage: nil))
        let byeDPI = LifecycleMockByeDPIEngine(waitResults: [true])
        let stateStore = TunnelRuntimeStateRepository()
        let persistence = LifecycleMockPersistenceService()
        let lifecycle = makeLifecycle(
            byeDPI: byeDPI,
            stateStore: stateStore,
            persistence: persistence
        )

        stateStore.setActiveDataPlane(dataPlane)
        stateStore.updateState {
            $0.providerState = .running
            $0.startedAt = Date(timeIntervalSince1970: 123)
            $0.tunInterfaceName = "utun9"
            $0.baselineBytesIn = 100
            $0.baselineBytesOut = 200
            $0.runtimeStats.uptimeSeconds = 5
            $0.runtimeStats.lastError = "old"
            $0.isDataPlaneRunning = true
            $0.isByeDPIRunning = true
        }

        lifecycle.stop()

        let state = stateStore.withState { $0 }
        XCTAssertEqual(state.providerState, .disconnected)
        XCTAssertFalse(state.isDataPlaneRunning)
        XCTAssertFalse(state.isByeDPIRunning)
        XCTAssertNil(state.startedAt)
        XCTAssertNil(state.tunInterfaceName)
        XCTAssertEqual(state.baselineBytesIn, 0)
        XCTAssertEqual(state.baselineBytesOut, 0)
        XCTAssertEqual(state.runtimeStats.uptimeSeconds, 0)
        XCTAssertNil(state.runtimeStats.lastError)
        XCTAssertEqual(state.runtimeStats.lifecycleStopAttempts, 1)
        XCTAssertEqual(state.runtimeStats.lifecycleStopFailures, nil)
        XCTAssertEqual(state.runtimeStats.dataPlaneStopFailures, nil)
        XCTAssertNil(stateStore.currentActiveDataPlane())
        XCTAssertEqual(dataPlane.stopCallCount, 1)
        XCTAssertEqual(byeDPI.requestStopCallCount, 1)
        XCTAssertEqual(persistence.snapshots.last?.state, .disconnected)
    }

    func testStopWhenByeDpiDoesNotStopMarksFailedAndKeepsRunningFlag() {
        let byeDPI = LifecycleMockByeDPIEngine(waitResults: [false, false])
        let stateStore = TunnelRuntimeStateRepository()
        let persistence = LifecycleMockPersistenceService()
        let lifecycle = makeLifecycle(
            byeDPI: byeDPI,
            stateStore: stateStore,
            persistence: persistence
        )

        stateStore.updateState {
            $0.providerState = .running
            $0.isByeDPIRunning = true
        }

        lifecycle.stop()

        let state = stateStore.withState { $0 }
        XCTAssertEqual(state.providerState, .failed)
        XCTAssertTrue(state.isByeDPIRunning)
        XCTAssertEqual(byeDPI.requestStopCallCount, 1)
        XCTAssertEqual(byeDPI.forceStopCallCount, 1)
        XCTAssertEqual(state.runtimeStats.lastError, "ByeDPI did not exit after force-stop")
        XCTAssertEqual(state.runtimeStats.lifecycleStopAttempts, 1)
        XCTAssertEqual(state.runtimeStats.lifecycleStopFailures, 1)
        XCTAssertEqual(persistence.snapshots.last?.state, .failed)
    }

    func testRollbackOnPartialStartupClearsRunningFlagsAndActiveDataPlane() {
        let dataPlane = LifecycleMockDataPlane(stopResult: DataPlaneStopResult(didStop: true, errorMessage: nil))
        let byeDPI = LifecycleMockByeDPIEngine(waitResults: [true])
        let stateStore = TunnelRuntimeStateRepository()
        let lifecycle = makeLifecycle(
            byeDPI: byeDPI,
            stateStore: stateStore,
            persistence: LifecycleMockPersistenceService()
        )

        stateStore.setActiveDataPlane(dataPlane)
        stateStore.updateState {
            $0.providerState = .starting
            $0.isDataPlaneRunning = true
            $0.isByeDPIRunning = true
        }

        lifecycle.rollbackStartup(didStartByeDPI: true, didStartDataPlane: true)

        let state = stateStore.withState { $0 }
        XCTAssertFalse(state.isDataPlaneRunning)
        XCTAssertFalse(state.isByeDPIRunning)
        XCTAssertNil(stateStore.currentActiveDataPlane())
        XCTAssertEqual(dataPlane.stopCallCount, 1)
        XCTAssertEqual(byeDPI.requestStopCallCount, 1)
        XCTAssertEqual(state.runtimeStats.lifecycleRollbackAttempts, 1)
        XCTAssertEqual(state.runtimeStats.lifecycleRollbackFailures, nil)
    }

    func testStopKeepsActiveDataPlaneWhenDataPlaneDidNotStop() {
        let dataPlane = LifecycleMockDataPlane(stopResult: DataPlaneStopResult(didStop: false, errorMessage: "stop timeout"))
        let stateStore = TunnelRuntimeStateRepository()
        let lifecycle = makeLifecycle(
            byeDPI: LifecycleMockByeDPIEngine(waitResults: [true]),
            stateStore: stateStore,
            persistence: LifecycleMockPersistenceService()
        )

        stateStore.setActiveDataPlane(dataPlane)
        stateStore.updateState {
            $0.providerState = .running
            $0.isDataPlaneRunning = true
        }

        lifecycle.stop()

        let state = stateStore.withState { $0 }
        XCTAssertEqual(state.providerState, .failed)
        XCTAssertTrue(state.isDataPlaneRunning)
        XCTAssertNotNil(stateStore.currentActiveDataPlane())
        XCTAssertEqual(state.runtimeStats.lifecycleStopAttempts, 1)
        XCTAssertEqual(state.runtimeStats.lifecycleStopFailures, 1)
        XCTAssertEqual(state.runtimeStats.dataPlaneStopFailures, 1)
    }

    private func makeLifecycle(
        byeDPI: LifecycleMockByeDPIEngine,
        stateStore: TunnelRuntimeStateRepository,
        persistence: LifecycleMockPersistenceService
    ) -> TunnelRuntimeLifecycleService {
        TunnelRuntimeLifecycleService(
            logger: Logger(subsystem: "FlowGuardCoreTests", category: "Lifecycle"),
            byedpiEngine: byeDPI,
            runtimeStateStore: stateStore,
            persistenceService: persistence
        )
    }
}

private final class LifecycleMockPersistenceService: TunnelRuntimePersisting {
    private(set) var snapshots: [(state: ProviderState, stats: RuntimeStats)] = []
    private(set) var logs: [String] = []

    func loadProfile() throws -> TunnelProfile? {
        nil
    }

    func persistSnapshot(state: ProviderState, stats: RuntimeStats) {
        snapshots.append((state: state, stats: stats))
    }

    func appendLog(_ line: String) {
        logs.append(line)
    }

    func readLogPreview(maxBytes: Int) -> String {
        _ = maxBytes
        return logs.joined(separator: "\n")
    }
}

private final class LifecycleMockByeDPIEngine: ByeDPIEngine {
    private var waitResults: [Bool]

    private(set) var requestStopCallCount = 0
    private(set) var forceStopCallCount = 0

    init(waitResults: [Bool]) {
        self.waitResults = waitResults
    }

    func start(arguments: [String], socksPort: Int, onExit: @escaping (Int32) -> Void) throws {
        _ = arguments
        _ = socksPort
        _ = onExit
    }

    func requestStop() throws {
        requestStopCallCount += 1
    }

    func waitForExit(timeout: TimeInterval) -> Bool {
        _ = timeout
        if waitResults.isEmpty {
            return false
        }
        return waitResults.removeFirst()
    }

    func forceStop() {
        forceStopCallCount += 1
    }
}

private final class LifecycleMockDataPlane: TunnelDataPlane {
    let mode: TunnelImplementationMode = .packetFlowPreferred
    private let stopResult: DataPlaneStopResult

    private(set) var isRunning = true
    private(set) var stopCallCount = 0

    init(stopResult: DataPlaneStopResult) {
        self.stopResult = stopResult
    }

    func start(
        profile: TunnelProfile,
        packetFlow: NEPacketTunnelFlow?,
        onExit: @escaping (Int32) -> Void,
        log: @escaping (String) -> Void
    ) throws -> DataPlaneStartResult {
        _ = profile
        _ = packetFlow
        _ = onExit
        _ = log
        return DataPlaneStartResult(tunInterfaceName: nil, baselineBytesIn: 0, baselineBytesOut: 0)
    }

    func stop(
        context: String,
        log: @escaping (String) -> Void
    ) -> DataPlaneStopResult {
        _ = context
        _ = log
        stopCallCount += 1
        isRunning = !stopResult.didStop
        return stopResult
    }

    func collectTrafficSnapshot() -> DataPlaneTrafficSnapshot? {
        nil
    }
}
