import Foundation

struct RuntimeStats: Codable, Sendable {
    var uptimeSeconds: TimeInterval
    var bytesIn: Int64
    var bytesOut: Int64
    var selectedPreset: ByeDPIPreset
    var lastError: String?
    var packetsIn: Int64? = nil
    var packetsOut: Int64? = nil
    var parseFailures: Int64? = nil
    var tcpConnectAttempts: Int64? = nil
    var tcpConnectFailures: Int64? = nil
    var tcpSendAttempts: Int64? = nil
    var tcpSendFailures: Int64? = nil
    var tcpActiveSessions: Int64? = nil
    var udpAssociateAttempts: Int64? = nil
    var udpAssociateFailures: Int64? = nil
    var udpTxPackets: Int64? = nil
    var udpRxPackets: Int64? = nil
    var udpTxFailures: Int64? = nil
    var udpActiveSessions: Int64? = nil
    var dnsRoutedCount: Int64? = nil

    static let empty = RuntimeStats(
        uptimeSeconds: 0,
        bytesIn: 0,
        bytesOut: 0,
        selectedPreset: .balanced,
        lastError: nil
    )
}
