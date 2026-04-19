import Foundation
import Network
import XCTest

final class PacketFlowTCPSessionTests: XCTestCase {
    func testApplyEventUpdatesStateAndReturnsTransition() {
        let session = PacketFlowTCPSession(key: makeFlowKey(), now: Date(timeIntervalSince1970: 0))

        let syn = session.apply(.inbound(flags: [.syn], hasPayload: false))
        XCTAssertEqual(syn.nextState, .synReceived)
        XCTAssertEqual(session.state, .synReceived)

        let ack = session.apply(.inbound(flags: [.ack], hasPayload: false))
        XCTAssertEqual(ack.nextState, .connecting)
        XCTAssertEqual(session.state, .connecting)

        let connected = session.apply(.socksConnected)
        XCTAssertEqual(connected.nextState, .established)
        XCTAssertEqual(session.state, .established)
    }

    func testObserveInboundPacketTracksClientSequenceWithSynAndPayload() {
        let session = PacketFlowTCPSession(key: makeFlowKey())

        let first = TCPPacket(
            flowKey: makeFlowKey(),
            sequenceNumber: 100,
            acknowledgementNumber: 0,
            flags: [.syn],
            windowSize: 1024,
            payload: Data([1, 2, 3])
        )
        session.observeInboundPacket(first)

        XCTAssertTrue(session.observedInitialSyn)
        XCTAssertTrue(session.hasClientSequence)
        XCTAssertEqual(session.clientNextSequence, 104)

        let lower = TCPPacket(
            flowKey: makeFlowKey(),
            sequenceNumber: 99,
            acknowledgementNumber: 0,
            flags: [.ack],
            windowSize: 1024,
            payload: Data([9])
        )
        session.observeInboundPacket(lower)
        XCTAssertEqual(session.clientNextSequence, 104)

        let fin = TCPPacket(
            flowKey: makeFlowKey(),
            sequenceNumber: 105,
            acknowledgementNumber: 0,
            flags: [.fin, .ack],
            windowSize: 1024,
            payload: Data([8, 7])
        )
        session.observeInboundPacket(fin)
        XCTAssertEqual(session.clientNextSequence, 108)
    }

    func testMarkSynAckSentAndConsumeRemoteSequenceBookkeeping() {
        let session = PacketFlowTCPSession(key: makeFlowKey(sourcePort: 1200, destinationPort: 34))
        let initial = session.remoteNextSequence

        session.markSynAckSent()
        XCTAssertTrue(session.didSendSyntheticSynAck)
        XCTAssertEqual(session.remoteNextSequence, initial + 1)

        session.consumeRemoteSequence(bytes: 10)
        XCTAssertEqual(session.remoteNextSequence, initial + 11)

        session.consumeRemoteSequence(bytes: 0)
        session.consumeRemoteSequence(bytes: -5)
        XCTAssertEqual(session.remoteNextSequence, initial + 11)
    }

    func testEnqueueDrainAndDetachClearsBufferedPayload() {
        let session = PacketFlowTCPSession(key: makeFlowKey(), maxBufferedBytes: 4)

        XCTAssertEqual(session.enqueueUpstreamPayload(Data([1, 2])), .accepted)
        XCTAssertEqual(session.enqueueUpstreamPayload(Data([3, 4])), .accepted)
        XCTAssertEqual(session.enqueueUpstreamPayload(Data([5])), .dropped)

        session.detachStream()
        XCTAssertTrue(session.drainUpstreamPayload().isEmpty)

        XCTAssertEqual(session.enqueueUpstreamPayload(Data([7, 8, 9])), .accepted)
        XCTAssertEqual(session.drainUpstreamPayload(), [Data([7, 8, 9])])
    }

    func testAttachAndCloseStreamDetachesAndClearsBuffer() {
        let session = PacketFlowTCPSession(key: makeFlowKey())
        let stream = makeStream()

        session.attachStream(stream)
        XCTAssertNotNil(session.stream)

        XCTAssertEqual(session.enqueueUpstreamPayload(Data([1, 2, 3])), .accepted)

        session.closeStream()
        XCTAssertNil(session.stream)
        XCTAssertTrue(session.drainUpstreamPayload().isEmpty)
    }

    func testTouchUpdatesLastSeenTimestamp() {
        let start = Date(timeIntervalSince1970: 100)
        let later = Date(timeIntervalSince1970: 200)
        let session = PacketFlowTCPSession(key: makeFlowKey(), now: start)

        XCTAssertEqual(session.lastSeenAt, start)
        session.touch(at: later)
        XCTAssertEqual(session.lastSeenAt, later)
    }

    private func makeFlowKey(sourcePort: UInt16 = 55000, destinationPort: UInt16 = 443) -> TCPFlowKey {
        TCPFlowKey(
            ipVersion: .ipv4,
            sourceAddress: "10.0.0.2",
            destinationAddress: "93.184.216.34",
            sourcePort: sourcePort,
            destinationPort: destinationPort
        )
    }

    private func makeStream() -> SOCKS5TCPStream {
        let connection = NWConnection(
            host: .ipv4(IPv4Address("127.0.0.1")!),
            port: .init(rawValue: 9)!,
            using: .tcp
        )
        return SOCKS5TCPStream(connection: connection, queue: DispatchQueue(label: "test.stream"))
    }
}
