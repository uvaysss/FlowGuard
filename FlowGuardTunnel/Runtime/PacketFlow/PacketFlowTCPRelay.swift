import Foundation

private enum TCPSessionCloseReason: String {
    case stateClose = "state-close"
    case sendFailed = "send-failed"
    case remoteClosed = "remote-closed"
    case backpressureDrop = "backpressure-drop"
    case relayStop = "relay-stop"
}

enum PacketFlowTCPRelayEvent: Sendable {
    case connected(flowKey: TCPFlowKey)
    case connectFailed(flowKey: TCPFlowKey)
    case ackNow(flowKey: TCPFlowKey)
    case upstreamData(flowKey: TCPFlowKey, data: Data)
    case upstreamClosed(flowKey: TCPFlowKey, hadError: Bool)
    case localReset(flowKey: TCPFlowKey)
    case localFin(flowKey: TCPFlowKey)
}

struct PacketFlowTCPRelaySnapshot: Sendable {
    let activeSessions: Int
    let connectAttempts: Int64
    let connectFailures: Int64
    let droppedPayloadChunks: Int64
    let upstreamBytesSent: Int64
    let downstreamBytesReceived: Int64
    let upstreamSendAttempts: Int64
    let upstreamSendFailures: Int64
    let malformedPackets: Int64
    let backpressureDrops: Int64
    let sessionCloseTotal: Int64
    let sessionCloseStateClose: Int64
    let sessionCloseSendFailed: Int64
    let sessionCloseRemoteClosed: Int64
    let sessionCloseBackpressureDrop: Int64
    let sessionCloseRelayStop: Int64
}

final class PacketFlowTCPRelay {
    private let queue = DispatchQueue(label: "com.uvays.FlowGuard.packetflow.tcp-relay")
    private let sessionRegistry: PacketFlowSessionRegistry
    private let connector: any SOCKS5TCPConnecting

    private var running = false
    private var socksPort: Int = 1080
    private var logHandler: ((String) -> Void)?
    private var connectAttempts: Int64 = 0
    private var connectFailures: Int64 = 0
    private var droppedPayloadChunks: Int64 = 0
    private var upstreamBytesSent: Int64 = 0
    private var downstreamBytesReceived: Int64 = 0
    private var upstreamSendAttempts: Int64 = 0
    private var upstreamSendFailures: Int64 = 0
    private var malformedPackets: Int64 = 0
    private var backpressureDrops: Int64 = 0
    private var sessionCloseTotal: Int64 = 0
    private var sessionCloseStateClose: Int64 = 0
    private var sessionCloseSendFailed: Int64 = 0
    private var sessionCloseRemoteClosed: Int64 = 0
    private var sessionCloseBackpressureDrop: Int64 = 0
    private var sessionCloseRelayStop: Int64 = 0
    private var recentlyClosed: [TCPFlowKey: Date] = [:]
    private var eventHandler: ((PacketFlowTCPRelayEvent) -> Void)?

    init(
        sessionRegistry: PacketFlowSessionRegistry,
        connector: any SOCKS5TCPConnecting = SOCKS5TCPConnector()
    ) {
        self.sessionRegistry = sessionRegistry
        self.connector = connector
    }

    func start(
        profile: TunnelProfile,
        log: @escaping (String) -> Void,
        onEvent: ((PacketFlowTCPRelayEvent) -> Void)? = nil
    ) {
        queue.sync {
            running = true
            socksPort = profile.socksPort
            logHandler = log
            eventHandler = onEvent
            connectAttempts = 0
            connectFailures = 0
            droppedPayloadChunks = 0
            upstreamBytesSent = 0
            downstreamBytesReceived = 0
            upstreamSendAttempts = 0
            upstreamSendFailures = 0
            malformedPackets = 0
            backpressureDrops = 0
            sessionCloseTotal = 0
            sessionCloseStateClose = 0
            sessionCloseSendFailed = 0
            sessionCloseRemoteClosed = 0
            sessionCloseBackpressureDrop = 0
            sessionCloseRelayStop = 0
            recentlyClosed.removeAll()
            log("PacketFlowTCPRelay started on upstream SOCKS 127.0.0.1:\(profile.socksPort)")
        }
    }

    func stop() {
        queue.sync {
            guard running else { return }
            running = false
            let removed = sessionRegistry.removeAllSessions { $0.closeStream() }
            if removed > 0 {
                recordClose(.relayStop, amount: Int64(removed))
            }
            logHandler?("PacketFlowTCPRelay stopped; removedSessions=\(removed)")
            eventHandler = nil
            logHandler = nil
        }
    }

    func snapshot() -> PacketFlowTCPRelaySnapshot {
        queue.sync {
            PacketFlowTCPRelaySnapshot(
                activeSessions: sessionRegistry.count(),
                connectAttempts: connectAttempts,
                connectFailures: connectFailures,
                droppedPayloadChunks: droppedPayloadChunks,
                upstreamBytesSent: upstreamBytesSent,
                downstreamBytesReceived: downstreamBytesReceived,
                upstreamSendAttempts: upstreamSendAttempts,
                upstreamSendFailures: upstreamSendFailures,
                malformedPackets: malformedPackets,
                backpressureDrops: backpressureDrops,
                sessionCloseTotal: sessionCloseTotal,
                sessionCloseStateClose: sessionCloseStateClose,
                sessionCloseSendFailed: sessionCloseSendFailed,
                sessionCloseRemoteClosed: sessionCloseRemoteClosed,
                sessionCloseBackpressureDrop: sessionCloseBackpressureDrop,
                sessionCloseRelayStop: sessionCloseRelayStop
            )
        }
    }

    func handleIngressPackets(_ packets: [Data]) {
        queue.async {
            guard self.running else { return }
            for packetData in packets {
                self.handlePacket(packetData)
            }
        }
    }

    private func handlePacket(_ packetData: Data) {
        if let ipMetadata = IPPacketCodec.parse(packet: packetData),
           ipMetadata.transportProtocol == .tcp,
           TCPPacketCodec.parse(packet: packetData) == nil {
            malformedPackets += 1
            if malformedPackets % 50 == 0 {
                logHandler?("PacketFlowTCPRelay malformed TCP packets observed count=\(malformedPackets)")
            }
            return
        }

        guard let tcpPacket = TCPPacketCodec.parse(packet: packetData) else {
            return
        }

        if shouldIgnoreRecentlyClosedPacket(tcpPacket) {
            return
        }

        let upsert = sessionRegistry.upsertSession(for: tcpPacket.flowKey) {
            PacketFlowTCPSession(key: tcpPacket.flowKey)
        }
        let session = upsert.0
        if upsert.inserted {
            recentlyClosed.removeValue(forKey: tcpPacket.flowKey)
            logHandler?("TCP session created \(format(flowKey: tcpPacket.flowKey))")
        }
        session.observeInboundPacket(tcpPacket)

        let transition = session.apply(.inbound(flags: tcpPacket.flags, hasPayload: !tcpPacket.payload.isEmpty))
        handleActions(transition.actions, session: session)
        if !tcpPacket.payload.isEmpty && !tcpPacket.flags.contains(.rst) {
            eventHandler?(.ackNow(flowKey: tcpPacket.flowKey))
        }
        if tcpPacket.flags.contains(.rst) {
            eventHandler?(.localReset(flowKey: tcpPacket.flowKey))
        }
        if tcpPacket.flags.contains(.fin) {
            eventHandler?(.localFin(flowKey: tcpPacket.flowKey))
        }

        if !tcpPacket.payload.isEmpty {
            switch session.enqueueUpstreamPayload(tcpPacket.payload) {
            case .accepted:
                flushBufferedPayloadIfPossible(session)
            case .dropped:
                droppedPayloadChunks += 1
                backpressureDrops += 1
                logHandler?("TCP upstream payload dropped by backpressure \(format(flowKey: session.key)); closing session")
                closeSession(session, reason: .backpressureDrop)
            }
        }
    }

    private func handleActions(_ actions: [TCPSessionAction], session: PacketFlowTCPSession) {
        for action in actions {
            switch action {
            case .connectSocks:
                connectSocksIfNeeded(session)
            case .flushBufferedPayload:
                flushBufferedPayloadIfPossible(session)
            case .closeConnection:
                closeSession(session, reason: .stateClose)
            case .none:
                continue
            }
        }
    }

    private func connectSocksIfNeeded(_ session: PacketFlowTCPSession) {
        guard running else { return }
        guard session.stream == nil else { return }

        connectAttempts += 1
        let destinationHost = session.key.destinationAddress
        let destinationPort = session.key.destinationPort
        let flowKey = session.key

        connector.connect(
            socksPort: socksPort,
            destinationHost: destinationHost,
            destinationPort: destinationPort
        ) { [weak self] result in
            guard let self else { return }
            self.queue.async {
                guard self.running else { return }
                guard let currentSession = self.sessionRegistry.session(for: flowKey) else {
                    if case let .success(stream) = result {
                        stream.cancel()
                    }
                    return
                }

                switch result {
                case let .success(stream):
                    currentSession.attachStream(stream)
                    let transition = currentSession.apply(.socksConnected)
                    self.logHandler?("SOCKS CONNECT established \(self.format(flowKey: flowKey))")
                    self.eventHandler?(.connected(flowKey: flowKey))
                    self.handleActions(transition.actions, session: currentSession)
                    stream.receiveLoop(
                        onData: { [weak self] data in
                            self?.queue.async {
                                guard let self else { return }
                                self.downstreamBytesReceived += Int64(data.count)
                                self.eventHandler?(.upstreamData(flowKey: flowKey, data: data))
                            }
                        },
                        onComplete: { [weak self] error in
                            self?.queue.async {
                                guard let self else { return }
                                guard let activeSession = self.sessionRegistry.session(for: flowKey) else { return }
                                if let error {
                                    self.logHandler?("TCP upstream closed with error \(self.format(flowKey: flowKey)): \(error.localizedDescription)")
                                }
                                self.eventHandler?(.upstreamClosed(flowKey: flowKey, hadError: error != nil))
                                let closeTransition = activeSession.apply(.remoteClosed)
                                self.handleActions(closeTransition.actions, session: activeSession)
                                if case .closed = activeSession.state {
                                    self.closeSession(activeSession, reason: .remoteClosed)
                                }
                            }
                        }
                    )
                case let .failure(error):
                    self.connectFailures += 1
                    let transition = currentSession.apply(.socksConnectFailed(error.localizedDescription))
                    self.logHandler?("SOCKS CONNECT failed \(self.format(flowKey: flowKey)): \(error.localizedDescription)")
                    self.eventHandler?(.connectFailed(flowKey: flowKey))
                    self.handleActions(transition.actions, session: currentSession)
                }
            }
        }
    }

    private func flushBufferedPayloadIfPossible(_ session: PacketFlowTCPSession) {
        guard let stream = session.stream else { return }
        let chunks = session.drainUpstreamPayload()
        guard !chunks.isEmpty else { return }

        for chunk in chunks {
            upstreamSendAttempts += 1
            stream.send(chunk) { [weak self, weak session] error in
                guard let self else { return }
                self.queue.async {
                    guard self.running else { return }
                    guard let session else { return }
                    if let error {
                        self.upstreamSendFailures += 1
                        self.logHandler?("TCP upstream send failed \(self.format(flowKey: session.key)): \(error.localizedDescription)")
                        self.closeSession(session, reason: .sendFailed)
                        return
                    }
                    self.upstreamBytesSent += Int64(chunk.count)
                }
            }
        }
    }

    private func closeSession(_ session: PacketFlowTCPSession, reason: TCPSessionCloseReason) {
        session.closeStream()
        guard sessionRegistry.removeSession(for: session.key) else {
            return
        }
        recordClose(reason)
        recentlyClosed[session.key] = Date()
        trimRecentlyClosed()
        logHandler?("TCP session closed \(format(flowKey: session.key)); reason=\(reason.rawValue)")
    }

    private func recordClose(_ reason: TCPSessionCloseReason, amount: Int64 = 1) {
        guard amount > 0 else { return }
        sessionCloseTotal += amount
        switch reason {
        case .stateClose:
            sessionCloseStateClose += amount
        case .sendFailed:
            sessionCloseSendFailed += amount
        case .remoteClosed:
            sessionCloseRemoteClosed += amount
        case .backpressureDrop:
            sessionCloseBackpressureDrop += amount
        case .relayStop:
            sessionCloseRelayStop += amount
        }
    }

    private func shouldIgnoreRecentlyClosedPacket(_ packet: TCPPacket) -> Bool {
        guard let closedAt = recentlyClosed[packet.flowKey] else {
            return false
        }
        if Date().timeIntervalSince(closedAt) > 3 {
            recentlyClosed.removeValue(forKey: packet.flowKey)
            return false
        }

        if packet.flags.contains(.syn) || !packet.payload.isEmpty {
            return false
        }
        return true
    }

    private func trimRecentlyClosed(maxEntries: Int = 1024, ttl: TimeInterval = 3) {
        let now = Date()
        recentlyClosed = recentlyClosed.filter { now.timeIntervalSince($0.value) <= ttl }
        if recentlyClosed.count <= maxEntries {
            return
        }
        let sortedKeys = recentlyClosed.sorted { $0.value < $1.value }
        let overflow = recentlyClosed.count - maxEntries
        guard overflow > 0 else { return }
        for index in 0..<overflow {
            recentlyClosed.removeValue(forKey: sortedKeys[index].key)
        }
    }

    private func format(flowKey: TCPFlowKey) -> String {
        "\(flowKey.sourceAddress):\(flowKey.sourcePort)->\(flowKey.destinationAddress):\(flowKey.destinationPort)"
    }
}
