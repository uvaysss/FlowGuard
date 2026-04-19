import Foundation
import NetworkExtension

enum TunnelRuntimeError: LocalizedError {
    case networkSettingsFailed
    case socksEndpointUnavailable(Int)
    case socksPortInUse(Int)
    case byeDPIExited(Int32)

    var errorDescription: String? {
        switch self {
        case .networkSettingsFailed:
            return "Failed to apply packet tunnel network settings."
        case let .socksEndpointUnavailable(port):
            return "Local SOCKS endpoint did not become ready on 127.0.0.1:\(port)."
        case let .socksPortInUse(port):
            return "SOCKS port 127.0.0.1:\(port) is already in use by another process."
        case let .byeDPIExited(code):
            return "ByeDPI exited during startup with code \(code)."
        }
    }
}

protocol TunnelRuntimePersisting {
    func loadProfile() throws -> TunnelProfile?
    func persistSnapshot(state: ProviderState, stats: RuntimeStats)
    func appendLog(_ line: String)
    func readLogPreview(maxBytes: Int) -> String
}

struct DataPlaneStartResult {
    let tunInterfaceName: String?
    let baselineBytesIn: UInt64
    let baselineBytesOut: UInt64
}

struct DataPlaneTrafficSnapshot {
    let bytesIn: Int64
    let bytesOut: Int64
    let packetsIn: Int64
    let packetsOut: Int64
    let parseFailures: Int64
    let tcpConnectAttempts: Int64
    let tcpConnectFailures: Int64
    let tcpSendAttempts: Int64
    let tcpSendFailures: Int64
    let tcpBackpressureDrops: Int64
    let tcpActiveSessions: Int64
    let tcpSessionCloseTotal: Int64
    let tcpSessionCloseStateClose: Int64
    let tcpSessionCloseSendFailed: Int64
    let tcpSessionCloseRemoteClosed: Int64
    let tcpSessionCloseBackpressureDrop: Int64
    let tcpSessionCloseRelayStop: Int64
    let udpAssociateAttempts: Int64
    let udpAssociateFailures: Int64
    let udpTxPackets: Int64
    let udpRxPackets: Int64
    let udpTxFailures: Int64
    let udpBackpressureDrops: Int64
    let udpActiveSessions: Int64
    let dnsRoutedCount: Int64
    let udpSessionCloseTotal: Int64
    let udpSessionCloseAssociateClosed: Int64
    let udpSessionCloseAssociateFailed: Int64
    let udpSessionCloseSendFailed: Int64
    let udpSessionCloseBackpressureDrop: Int64
    let udpSessionCloseIdleCleanup: Int64
    let udpSessionCloseRelayStop: Int64
}

struct DataPlaneStopResult {
    let didStop: Bool
    let errorMessage: String?
}

protocol TunnelDataPlane: AnyObject {
    var mode: TunnelImplementationMode { get }
    var isRunning: Bool { get }

    func start(
        profile: TunnelProfile,
        packetFlow: NEPacketTunnelFlow?,
        onExit: @escaping (Int32) -> Void,
        log: @escaping (String) -> Void
    ) throws -> DataPlaneStartResult

    func stop(
        context: String,
        log: @escaping (String) -> Void
    ) -> DataPlaneStopResult

    func collectTrafficSnapshot() -> DataPlaneTrafficSnapshot?
}
