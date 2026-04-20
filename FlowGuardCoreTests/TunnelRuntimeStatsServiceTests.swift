import Foundation
import NetworkExtension
import XCTest

final class TunnelRuntimeStatsServiceTests: XCTestCase {
    func testCollectStatsMapsExtendedDataPlaneCounters() {
        let store = TunnelRuntimeStateRepository()
        store.updateState {
            $0.implementationMode = .legacyTunFD
            $0.startedAt = Date(timeIntervalSince1970: 100)
        }
        let dataPlane = StatsMockDataPlane(snapshot: DataPlaneTrafficSnapshot(
            bytesIn: 100,
            bytesOut: 200,
            packetsIn: 10,
            packetsOut: 20,
            parseFailures: 3,
            tcpConnectAttempts: 4,
            tcpConnectFailures: 1,
            tcpSendAttempts: 8,
            tcpSendFailures: 2,
            tcpBackpressureDrops: 5,
            tcpActiveSessions: 6,
            tcpSessionCloseTotal: 7,
            tcpSessionCloseStateClose: 1,
            tcpSessionCloseSendFailed: 2,
            tcpSessionCloseRemoteClosed: 1,
            tcpSessionCloseBackpressureDrop: 2,
            tcpSessionCloseRelayStop: 1,
            udpAssociateAttempts: 9,
            udpAssociateFailures: 3,
            udpTxPackets: 11,
            udpRxPackets: 12,
            udpTxFailures: 4,
            udpBackpressureDrops: 2,
            udpActiveSessions: 13,
            dnsRoutedCount: 14,
            udpSessionCloseTotal: 15,
            udpSessionCloseAssociateClosed: 3,
            udpSessionCloseAssociateFailed: 4,
            udpSessionCloseSendFailed: 2,
            udpSessionCloseBackpressureDrop: 1,
            udpSessionCloseIdleCleanup: 3,
            udpSessionCloseRelayStop: 2
        ))
        store.setActiveDataPlane(dataPlane)

        let service = TunnelRuntimeStatsService(runtimeStateStore: store)
        let stats = service.collectStats(now: Date(timeIntervalSince1970: 200))

        XCTAssertEqual(stats.tcpBackpressureDrops, 5)
        XCTAssertEqual(stats.tcpSessionCloseTotal, 7)
        XCTAssertEqual(stats.tcpSessionCloseStateClose, 1)
        XCTAssertEqual(stats.tcpSessionCloseSendFailed, 2)
        XCTAssertEqual(stats.tcpSessionCloseRemoteClosed, 1)
        XCTAssertEqual(stats.tcpSessionCloseBackpressureDrop, 2)
        XCTAssertEqual(stats.tcpSessionCloseRelayStop, 1)
        XCTAssertEqual(stats.udpBackpressureDrops, 2)
        XCTAssertEqual(stats.udpSessionCloseTotal, 15)
        XCTAssertEqual(stats.udpSessionCloseAssociateClosed, 3)
        XCTAssertEqual(stats.udpSessionCloseAssociateFailed, 4)
        XCTAssertEqual(stats.udpSessionCloseSendFailed, 2)
        XCTAssertEqual(stats.udpSessionCloseBackpressureDrop, 1)
        XCTAssertEqual(stats.udpSessionCloseIdleCleanup, 3)
        XCTAssertEqual(stats.udpSessionCloseRelayStop, 2)
        XCTAssertEqual(stats.startupImplementationMode, TunnelImplementationMode.legacyTunFD.rawValue)
        XCTAssertEqual(stats.totalThroughputBytesPerSecond ?? -1, 3.0, accuracy: 0.0001)

        let persisted = store.withState { $0.runtimeStats }
        XCTAssertEqual(persisted.tcpSessionCloseTotal, 7)
        XCTAssertEqual(persisted.udpSessionCloseTotal, 15)
        XCTAssertEqual(persisted.startupImplementationMode, TunnelImplementationMode.legacyTunFD.rawValue)
        XCTAssertEqual(persisted.totalThroughputBytesPerSecond ?? -1, 3.0, accuracy: 0.0001)
    }
}

private final class StatsMockDataPlane: TunnelDataPlane {
    let mode: TunnelImplementationMode = .packetFlowPreferred
    var isRunning: Bool = true
    private let snapshot: DataPlaneTrafficSnapshot?

    init(snapshot: DataPlaneTrafficSnapshot?) {
        self.snapshot = snapshot
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
        isRunning = false
        return DataPlaneStopResult(didStop: true, errorMessage: nil)
    }

    func collectTrafficSnapshot() -> DataPlaneTrafficSnapshot? {
        snapshot
    }
}
