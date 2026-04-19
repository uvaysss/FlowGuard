import Foundation
import NetworkExtension

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

final class PacketFlowDataPlane: TunnelDataPlane {
    private static let downstreamTCPPayloadChunkSize = 900

    private let stateLock = NSLock()
    private let sessionRegistry: PacketFlowSessionRegistry
    private let pump: PacketFlowPump
    private let tcpRelay: PacketFlowTCPRelay
    private let udpRelay: PacketFlowUDPRelay
    private let egressWriter: PacketFlowEgressWriter
    private var summaryTimer: DispatchSourceTimer?
    private var logHandler: ((String) -> Void)?
    private var running = false

    let mode: TunnelImplementationMode

    var isRunning: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return running
    }

    init(
        mode: TunnelImplementationMode,
        sessionRegistry: PacketFlowSessionRegistry = PacketFlowSessionRegistry(),
        pump: PacketFlowPump = PacketFlowPump()
    ) {
        self.mode = mode
        self.sessionRegistry = sessionRegistry
        self.pump = pump
        self.tcpRelay = PacketFlowTCPRelay(sessionRegistry: sessionRegistry)
        self.udpRelay = PacketFlowUDPRelay()
        self.egressWriter = PacketFlowEgressWriter()
    }

    func start(
        profile: TunnelProfile,
        packetFlow: NEPacketTunnelFlow?,
        onExit: @escaping (Int32) -> Void,
        log: @escaping (String) -> Void
    ) throws -> DataPlaneStartResult {
        _ = onExit
        _ = sessionRegistry.removeAllSessions(onRemove: { $0.closeStream() })
        logHandler = log
        egressWriter.start(flow: packetFlow, log: log)
        tcpRelay.start(profile: profile, log: log, onEvent: { [weak self] event in
            self?.handleTCPRelayEvent(event)
        })
        udpRelay.start(profile: profile, log: log, onEvent: { [weak self] event in
            self?.handleUDPRelayEvent(event)
        })
        pump.start(
            flow: packetFlow,
            log: log,
            onIngressPackets: { [weak self] packets in
                self?.tcpRelay.handleIngressPackets(packets)
                self?.udpRelay.handleIngressPackets(packets)
            }
        )
        scheduleSummaryTimer()
        setRunning(true)
        log("PacketFlow data plane started in mode: \(mode.rawValue)")
        return DataPlaneStartResult(tunInterfaceName: nil, baselineBytesIn: 0, baselineBytesOut: 0)
    }

    func stop(
        context: String,
        log: @escaping (String) -> Void
    ) -> DataPlaneStopResult {
        cancelSummaryTimer()
        pump.stop()
        tcpRelay.stop()
        udpRelay.stop()
        egressWriter.stop()
        let cleaned = sessionRegistry.cleanupIdleSessions(maxIdle: 0, onRemove: { $0.closeStream() })
        setRunning(false)
        let snapshot = collectTrafficSnapshot()
        log("PacketFlow data plane stopped (\(context)); cleanedSessions=\(cleaned)")
        if let snapshot {
            log("PacketFlow final metrics mode=\(mode.rawValue) bytesIn=\(snapshot.bytesIn) bytesOut=\(snapshot.bytesOut) packetsIn=\(snapshot.packetsIn) packetsOut=\(snapshot.packetsOut) tcpActive=\(snapshot.tcpActiveSessions) udpActive=\(snapshot.udpActiveSessions) tcpConnectFailures=\(snapshot.tcpConnectFailures) udpAssociateFailures=\(snapshot.udpAssociateFailures) udpTxFailures=\(snapshot.udpTxFailures) dnsRouted=\(snapshot.dnsRoutedCount) parseFailures=\(snapshot.parseFailures) tcpBackpressureDrops=\(snapshot.tcpBackpressureDrops) udpBackpressureDrops=\(snapshot.udpBackpressureDrops) tcpClosedTotal=\(snapshot.tcpSessionCloseTotal) udpClosedTotal=\(snapshot.udpSessionCloseTotal)")
        }
        return DataPlaneStopResult(didStop: true, errorMessage: nil)
    }

    func collectTrafficSnapshot() -> DataPlaneTrafficSnapshot? {
        let pumpSnapshot = pump.snapshot()
        let tcpSnapshot = tcpRelay.snapshot()
        let udpSnapshot = udpRelay.snapshot()
        let egressSnapshot = egressWriter.snapshot()
        let packetsOut = tcpSnapshot.upstreamSendAttempts + udpSnapshot.txPackets
        let packetsIn = max(pumpSnapshot.ingressPackets, egressSnapshot.packetsWritten)
        let bytesOut = max(egressSnapshot.bytesWritten, tcpSnapshot.upstreamBytesSent + udpSnapshot.txBytes)
        return DataPlaneTrafficSnapshot(
            bytesIn: pumpSnapshot.ingressBytes,
            bytesOut: bytesOut,
            packetsIn: packetsIn,
            packetsOut: packetsOut,
            parseFailures: pumpSnapshot.parseFailures + tcpSnapshot.malformedPackets + udpSnapshot.malformedPackets,
            tcpConnectAttempts: tcpSnapshot.connectAttempts,
            tcpConnectFailures: tcpSnapshot.connectFailures,
            tcpSendAttempts: tcpSnapshot.upstreamSendAttempts,
            tcpSendFailures: tcpSnapshot.upstreamSendFailures,
            tcpBackpressureDrops: tcpSnapshot.backpressureDrops,
            tcpActiveSessions: Int64(tcpSnapshot.activeSessions),
            tcpSessionCloseTotal: tcpSnapshot.sessionCloseTotal,
            tcpSessionCloseStateClose: tcpSnapshot.sessionCloseStateClose,
            tcpSessionCloseSendFailed: tcpSnapshot.sessionCloseSendFailed,
            tcpSessionCloseRemoteClosed: tcpSnapshot.sessionCloseRemoteClosed,
            tcpSessionCloseBackpressureDrop: tcpSnapshot.sessionCloseBackpressureDrop,
            tcpSessionCloseRelayStop: tcpSnapshot.sessionCloseRelayStop,
            udpAssociateAttempts: udpSnapshot.associateAttempts,
            udpAssociateFailures: udpSnapshot.associateFailures,
            udpTxPackets: udpSnapshot.txPackets,
            udpRxPackets: udpSnapshot.rxPackets,
            udpTxFailures: udpSnapshot.txFailures,
            udpBackpressureDrops: udpSnapshot.backpressureDrops,
            udpActiveSessions: Int64(udpSnapshot.activeSessions),
            dnsRoutedCount: udpSnapshot.dnsRoutedCount,
            udpSessionCloseTotal: udpSnapshot.sessionCloseTotal,
            udpSessionCloseAssociateClosed: udpSnapshot.sessionCloseAssociateClosed,
            udpSessionCloseAssociateFailed: udpSnapshot.sessionCloseAssociateFailed,
            udpSessionCloseSendFailed: udpSnapshot.sessionCloseSendFailed,
            udpSessionCloseBackpressureDrop: udpSnapshot.sessionCloseBackpressureDrop,
            udpSessionCloseIdleCleanup: udpSnapshot.sessionCloseIdleCleanup,
            udpSessionCloseRelayStop: udpSnapshot.sessionCloseRelayStop
        )
    }

    private func setRunning(_ value: Bool) {
        stateLock.lock()
        running = value
        stateLock.unlock()
    }

    private func handleTCPRelayEvent(_ event: PacketFlowTCPRelayEvent) {
        switch event {
        case let .connected(flowKey):
            guard let session = sessionRegistry.session(for: flowKey), session.hasClientSequence else { return }
            if session.observedInitialSyn,
               !session.didSendSyntheticSynAck,
               let packet = PacketSynthesizer.synthesizeTCP(
                   flowKey: flowKey,
                   sequenceNumber: session.remoteNextSequence,
                   acknowledgementNumber: session.clientNextSequence,
                   flags: [.syn, .ack]
               ) {
                session.markSynAckSent()
                writeSynthesizedPackets([packet])
            }

        case let .connectFailed(flowKey):
            guard let session = sessionRegistry.session(for: flowKey) else { return }
            let ack = session.hasClientSequence ? session.clientNextSequence : 0
            if let rst = PacketSynthesizer.synthesizeTCP(
                flowKey: flowKey,
                sequenceNumber: session.remoteNextSequence,
                acknowledgementNumber: ack,
                flags: [.rst, .ack]
            ) {
                writeSynthesizedPackets([rst])
            }

        case let .ackNow(flowKey):
            guard let session = sessionRegistry.session(for: flowKey), session.hasClientSequence else { return }
            guard session.didSendSyntheticSynAck else { return }
            if let ackPacket = PacketSynthesizer.synthesizeTCP(
                flowKey: flowKey,
                sequenceNumber: session.remoteNextSequence,
                acknowledgementNumber: session.clientNextSequence,
                flags: [.ack]
            ) {
                writeSynthesizedPackets([ackPacket])
            }

        case let .upstreamData(flowKey, data):
            guard let session = sessionRegistry.session(for: flowKey), session.hasClientSequence else { return }
            let chunkSize = Self.downstreamTCPPayloadChunkSize
            let chunks = data.chunked(maxChunkSize: chunkSize)
            guard !chunks.isEmpty else { return }
            if chunks.count > 1 {
                logHandler?(
                    "TCP downstream segmentation flow=\(format(flowKey: flowKey)) bytes=\(data.count) chunks=\(chunks.count) chunkSize=\(chunkSize)"
                )
            }

            var sequence = session.remoteNextSequence

            for index in chunks.indices {
                let isLast = index == chunks.count - 1
                let flags: TCPFlags = isLast ? [.ack, .psh] : [.ack]
                guard let packet = PacketSynthesizer.synthesizeTCP(
                    flowKey: flowKey,
                    sequenceNumber: sequence,
                    acknowledgementNumber: session.clientNextSequence,
                    flags: flags,
                    payload: chunks[index]
                ) else {
                    return
                }
                writeSynthesizedPackets([packet])
                sequence = sequence &+ UInt32(chunks[index].count)
            }

            session.consumeRemoteSequence(bytes: data.count)

        case let .upstreamClosed(flowKey, hadError):
            guard let session = sessionRegistry.session(for: flowKey), session.hasClientSequence else { return }
            let flags: TCPFlags = hadError ? [.rst, .ack] : [.fin, .ack]
            if let closePacket = PacketSynthesizer.synthesizeTCP(
                flowKey: flowKey,
                sequenceNumber: session.remoteNextSequence,
                acknowledgementNumber: session.clientNextSequence,
                flags: flags
            ) {
                if !hadError {
                    session.consumeRemoteSequence(bytes: 1)
                }
                writeSynthesizedPackets([closePacket])
            }

        case let .localReset(flowKey):
            guard let session = sessionRegistry.session(for: flowKey), session.hasClientSequence else { return }
            if let packet = PacketSynthesizer.synthesizeTCP(
                flowKey: flowKey,
                sequenceNumber: session.remoteNextSequence,
                acknowledgementNumber: session.clientNextSequence,
                flags: [.rst, .ack]
            ) {
                writeSynthesizedPackets([packet])
            }

        case .localFin:
            break
        }
    }

    private func handleUDPRelayEvent(_ event: PacketFlowUDPRelayEvent) {
        switch event {
        case let .upstreamDatagram(flowKey, payload):
            guard let packet = PacketSynthesizer.synthesizeUDP(flowKey: flowKey, payload: payload) else {
                return
            }
            writeSynthesizedPackets([packet])
        }
    }

    private func writeSynthesizedPackets(_ packets: [SynthesizedPacket]) {
        guard !packets.isEmpty else { return }
        egressWriter.write(packets: packets) { [weak self] count, bytes in
            self?.pump.recordEgress(packets: count, bytes: bytes)
        }
    }

    private func format(flowKey: TCPFlowKey) -> String {
        "\(flowKey.sourceAddress):\(flowKey.sourcePort)->\(flowKey.destinationAddress):\(flowKey.destinationPort)"
    }

    private func scheduleSummaryTimer() {
        cancelSummaryTimer()
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "com.uvays.FlowGuard.packetflow.summary"))
        timer.schedule(deadline: .now() + 10, repeating: 10)
        timer.setEventHandler { [weak self] in
            guard let self, self.isRunning else { return }
            guard let snapshot = self.collectTrafficSnapshot() else { return }
            self.logHandler?(
                "PacketFlow summary mode=\(self.mode.rawValue) bytesIn=\(snapshot.bytesIn) bytesOut=\(snapshot.bytesOut) packetsIn=\(snapshot.packetsIn) packetsOut=\(snapshot.packetsOut) tcpActive=\(snapshot.tcpActiveSessions) udpActive=\(snapshot.udpActiveSessions) tcpConnectFailures=\(snapshot.tcpConnectFailures) udpAssociateFailures=\(snapshot.udpAssociateFailures) udpTxFailures=\(snapshot.udpTxFailures) dnsRouted=\(snapshot.dnsRoutedCount) parseFailures=\(snapshot.parseFailures) tcpBackpressureDrops=\(snapshot.tcpBackpressureDrops) udpBackpressureDrops=\(snapshot.udpBackpressureDrops) tcpClosedTotal=\(snapshot.tcpSessionCloseTotal) udpClosedTotal=\(snapshot.udpSessionCloseTotal)"
            )
        }
        summaryTimer = timer
        timer.resume()
    }

    private func cancelSummaryTimer() {
        summaryTimer?.cancel()
        summaryTimer = nil
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}

private extension Data {
    func chunked(maxChunkSize: Int) -> [Data] {
        guard maxChunkSize > 0 else { return [self] }
        guard count > maxChunkSize else { return [self] }

        var result: [Data] = []
        result.reserveCapacity((count + maxChunkSize - 1) / maxChunkSize)

        var offset = startIndex
        while offset < endIndex {
            let nextOffset = index(offset, offsetBy: maxChunkSize, limitedBy: endIndex) ?? endIndex
            result.append(self[offset..<nextOffset])
            offset = nextOffset
        }
        return result
    }
}
