import Foundation

final class TunnelRuntimeStatsService {
    private let runtimeStateStore: TunnelRuntimeStateStoring

    init(runtimeStateStore: TunnelRuntimeStateStoring) {
        self.runtimeStateStore = runtimeStateStore
    }

    func collectStats(now: Date = Date()) -> RuntimeStats {
        var snapshot = runtimeStateStore.withState { $0.runtimeStats }
        let startedAt = runtimeStateStore.withState { $0.startedAt }
        let implementationMode = runtimeStateStore.withState { $0.implementationMode }
        snapshot.startupImplementationMode = implementationMode.rawValue
        if let startedAt {
            snapshot.uptimeSeconds = now.timeIntervalSince(startedAt)
        }

        guard let dataPlaneSnapshot = runtimeStateStore.activeDataPlaneSnapshot() else {
            return snapshot
        }

        apply(dataPlaneSnapshot, to: &snapshot)
        runtimeStateStore.updateState {
            var runtimeStats = $0.runtimeStats
            runtimeStats.uptimeSeconds = snapshot.uptimeSeconds
            apply(dataPlaneSnapshot, to: &runtimeStats)
            runtimeStats.startupImplementationMode = $0.implementationMode.rawValue
            $0.runtimeStats = runtimeStats
        }
        return snapshot
    }

    private func apply(_ dataPlaneSnapshot: DataPlaneTrafficSnapshot, to stats: inout RuntimeStats) {
        stats.bytesIn = dataPlaneSnapshot.bytesIn
        stats.bytesOut = dataPlaneSnapshot.bytesOut
        stats.packetsIn = dataPlaneSnapshot.packetsIn
        stats.packetsOut = dataPlaneSnapshot.packetsOut
        stats.parseFailures = dataPlaneSnapshot.parseFailures
        stats.tcpConnectAttempts = dataPlaneSnapshot.tcpConnectAttempts
        stats.tcpConnectFailures = dataPlaneSnapshot.tcpConnectFailures
        stats.tcpSendAttempts = dataPlaneSnapshot.tcpSendAttempts
        stats.tcpSendFailures = dataPlaneSnapshot.tcpSendFailures
        stats.tcpBackpressureDrops = dataPlaneSnapshot.tcpBackpressureDrops
        stats.tcpActiveSessions = dataPlaneSnapshot.tcpActiveSessions
        stats.tcpSessionCloseTotal = dataPlaneSnapshot.tcpSessionCloseTotal
        stats.tcpSessionCloseStateClose = dataPlaneSnapshot.tcpSessionCloseStateClose
        stats.tcpSessionCloseSendFailed = dataPlaneSnapshot.tcpSessionCloseSendFailed
        stats.tcpSessionCloseRemoteClosed = dataPlaneSnapshot.tcpSessionCloseRemoteClosed
        stats.tcpSessionCloseBackpressureDrop = dataPlaneSnapshot.tcpSessionCloseBackpressureDrop
        stats.tcpSessionCloseRelayStop = dataPlaneSnapshot.tcpSessionCloseRelayStop
        stats.udpAssociateAttempts = dataPlaneSnapshot.udpAssociateAttempts
        stats.udpAssociateFailures = dataPlaneSnapshot.udpAssociateFailures
        stats.udpTxPackets = dataPlaneSnapshot.udpTxPackets
        stats.udpRxPackets = dataPlaneSnapshot.udpRxPackets
        stats.udpTxFailures = dataPlaneSnapshot.udpTxFailures
        stats.udpBackpressureDrops = dataPlaneSnapshot.udpBackpressureDrops
        stats.udpActiveSessions = dataPlaneSnapshot.udpActiveSessions
        stats.dnsRoutedCount = dataPlaneSnapshot.dnsRoutedCount
        stats.udpSessionCloseTotal = dataPlaneSnapshot.udpSessionCloseTotal
        stats.udpSessionCloseAssociateClosed = dataPlaneSnapshot.udpSessionCloseAssociateClosed
        stats.udpSessionCloseAssociateFailed = dataPlaneSnapshot.udpSessionCloseAssociateFailed
        stats.udpSessionCloseSendFailed = dataPlaneSnapshot.udpSessionCloseSendFailed
        stats.udpSessionCloseBackpressureDrop = dataPlaneSnapshot.udpSessionCloseBackpressureDrop
        stats.udpSessionCloseIdleCleanup = dataPlaneSnapshot.udpSessionCloseIdleCleanup
        stats.udpSessionCloseRelayStop = dataPlaneSnapshot.udpSessionCloseRelayStop
        if stats.uptimeSeconds > 0 {
            let totalBytes = Double(stats.bytesIn + stats.bytesOut)
            stats.totalThroughputBytesPerSecond = totalBytes / stats.uptimeSeconds
        } else {
            stats.totalThroughputBytesPerSecond = nil
        }
    }
}
