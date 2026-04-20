import Foundation

protocol TunnelRuntimeStateStoring: AnyObject {
    var providerState: ProviderState { get }

    func withState<T>(_ block: (TunnelRuntimeState) -> T) -> T
    func updateState(_ block: (inout TunnelRuntimeState) -> Void)
    func setActiveDataPlane(_ dataPlane: TunnelDataPlane?)
    func currentActiveDataPlane() -> TunnelDataPlane?
    func activeDataPlaneSnapshot() -> DataPlaneTrafficSnapshot?
    func makePersistentSnapshot(now: Date) -> (state: ProviderState, stats: RuntimeStats)
}

final class TunnelRuntimeStateRepository: TunnelRuntimeStateStoring {
    private let stateQueue = DispatchQueue(label: "com.uvays.FlowGuard.tunnel-runtime.state")
    private var state = TunnelRuntimeState()
    private var activeDataPlane: TunnelDataPlane?

    var providerState: ProviderState {
        withState { $0.providerState }
    }

    func withState<T>(_ block: (TunnelRuntimeState) -> T) -> T {
        stateQueue.sync { block(state) }
    }

    func updateState(_ block: (inout TunnelRuntimeState) -> Void) {
        stateQueue.sync { block(&state) }
    }

    func setActiveDataPlane(_ dataPlane: TunnelDataPlane?) {
        stateQueue.sync { activeDataPlane = dataPlane }
    }

    func currentActiveDataPlane() -> TunnelDataPlane? {
        stateQueue.sync { activeDataPlane }
    }

    func activeDataPlaneSnapshot() -> DataPlaneTrafficSnapshot? {
        stateQueue.sync {
            activeDataPlane?.collectTrafficSnapshot()
        }
    }

    func makePersistentSnapshot(now: Date = Date()) -> (state: ProviderState, stats: RuntimeStats) {
        withState { currentState in
            var stats = currentState.runtimeStats
            if let startedAt = currentState.startedAt {
                stats.uptimeSeconds = now.timeIntervalSince(startedAt)
            }
            return (currentState.providerState, stats)
        }
    }
}

struct TunnelRuntimeState {
    var providerState: ProviderState = .disconnected
    var runtimeStats: RuntimeStats = .empty
    var startedAt: Date?
    var activeProfile: TunnelProfile = .default
    var implementationMode: TunnelImplementationMode = .legacyTunFD
    var tunInterfaceName: String?
    var baselineBytesIn: UInt64 = 0
    var baselineBytesOut: UInt64 = 0
    var isByeDPIRunning = false
    var isDataPlaneRunning = false
}
