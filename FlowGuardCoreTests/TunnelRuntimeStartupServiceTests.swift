import Foundation
import NetworkExtension
import OSLog
import XCTest
@testable import FlowGuardTunnel

final class TunnelRuntimeStartupServiceTests: XCTestCase {
    func testStartHappyPathSetsRunningState() async throws {
        let deps = makeDependencies()
        let profile = makeProfile(socksPort: 1080)

        try await deps.startup.start(
            profile: profile,
            implementationMode: .packetFlowPreferred,
            packetFlow: nil,
            applyNetworkSettingsHandler: { _ in true }
        )

        let state = deps.stateStore.withState { $0 }
        XCTAssertEqual(state.providerState, .running)
        XCTAssertTrue(state.isByeDPIRunning)
        XCTAssertTrue(state.isDataPlaneRunning)
        XCTAssertEqual(state.activeProfile.socksPort, 1080)
        XCTAssertNotNil(state.startedAt)
        XCTAssertNotNil(deps.stateStore.currentActiveDataPlane())
        XCTAssertEqual(deps.dataPlane.startCallCount, 1)
        XCTAssertEqual(deps.persistence.snapshots.last?.state, .running)
    }

    func testStartWhenPreferredPortBusyUsesFallbackAndUpdatesActiveProfile() async throws {
        let deps = makeDependencies(portAllocator: MockPortAllocator(resolvedPort: 1083))
        let profile = makeProfile(socksPort: 1080)

        try await deps.startup.start(
            profile: profile,
            implementationMode: .packetFlowPreferred,
            packetFlow: nil,
            applyNetworkSettingsHandler: { _ in true }
        )

        let state = deps.stateStore.withState { $0 }
        XCTAssertEqual(state.providerState, .running)
        XCTAssertEqual(state.activeProfile.socksPort, 1083)
        XCTAssertEqual(deps.byeDPI.startedPort, 1083)
        XCTAssertTrue(deps.persistence.logs.contains { $0.contains("switched to 1083") })
    }

    func testStartWhenApplyNetworkSettingsFailsThrowsAndMarksFailed() async {
        let deps = makeDependencies()

        do {
            try await deps.startup.start(
                profile: makeProfile(),
                implementationMode: .packetFlowPreferred,
                packetFlow: nil,
                applyNetworkSettingsHandler: { _ in false }
            )
            XCTFail("Expected networkSettingsFailed")
        } catch let error as TunnelRuntimeError {
            guard case .networkSettingsFailed = error else {
                XCTFail("Expected networkSettingsFailed, got \(error)")
                return
            }
        } catch {
            XCTFail("Expected TunnelRuntimeError, got \(error)")
        }

        let state = deps.stateStore.withState { $0 }
        XCTAssertEqual(state.providerState, .failed)
        XCTAssertFalse(state.isByeDPIRunning)
        XCTAssertFalse(state.isDataPlaneRunning)
        XCTAssertEqual(deps.byeDPI.startCallCount, 0)
        XCTAssertEqual(deps.persistence.snapshots.last?.state, .failed)
    }

    func testStartWhenByeDPIExitsBeforeSocksReadyThrowsByeDPIExited() async {
        let deps = makeDependencies(socksMonitor: MockSocksMonitor(result: .exited(42)))

        do {
            try await deps.startup.start(
                profile: makeProfile(),
                implementationMode: .packetFlowPreferred,
                packetFlow: nil,
                applyNetworkSettingsHandler: { _ in true }
            )
            XCTFail("Expected byeDPIExited")
        } catch let error as TunnelRuntimeError {
            guard case let .byeDPIExited(code) = error else {
                XCTFail("Expected byeDPIExited, got \(error)")
                return
            }
            XCTAssertEqual(code, 42)
        } catch {
            XCTFail("Expected TunnelRuntimeError, got \(error)")
        }

        let state = deps.stateStore.withState { $0 }
        XCTAssertEqual(state.providerState, .failed)
        XCTAssertFalse(state.isByeDPIRunning)
        XCTAssertEqual(deps.byeDPI.requestStopCallCount, 1)
        XCTAssertEqual(deps.dataPlane.startCallCount, 0)
    }

    func testStartWhenSocksReadinessTimeoutThrowsSocksEndpointUnavailable() async {
        let deps = makeDependencies(
            portAllocator: MockPortAllocator(resolvedPort: 1099),
            socksMonitor: MockSocksMonitor(result: .timeout)
        )

        do {
            try await deps.startup.start(
                profile: makeProfile(socksPort: 1099),
                implementationMode: .packetFlowPreferred,
                packetFlow: nil,
                applyNetworkSettingsHandler: { _ in true }
            )
            XCTFail("Expected socksEndpointUnavailable")
        } catch let error as TunnelRuntimeError {
            guard case let .socksEndpointUnavailable(port) = error else {
                XCTFail("Expected socksEndpointUnavailable, got \(error)")
                return
            }
            XCTAssertEqual(port, 1099)
        } catch {
            XCTFail("Expected TunnelRuntimeError, got \(error)")
        }

        let state = deps.stateStore.withState { $0 }
        XCTAssertEqual(state.providerState, .failed)
        XCTAssertFalse(state.isByeDPIRunning)
        XCTAssertEqual(deps.byeDPI.requestStopCallCount, 1)
        XCTAssertEqual(deps.dataPlane.startCallCount, 0)
    }

    func testStartWhenDataPlaneStartFailsRollsBackAndMarksFailed() async {
        let startError = MockDataPlaneError.startFailed
        let dataPlane = MockDataPlane(startError: startError)
        let deps = makeDependencies(dataPlane: dataPlane)

        do {
            try await deps.startup.start(
                profile: makeProfile(),
                implementationMode: .packetFlowPreferred,
                packetFlow: nil,
                applyNetworkSettingsHandler: { _ in true }
            )
            XCTFail("Expected start failure")
        } catch let error as MockDataPlaneError {
            XCTAssertEqual(error, .startFailed)
        } catch {
            XCTFail("Expected MockDataPlaneError, got \(error)")
        }

        let state = deps.stateStore.withState { $0 }
        XCTAssertEqual(state.providerState, .failed)
        XCTAssertFalse(state.isByeDPIRunning)
        XCTAssertFalse(state.isDataPlaneRunning)
        XCTAssertNil(deps.stateStore.currentActiveDataPlane())
        XCTAssertEqual(deps.byeDPI.requestStopCallCount, 1)
        XCTAssertEqual(deps.persistence.snapshots.last?.state, .failed)
    }

    func testLifecycleRollbackOnPartialStartupClearsRunningFlags() {
        let dataPlane = MockDataPlane()
        let stateStore = TunnelRuntimeStateRepository()
        let byeDPI = MockByeDPIEngine(waitForExitResult: true)
        let persistence = MockPersistenceService()
        let lifecycle = TunnelRuntimeLifecycleService(
            logger: Logger(subsystem: "FlowGuardCoreTests", category: "Lifecycle"),
            byedpiEngine: byeDPI,
            runtimeStateStore: stateStore,
            persistenceService: persistence
        )

        stateStore.setActiveDataPlane(dataPlane)
        stateStore.updateState {
            $0.providerState = .starting
            $0.isByeDPIRunning = true
            $0.isDataPlaneRunning = true
        }

        lifecycle.rollbackStartup(didStartByeDPI: true, didStartDataPlane: true)

        let state = stateStore.withState { $0 }
        XCTAssertFalse(state.isByeDPIRunning)
        XCTAssertFalse(state.isDataPlaneRunning)
        XCTAssertNil(stateStore.currentActiveDataPlane())
        XCTAssertEqual(dataPlane.stopCallCount, 1)
        XCTAssertEqual(byeDPI.requestStopCallCount, 1)
    }

    private func makeDependencies(
        portAllocator: MockPortAllocator = MockPortAllocator(resolvedPort: 1080),
        socksMonitor: MockSocksMonitor = MockSocksMonitor(result: .ready),
        dataPlane: MockDataPlane = MockDataPlane()
    ) -> StartupDependencies {
        let stateStore = TunnelRuntimeStateRepository()
        let byeDPI = MockByeDPIEngine(waitForExitResult: true)
        let persistence = MockPersistenceService()
        let lifecycle = TunnelRuntimeLifecycleService(
            logger: Logger(subsystem: "FlowGuardCoreTests", category: "Startup"),
            byedpiEngine: byeDPI,
            runtimeStateStore: stateStore,
            persistenceService: persistence
        )

        let startup = TunnelRuntimeStartupService(
            byedpiEngine: byeDPI,
            dataPlaneFactory: { _ in dataPlane },
            networkSettingsBuilder: MockNetworkSettingsBuilder(),
            portAllocator: portAllocator,
            socksEndpointMonitor: socksMonitor,
            runtimeStateStore: stateStore,
            lifecycleService: lifecycle,
            persistenceService: persistence
        )

        return StartupDependencies(
            startup: startup,
            stateStore: stateStore,
            persistence: persistence,
            byeDPI: byeDPI,
            dataPlane: dataPlane
        )
    }

    private func makeProfile(socksPort: Int = 1080) -> TunnelProfile {
        TunnelProfile(
            socksPort: socksPort,
            dnsMode: .system,
            ipv6Enabled: true,
            preset: .balanced,
            customArguments: ["--test-arg"]
        )
    }
}

private struct StartupDependencies {
    let startup: TunnelRuntimeStartupService
    let stateStore: TunnelRuntimeStateRepository
    let persistence: MockPersistenceService
    let byeDPI: MockByeDPIEngine
    let dataPlane: MockDataPlane
}

private final class MockPersistenceService: TunnelRuntimePersisting {
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
        logs.joined(separator: "\n")
    }
}

private struct MockNetworkSettingsBuilder: TunnelNetworkSettingsBuilding {
    func makeNetworkSettings(profile: TunnelProfile) -> NEPacketTunnelNetworkSettings {
        _ = profile
        return NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "127.0.0.1")
    }
}

private struct MockPortAllocator: LocalhostPortAllocating {
    let resolvedPort: Int?

    func resolveAvailablePort(preferred: Int, scanWindow: Int) -> Int? {
        _ = preferred
        _ = scanWindow
        return resolvedPort
    }
}

private struct MockSocksMonitor: LocalSocksEndpointMonitoring {
    let result: LocalSocksReadiness

    func waitUntilReady(
        port: Int,
        attempts: Int,
        delayMicroseconds: useconds_t,
        exitCode: () -> Int32?
    ) -> LocalSocksReadiness {
        _ = port
        _ = attempts
        _ = delayMicroseconds
        _ = exitCode
        return result
    }
}

private final class MockByeDPIEngine: ByeDPIEngine {
    private let waitForExitResult: Bool
    private(set) var startCallCount = 0
    private(set) var requestStopCallCount = 0
    private(set) var forceStopCallCount = 0
    private(set) var startedPort: Int?

    init(waitForExitResult: Bool) {
        self.waitForExitResult = waitForExitResult
    }

    func start(arguments: [String], socksPort: Int, onExit: @escaping (Int32) -> Void) throws {
        _ = arguments
        _ = onExit
        startCallCount += 1
        startedPort = socksPort
    }

    func requestStop() throws {
        requestStopCallCount += 1
    }

    func waitForExit(timeout: TimeInterval) -> Bool {
        _ = timeout
        return waitForExitResult
    }

    func forceStop() {
        forceStopCallCount += 1
    }
}

private enum MockDataPlaneError: Error {
    case startFailed
}

private final class MockDataPlane: TunnelDataPlane {
    let mode: TunnelImplementationMode = .packetFlowPreferred
    private let startError: MockDataPlaneError?

    private(set) var isRunning = false
    private(set) var startCallCount = 0
    private(set) var stopCallCount = 0

    init(startError: MockDataPlaneError? = nil) {
        self.startError = startError
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
        startCallCount += 1

        if let startError {
            throw startError
        }

        isRunning = true
        return DataPlaneStartResult(tunInterfaceName: "utun-test", baselineBytesIn: 11, baselineBytesOut: 22)
    }

    func stop(
        context: String,
        log: @escaping (String) -> Void
    ) -> DataPlaneStopResult {
        _ = context
        _ = log
        stopCallCount += 1
        isRunning = false
        return DataPlaneStopResult(didStop: true, errorMessage: nil)
    }

    func collectTrafficSnapshot() -> DataPlaneTrafficSnapshot? {
        nil
    }
}
