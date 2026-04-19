import Foundation
import XCTest

final class PacketFlowIntegrationTests: XCTestCase {
    func testTCPSynIngressProducesSynthesizedSynAckEgress() {
        let connector = IntegrationFakeTCPConnector()
        connector.enqueue(result: .success(IntegrationFakeTCPStream()))
        let harness = PacketPipelineHarness(tcpConnector: connector)
        harness.start()

        harness.emitIngress([makeTCPSynPacket(sequence: 100)])

        waitUntil("syn/ack written") {
            harness.egressPackets().count == 1
        }

        let egress = harness.egressPackets()
        XCTAssertEqual(egress.count, 1)
        let parsed = TCPPacketCodec.parse(packet: egress[0].data)
        XCTAssertNotNil(parsed)
        XCTAssertTrue(parsed?.flags.contains(.syn) == true)
        XCTAssertTrue(parsed?.flags.contains(.ack) == true)
        XCTAssertEqual(parsed?.acknowledgementNumber, 101)

        harness.stop()
    }

    func testTCPConnectFailureProducesSynthesizedResetEgress() {
        let connector = IntegrationFakeTCPConnector()
        connector.enqueue(result: .failure(IntegrationError.connectFailed))
        let harness = PacketPipelineHarness(tcpConnector: connector)
        harness.start()

        harness.emitIngress([makeTCPSynPacket(sequence: 77)])

        waitUntil("rst/ack written") {
            harness.egressPackets().count == 1
        }

        let egress = harness.egressPackets()
        XCTAssertEqual(egress.count, 1)
        let parsed = TCPPacketCodec.parse(packet: egress[0].data)
        XCTAssertNotNil(parsed)
        XCTAssertTrue(parsed?.flags.contains(.rst) == true)
        XCTAssertTrue(parsed?.flags.contains(.ack) == true)
        XCTAssertEqual(parsed?.acknowledgementNumber, 78)

        harness.stop()
    }

    func testUDPDNSIngressRoutesUpstreamAndSynthesizesEgressDatagram() {
        let association = IntegrationFakeUDPAssociation()
        let udpClient = IntegrationFakeUDPAssociateClient()
        udpClient.enqueue(result: .success(association))
        let harness = PacketPipelineHarness(udpAssociateClient: udpClient)
        harness.start()

        let ingressPayload = Data([0xDE, 0xAD, 0xBE, 0xEF])
        harness.emitIngress([makeUDPDNSPacket(payload: ingressPayload)])

        waitUntil("dns datagram sent upstream") {
            association.sentDatagrams.count == 1
        }

        XCTAssertEqual(association.sentDatagrams.first?.destinationPort, 53)
        XCTAssertEqual(association.sentDatagrams.first?.payload, ingressPayload)

        waitUntil("udp receive loop registered") {
            association.receiveLoopRegistered
        }

        let upstreamPayload = Data([0x01, 0x02, 0x03])
        association.emit(datagram: SOCKS5UDPDatagram(destinationHost: "8.8.8.8", destinationPort: 53, payload: upstreamPayload))

        waitUntil("udp egress synthesized") {
            harness.egressPackets().count == 1
        }

        let egress = harness.egressPackets()
        XCTAssertEqual(egress.count, 1)
        let parsed = UDPPacketCodec.parse(packet: egress[0].data)
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.payload, upstreamPayload)
        XCTAssertEqual(parsed?.flowKey.sourcePort, 53)
        XCTAssertEqual(parsed?.flowKey.destinationPort, 55000)

        harness.stop()
    }

    func testMalformedIngressIncrementsPumpParseFailuresMetric() {
        let harness = PacketPipelineHarness()
        harness.start()

        harness.emitIngress([Data([0x00, 0x01, 0x02, 0x03])])

        waitUntil("parse failures incremented") {
            harness.pumpSnapshot().parseFailures == 1
        }

        XCTAssertEqual(harness.pumpSnapshot().parseFailures, 1)
        XCTAssertTrue(harness.egressPackets().isEmpty)

        harness.stop()
    }

    private func makeTCPSynPacket(sequence: UInt32) -> Data {
        let packet = TestPacketBuilders.makeTCPPacket(
            ipVersion: .ipv4,
            sourceAddress: "10.0.0.2",
            destinationAddress: "93.184.216.34",
            sourcePort: 55000,
            destinationPort: 443,
            sequenceNumber: sequence,
            acknowledgementNumber: 0,
            flags: [.syn]
        )
        XCTAssertNotNil(packet)
        return packet!
    }

    private func makeUDPDNSPacket(payload: Data) -> Data {
        let packet = TestPacketBuilders.makeUDPPacket(
            ipVersion: .ipv4,
            sourceAddress: "10.0.0.2",
            destinationAddress: "93.184.216.34",
            sourcePort: 55000,
            destinationPort: 53,
            payload: payload
        )
        XCTAssertNotNil(packet)
        return packet!
    }

    private func waitUntil(_ description: String, timeout: TimeInterval = 1.2, condition: @escaping () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        let exp = expectation(description: description)

        func poll() {
            if condition() {
                exp.fulfill()
                return
            }
            if Date() >= deadline {
                return
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.01) {
                poll()
            }
        }

        poll()
        wait(for: [exp], timeout: timeout + 0.3)
    }
}

private final class PacketPipelineHarness {
    private let sessionRegistry = PacketFlowSessionRegistry()
    private let pump = PacketFlowPump()
    private let egressWriter = PacketFlowEgressWriter()
    private let flow = InMemoryPacketFlowIO()
    private let tcpRelay: PacketFlowTCPRelay
    private let udpRelay: PacketFlowUDPRelay

    init(
        tcpConnector: any SOCKS5TCPConnecting = IntegrationFakeTCPConnector(),
        udpAssociateClient: any SOCKS5UDPAssociating = IntegrationFakeUDPAssociateClient()
    ) {
        tcpRelay = PacketFlowTCPRelay(sessionRegistry: sessionRegistry, connector: tcpConnector)
        udpRelay = PacketFlowUDPRelay(associateClient: udpAssociateClient)
    }

    func start(profile: TunnelProfile = .default) {
        egressWriter.start(flow: flow, log: { _ in })

        tcpRelay.start(profile: profile, log: { _ in }, onEvent: { [weak self] event in
            self?.handleTCPEvent(event)
        })

        udpRelay.start(profile: profile, log: { _ in }, onEvent: { [weak self] event in
            self?.handleUDPEvent(event)
        })

        pump.start(flow: flow, log: { _ in }, onIngressPackets: { [weak self] packets in
            self?.tcpRelay.handleIngressPackets(packets)
            self?.udpRelay.handleIngressPackets(packets)
        })
    }

    func stop() {
        pump.stop()
        tcpRelay.stop()
        udpRelay.stop()
        egressWriter.stop()
    }

    func emitIngress(_ packets: [Data]) {
        flow.emitIngress(packets)
    }

    func egressPackets() -> [SynthesizedPacket] {
        flow.writtenPackets()
    }

    func pumpSnapshot() -> PacketFlowPumpSnapshot {
        pump.snapshot()
    }

    private func handleTCPEvent(_ event: PacketFlowTCPRelayEvent) {
        switch event {
        case let .connected(flowKey):
            guard let session = sessionRegistry.session(for: flowKey), session.hasClientSequence else { return }
            guard session.observedInitialSyn, !session.didSendSyntheticSynAck else { return }
            guard let packet = PacketSynthesizer.synthesizeTCP(
                flowKey: flowKey,
                sequenceNumber: session.remoteNextSequence,
                acknowledgementNumber: session.clientNextSequence,
                flags: [.syn, .ack]
            ) else {
                return
            }
            session.markSynAckSent()
            writeSynthesizedPackets([packet])

        case let .connectFailed(flowKey):
            guard let session = sessionRegistry.session(for: flowKey) else { return }
            let ack = session.hasClientSequence ? session.clientNextSequence : 0
            guard let packet = PacketSynthesizer.synthesizeTCP(
                flowKey: flowKey,
                sequenceNumber: session.remoteNextSequence,
                acknowledgementNumber: ack,
                flags: [.rst, .ack]
            ) else {
                return
            }
            writeSynthesizedPackets([packet])

        default:
            return
        }
    }

    private func handleUDPEvent(_ event: PacketFlowUDPRelayEvent) {
        switch event {
        case let .upstreamDatagram(flowKey, payload):
            guard let packet = PacketSynthesizer.synthesizeUDP(flowKey: flowKey, payload: payload) else {
                return
            }
            writeSynthesizedPackets([packet])
        }
    }

    private func writeSynthesizedPackets(_ packets: [SynthesizedPacket]) {
        egressWriter.write(packets: packets) { [weak self] count, bytes in
            self?.pump.recordEgress(packets: count, bytes: bytes)
        }
    }
}

private final class InMemoryPacketFlowIO: PacketFlowIO {
    private struct IngressBatch {
        let packets: [Data]
        let protocols: [NSNumber]
    }

    private let queue = DispatchQueue(label: "com.uvays.FlowGuard.tests.in-memory-packet-flow")
    private var pendingIngress: [IngressBatch] = []
    private var readContinuation: (([Data], [NSNumber]) -> Void)?
    private var writes: [SynthesizedPacket] = []

    func readPacketBatch(_ completion: @escaping ([Data], [NSNumber]) -> Void) {
        queue.async {
            if self.pendingIngress.isEmpty {
                self.readContinuation = completion
                return
            }
            let next = self.pendingIngress.removeFirst()
            completion(next.packets, next.protocols)
        }
    }

    func writePacketBatch(_ packets: [Data], protocols: [NSNumber]) -> Bool {
        queue.async {
            for index in packets.indices {
                let proto = index < protocols.count ? protocols[index].int32Value : Int32(AF_INET)
                let version: IPVersion = proto == Int32(AF_INET6) ? .ipv6 : .ipv4
                self.writes.append(SynthesizedPacket(data: packets[index], ipVersion: version))
            }
        }
        return true
    }

    func emitIngress(_ packets: [Data]) {
        let protocols = packets.map { packet -> NSNumber in
            guard let parsed = IPPacketCodec.parse(packet: packet) else {
                return NSNumber(value: Int32(AF_INET))
            }
            let proto: Int32 = parsed.version == .ipv6 ? Int32(AF_INET6) : Int32(AF_INET)
            return NSNumber(value: proto)
        }

        queue.async {
            if let continuation = self.readContinuation {
                self.readContinuation = nil
                continuation(packets, protocols)
                return
            }
            self.pendingIngress.append(IngressBatch(packets: packets, protocols: protocols))
        }
    }

    func writtenPackets() -> [SynthesizedPacket] {
        queue.sync { writes }
    }
}

private enum IntegrationError: Error {
    case connectFailed
}

private final class IntegrationFakeTCPConnector: SOCKS5TCPConnecting {
    private var queuedResults: [Result<any SOCKS5TCPStreaming, Error>] = []

    func enqueue(result: Result<any SOCKS5TCPStreaming, Error>) {
        queuedResults.append(result)
    }

    func connect(
        socksPort: Int,
        destinationHost: String,
        destinationPort: UInt16,
        completion: @escaping (Result<any SOCKS5TCPStreaming, Error>) -> Void
    ) {
        if queuedResults.isEmpty {
            completion(.success(IntegrationFakeTCPStream()))
            return
        }
        completion(queuedResults.removeFirst())
    }
}

private final class IntegrationFakeTCPStream: SOCKS5TCPStreaming {
    func send(_ data: Data, completion: @escaping (Error?) -> Void) {
        completion(nil)
    }

    func receiveLoop(onData: @escaping (Data) -> Void, onComplete: @escaping (Error?) -> Void) {
        // No-op for integration scenarios in this test.
    }

    func cancel() {}
}

private final class IntegrationFakeUDPAssociateClient: SOCKS5UDPAssociating {
    private var queuedResults: [Result<any SOCKS5UDPAssociationing, Error>] = []

    func enqueue(result: Result<any SOCKS5UDPAssociationing, Error>) {
        queuedResults.append(result)
    }

    func open(socksPort: Int, completion: @escaping (Result<any SOCKS5UDPAssociationing, Error>) -> Void) {
        if queuedResults.isEmpty {
            completion(.success(IntegrationFakeUDPAssociation()))
            return
        }
        completion(queuedResults.removeFirst())
    }
}

private final class IntegrationFakeUDPAssociation: SOCKS5UDPAssociationing {
    private let queue = DispatchQueue(label: "com.uvays.FlowGuard.tests.integration-udp-association")
    private var onDatagram: ((SOCKS5UDPDatagram) -> Void)?

    private(set) var sentDatagrams: [SOCKS5UDPDatagram] = []
    private(set) var receiveLoopRegistered = false

    func send(datagram: SOCKS5UDPDatagram, completion: @escaping (Error?) -> Void) {
        queue.async {
            self.sentDatagrams.append(datagram)
            completion(nil)
        }
    }

    func receiveLoop(onDatagram: @escaping (SOCKS5UDPDatagram) -> Void, onComplete: @escaping (Error?) -> Void) {
        queue.async {
            self.onDatagram = onDatagram
            self.receiveLoopRegistered = true
        }
    }

    func close() {}

    func emit(datagram: SOCKS5UDPDatagram) {
        queue.async {
            self.onDatagram?(datagram)
        }
    }
}
