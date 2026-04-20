import Foundation

struct RuntimeStats: Codable, Sendable {
    var uptimeSeconds: TimeInterval
    var bytesIn: Int64
    var bytesOut: Int64
    var selectedPreset: ByeDPIPreset
    var lastError: String?
    var startupDurationMs: Int64? = nil
    var startupImplementationMode: String? = nil
    var totalThroughputBytesPerSecond: Double? = nil
    var packetsIn: Int64? = nil
    var packetsOut: Int64? = nil
    var parseFailures: Int64? = nil
    var tcpConnectAttempts: Int64? = nil
    var tcpConnectFailures: Int64? = nil
    var tcpSendAttempts: Int64? = nil
    var tcpSendFailures: Int64? = nil
    var tcpBackpressureDrops: Int64? = nil
    var tcpActiveSessions: Int64? = nil
    var tcpSessionCloseTotal: Int64? = nil
    var tcpSessionCloseStateClose: Int64? = nil
    var tcpSessionCloseSendFailed: Int64? = nil
    var tcpSessionCloseRemoteClosed: Int64? = nil
    var tcpSessionCloseBackpressureDrop: Int64? = nil
    var tcpSessionCloseRelayStop: Int64? = nil
    var udpAssociateAttempts: Int64? = nil
    var udpAssociateFailures: Int64? = nil
    var udpTxPackets: Int64? = nil
    var udpRxPackets: Int64? = nil
    var udpTxFailures: Int64? = nil
    var udpBackpressureDrops: Int64? = nil
    var udpActiveSessions: Int64? = nil
    var dnsRoutedCount: Int64? = nil
    var udpSessionCloseTotal: Int64? = nil
    var udpSessionCloseAssociateClosed: Int64? = nil
    var udpSessionCloseAssociateFailed: Int64? = nil
    var udpSessionCloseSendFailed: Int64? = nil
    var udpSessionCloseBackpressureDrop: Int64? = nil
    var udpSessionCloseIdleCleanup: Int64? = nil
    var udpSessionCloseRelayStop: Int64? = nil
    var lifecycleStopAttempts: Int64? = nil
    var lifecycleStopFailures: Int64? = nil
    var lifecycleRollbackAttempts: Int64? = nil
    var lifecycleRollbackFailures: Int64? = nil
    var dataPlaneStopFailures: Int64? = nil

    static let empty = RuntimeStats(
        uptimeSeconds: 0,
        bytesIn: 0,
        bytesOut: 0,
        selectedPreset: .balanced,
        lastError: nil
    )
}
