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

private enum LegacyTunFDDataPlaneError: LocalizedError {
    case missingPacketFlow
    case tunnelDescriptorResolutionFailed(String)
    case invalidTunnelDescriptor(Int32)

    var errorDescription: String? {
        switch self {
        case .missingPacketFlow:
            return "Packet flow reference is unavailable for TUN descriptor resolution."
        case let .tunnelDescriptorResolutionFailed(details):
            return "Failed to resolve tunnel interface file descriptor. \(details)"
        case let .invalidTunnelDescriptor(fd):
            return "Resolved tunnel interface descriptor is invalid: \(fd)."
        }
    }
}

final class LegacyTunFDDataPlane: TunnelDataPlane {
    private let tun2socksEngine: Tun2SocksEngine
    private let stateLock = NSLock()
    private var running = false
    private var trackedInterfaceName: String?
    private var baselineBytesIn: UInt64 = 0
    private var baselineBytesOut: UInt64 = 0

    let mode: TunnelImplementationMode

    var isRunning: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return running
    }

    init(mode: TunnelImplementationMode, tun2socksEngine: Tun2SocksEngine) {
        self.mode = mode
        self.tun2socksEngine = tun2socksEngine
    }

    func start(
        profile: TunnelProfile,
        packetFlow: NEPacketTunnelFlow?,
        onExit: @escaping (Int32) -> Void,
        log: @escaping (String) -> Void
    ) throws -> DataPlaneStartResult {
        guard let packetFlow else {
            throw LegacyTunFDDataPlaneError.missingPacketFlow
        }

        let resolveResult = TunFileDescriptorResolver.resolveUTUNFileDescriptorDetailed(
            from: packetFlow,
            attempts: 20,
            retryDelayMicroseconds: 100_000,
            // iOS internals for NEPacketTunnelFlow can change, making KVC extraction brittle.
            // Keep speed-first path resilient by falling back to scanning open FDs for utun.
            debugFallback: .scanOpenFileDescriptors(maxFD: 4096)
        )
        guard let tunFD = resolveResult.fileDescriptor else {
            let details = resolveResult.diagnostics?.failure.description ?? "Unknown descriptor resolution failure."
            throw LegacyTunFDDataPlaneError.tunnelDescriptorResolutionFailed(details)
        }
        guard tunFD >= 0 else {
            throw LegacyTunFDDataPlaneError.invalidTunnelDescriptor(tunFD)
        }
        log("Resolved TUN descriptor: \(tunFD)")

        let interfaceName = TunFileDescriptorResolver.utunInterfaceName(from: tunFD)
        let counters = interfaceName.flatMap(TunFileDescriptorResolver.interfaceTrafficCounters(interfaceName:))
        let baselineIn = counters?.bytesIn ?? 0
        let baselineOut = counters?.bytesOut ?? 0
        stateLock.lock()
        trackedInterfaceName = interfaceName
        baselineBytesIn = baselineIn
        baselineBytesOut = baselineOut
        stateLock.unlock()

        if let interfaceName {
            log("Resolved TUN interface: \(interfaceName)")
        } else {
            log("Failed to resolve TUN interface name from descriptor")
        }

        try tun2socksEngine.start(config: profile, tunFD: tunFD) { [weak self] exitCode in
            self?.setRunning(false)
            onExit(exitCode)
        }

        setRunning(true)
        log("tun2socks started")

        return DataPlaneStartResult(
            tunInterfaceName: interfaceName,
            baselineBytesIn: baselineIn,
            baselineBytesOut: baselineOut
        )
    }

    func stop(
        context: String,
        log: @escaping (String) -> Void
    ) -> DataPlaneStopResult {
        let gracefulTimeout: TimeInterval = 3
        let forcedTimeout: TimeInterval = 2

        do {
            try tun2socksEngine.requestStop()
            let stopped = tun2socksEngine.waitForExit(timeout: gracefulTimeout)
            if stopped {
                setRunning(false)
                clearInterfaceTracking()
                log("tun2socks stopped")
                return DataPlaneStopResult(didStop: true, errorMessage: nil)
            }

            log("tun2socks did not stop within \(Int(gracefulTimeout))s, forcing shutdown")
            tun2socksEngine.forceStop()
            let forceStopped = tun2socksEngine.waitForExit(timeout: forcedTimeout)
            if forceStopped {
                setRunning(false)
                clearInterfaceTracking()
                log("tun2socks stopped after force-stop")
                return DataPlaneStopResult(didStop: true, errorMessage: nil)
            }

            let message = "tun2socks did not exit after force-stop"
            log(message)
            return DataPlaneStopResult(didStop: false, errorMessage: "\(context) \(message)")
        } catch {
            log("tun2socks stop failed: \(error.localizedDescription)")
            tun2socksEngine.forceStop()
            if tun2socksEngine.waitForExit(timeout: forcedTimeout) {
                setRunning(false)
                clearInterfaceTracking()
                log("tun2socks force-stopped after error")
                return DataPlaneStopResult(didStop: true, errorMessage: nil)
            }

            let message = "tun2socks did not exit after force-stop following stop error"
            log(message)
            return DataPlaneStopResult(didStop: false, errorMessage: "\(context) \(message)")
        }
    }

    func collectTrafficSnapshot() -> DataPlaneTrafficSnapshot? {
        let snapshotState: (String?, UInt64, UInt64)
        stateLock.lock()
        snapshotState = (trackedInterfaceName, baselineBytesIn, baselineBytesOut)
        stateLock.unlock()

        guard let interfaceName = snapshotState.0,
              let counters = TunFileDescriptorResolver.interfaceTrafficCounters(interfaceName: interfaceName) else {
            return nil
        }

        let deltaIn = counters.bytesIn >= snapshotState.1 ? counters.bytesIn - snapshotState.1 : 0
        let deltaOut = counters.bytesOut >= snapshotState.2 ? counters.bytesOut - snapshotState.2 : 0
        return DataPlaneTrafficSnapshot(
            bytesIn: Int64(deltaIn),
            bytesOut: Int64(deltaOut),
            packetsIn: 0,
            packetsOut: 0,
            parseFailures: 0,
            tcpConnectAttempts: 0,
            tcpConnectFailures: 0,
            tcpSendAttempts: 0,
            tcpSendFailures: 0,
            tcpBackpressureDrops: 0,
            tcpActiveSessions: 0,
            tcpSessionCloseTotal: 0,
            tcpSessionCloseStateClose: 0,
            tcpSessionCloseSendFailed: 0,
            tcpSessionCloseRemoteClosed: 0,
            tcpSessionCloseBackpressureDrop: 0,
            tcpSessionCloseRelayStop: 0,
            udpAssociateAttempts: 0,
            udpAssociateFailures: 0,
            udpTxPackets: 0,
            udpRxPackets: 0,
            udpTxFailures: 0,
            udpBackpressureDrops: 0,
            udpActiveSessions: 0,
            dnsRoutedCount: 0,
            udpSessionCloseTotal: 0,
            udpSessionCloseAssociateClosed: 0,
            udpSessionCloseAssociateFailed: 0,
            udpSessionCloseSendFailed: 0,
            udpSessionCloseBackpressureDrop: 0,
            udpSessionCloseIdleCleanup: 0,
            udpSessionCloseRelayStop: 0
        )
    }

    private func setRunning(_ value: Bool) {
        stateLock.lock()
        running = value
        stateLock.unlock()
    }

    private func clearInterfaceTracking() {
        stateLock.lock()
        trackedInterfaceName = nil
        baselineBytesIn = 0
        baselineBytesOut = 0
        stateLock.unlock()
    }
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
