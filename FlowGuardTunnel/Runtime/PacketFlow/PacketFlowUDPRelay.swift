import Foundation

enum PacketFlowUDPRelayEvent: Sendable {
    case upstreamDatagram(flowKey: UDPFlowKey, payload: Data)
}

struct PacketFlowUDPRelaySnapshot: Sendable {
    let activeSessions: Int
    let associateAttempts: Int64
    let associateFailures: Int64
    let droppedDatagrams: Int64
    let txPackets: Int64
    let txBytes: Int64
    let rxPackets: Int64
    let rxBytes: Int64
    let dnsRoutedCount: Int64
    let txFailures: Int64
    let malformedPackets: Int64
}

final class PacketFlowUDPRelay {
    private let queue = DispatchQueue(label: "com.uvays.FlowGuard.packetflow.udp-relay")
    private let associateClient: SOCKS5UDPAssociateClient

    private var running = false
    private var socksPort: Int = 1080
    private var dnsMode: DNSMode = .system
    private var logHandler: ((String) -> Void)?
    private var sessions: [UDPFlowKey: PacketFlowUDPSession] = [:]

    private var associateAttempts: Int64 = 0
    private var associateFailures: Int64 = 0
    private var droppedDatagrams: Int64 = 0
    private var txPackets: Int64 = 0
    private var txBytes: Int64 = 0
    private var rxPackets: Int64 = 0
    private var rxBytes: Int64 = 0
    private var dnsRoutedCount: Int64 = 0
    private var txFailures: Int64 = 0
    private var malformedCount: Int64 = 0
    private var eventHandler: ((PacketFlowUDPRelayEvent) -> Void)?

    init(associateClient: SOCKS5UDPAssociateClient = SOCKS5UDPAssociateClient()) {
        self.associateClient = associateClient
    }

    func start(
        profile: TunnelProfile,
        log: @escaping (String) -> Void,
        onEvent: ((PacketFlowUDPRelayEvent) -> Void)? = nil
    ) {
        queue.sync {
            running = true
            socksPort = profile.socksPort
            dnsMode = profile.dnsMode
            logHandler = log
            sessions.removeAll()
            associateAttempts = 0
            associateFailures = 0
            droppedDatagrams = 0
            txPackets = 0
            txBytes = 0
            rxPackets = 0
            rxBytes = 0
            dnsRoutedCount = 0
            txFailures = 0
            malformedCount = 0
            eventHandler = onEvent
            log("PacketFlowUDPRelay started on upstream SOCKS 127.0.0.1:\(profile.socksPort) dnsMode=\(profile.dnsMode.rawValue)")
        }
    }

    func stop() {
        queue.sync {
            guard running else { return }
            running = false
            let count = sessions.count
            for session in sessions.values {
                session.close()
            }
            sessions.removeAll()
            logHandler?("PacketFlowUDPRelay stopped; removedSessions=\(count)")
            eventHandler = nil
            logHandler = nil
        }
    }

    func snapshot() -> PacketFlowUDPRelaySnapshot {
        queue.sync {
            PacketFlowUDPRelaySnapshot(
                activeSessions: sessions.count,
                associateAttempts: associateAttempts,
                associateFailures: associateFailures,
                droppedDatagrams: droppedDatagrams,
                txPackets: txPackets,
                txBytes: txBytes,
                rxPackets: rxPackets,
                rxBytes: rxBytes,
                dnsRoutedCount: dnsRoutedCount,
                txFailures: txFailures,
                malformedPackets: malformedCount
            )
        }
    }

    func handleIngressPackets(_ packets: [Data]) {
        queue.async {
            guard self.running else { return }
            for packet in packets {
                if let udp = UDPPacketCodec.parse(packet: packet) {
                    self.handleUDPPacket(udp)
                } else if IPPacketCodec.parse(packet: packet)?.transportProtocol == .udp {
                    self.malformedCount += 1
                    if self.malformedCount % 50 == 0 {
                        self.logHandler?("PacketFlowUDPRelay malformed UDP packets observed count=\(self.malformedCount)")
                    }
                }
            }
            self.cleanupIdleSessions(now: Date(), maxIdle: 90)
        }
    }

    private func handleUDPPacket(_ packet: UDPPacket) {
        let session = upsertSession(for: packet.flowKey)
        session.touch()

        let routed = resolveDestination(for: packet)
        if routed.routedByPolicy {
            dnsRoutedCount += 1
        }

        let pending = PendingUDPSendDatagram(
            destinationHost: routed.destinationHost,
            destinationPort: routed.destinationPort,
            payload: packet.payload
        )

        switch session.enqueue(pending) {
        case .accepted:
            ensureAssociation(for: session)
            flushQueuedDatagrams(session)
        case .dropped:
            droppedDatagrams += 1
            logHandler?("UDP datagram dropped by backpressure \(format(flowKey: packet.flowKey)); closing session")
            closeSession(session, reason: "backpressure-drop")
        }
    }

    private func ensureAssociation(for session: PacketFlowUDPSession) {
        switch session.state {
        case .ready, .associating:
            return
        case .closing, .closed, .failed:
            return
        case .idle:
            break
        }

        session.setState(.associating)
        associateAttempts += 1
        let key = session.key

        associateClient.open(socksPort: socksPort) { [weak self] result in
            guard let self else { return }
            self.queue.async {
                guard self.running else { return }
                guard let liveSession = self.sessions[key] else {
                    if case let .success(association) = result {
                        association.close()
                    }
                    return
                }

                switch result {
                case let .success(association):
                    liveSession.attachAssociation(association)
                    self.logHandler?("UDP ASSOCIATE established \(self.format(flowKey: key))")
                    association.receiveLoop(
                        onDatagram: { [weak self] datagram in
                            self?.queue.async {
                                guard let self else { return }
                                guard self.running else { return }
                                self.rxPackets += 1
                                self.rxBytes += Int64(datagram.payload.count)
                                self.eventHandler?(.upstreamDatagram(flowKey: key, payload: datagram.payload))
                            }
                        },
                        onComplete: { [weak self] error in
                            self?.queue.async {
                                guard let self else { return }
                                guard let current = self.sessions[key] else { return }
                                if let error {
                                    self.logHandler?("UDP association closed with error \(self.format(flowKey: key)): \(error.localizedDescription)")
                                }
                                self.closeSession(current, reason: "associate-closed")
                            }
                        }
                    )
                    self.flushQueuedDatagrams(liveSession)
                case let .failure(error):
                    self.associateFailures += 1
                    liveSession.setState(.failed(error.localizedDescription))
                    self.logHandler?("UDP ASSOCIATE failed \(self.format(flowKey: key)): \(error.localizedDescription)")
                    self.closeSession(liveSession, reason: "associate-failed")
                }
            }
        }
    }

    private func flushQueuedDatagrams(_ session: PacketFlowUDPSession) {
        guard case .ready = session.state, let association = session.association else {
            return
        }

        let pending = session.drain()
        guard !pending.isEmpty else { return }

        for datagram in pending {
            association.send(
                datagram: SOCKS5UDPDatagram(
                    destinationHost: datagram.destinationHost,
                    destinationPort: datagram.destinationPort,
                    payload: datagram.payload
                )
            ) { [weak self, weak session] error in
                guard let self else { return }
                self.queue.async {
                    guard self.running else { return }
                    guard let session else { return }
                    if let error {
                        self.txFailures += 1
                        self.logHandler?("UDP send failed \(self.format(flowKey: session.key)): \(error.localizedDescription)")
                        self.closeSession(session, reason: "send-failed")
                        return
                    }
                    self.txPackets += 1
                    self.txBytes += Int64(datagram.payload.count)
                }
            }
        }
    }

    private func closeSession(_ session: PacketFlowUDPSession, reason: String) {
        session.close()
        sessions.removeValue(forKey: session.key)
        logHandler?("UDP session closed \(format(flowKey: session.key)); reason=\(reason)")
    }

    private func upsertSession(for key: UDPFlowKey) -> PacketFlowUDPSession {
        if let existing = sessions[key] {
            return existing
        }
        let created = PacketFlowUDPSession(key: key)
        sessions[key] = created
        logHandler?("UDP session created \(format(flowKey: key))")
        return created
    }

    private func cleanupIdleSessions(now: Date, maxIdle: TimeInterval) {
        var keysToRemove: [UDPFlowKey] = []
        for (key, session) in sessions where now.timeIntervalSince(session.lastSeenAt) > maxIdle {
            session.close()
            keysToRemove.append(key)
        }
        if !keysToRemove.isEmpty {
            for key in keysToRemove {
                sessions.removeValue(forKey: key)
            }
            logHandler?("UDP idle cleanup removed \(keysToRemove.count) sessions")
        }
    }

    private func resolveDestination(for packet: UDPPacket) -> (destinationHost: String, destinationPort: UInt16, routedByPolicy: Bool) {
        guard packet.flowKey.destinationPort == 53 else {
            return (packet.flowKey.destinationAddress, packet.flowKey.destinationPort, false)
        }
        let server = dnsServers(for: dnsMode).first ?? "9.9.9.9"
        return (server, 53, true)
    }

    private func dnsServers(for mode: DNSMode) -> [String] {
        switch mode {
        case .system:
            return ["9.9.9.9", "149.112.112.112"]
        case .doh:
            return ["1.1.1.1", "1.0.0.1"]
        case .plain:
            return ["8.8.8.8", "8.8.4.4"]
        }
    }

    private func format(flowKey: UDPFlowKey) -> String {
        "\(flowKey.sourceAddress):\(flowKey.sourcePort)->\(flowKey.destinationAddress):\(flowKey.destinationPort)"
    }
}
