import Foundation
import XCTest

final class PacketFlowTCPRelayTests: XCTestCase {
    func testSynStartsSessionAndConnectAttempt() {
        let registry = PacketFlowSessionRegistry()
        let connector = FakeConnector()
        let relay = makeRelay(registry: registry, connector: connector)

        relay.handleIngressPackets([makePacket(flags: [.syn])])

        waitUntil("connect attempt recorded") {
            relay.snapshot().connectAttempts == 1
        }

        let snapshot = relay.snapshot()
        XCTAssertEqual(snapshot.activeSessions, 1)
        XCTAssertEqual(snapshot.connectAttempts, 1)
        XCTAssertTrue(connector.calls.contains { $0.destinationPort == 443 })

        relay.stop()
    }

    func testPayloadIsBufferedUntilConnectThenFlushed() {
        let registry = PacketFlowSessionRegistry()
        let connector = FakeConnector()
        connector.autoComplete = false
        let stream = FakeStream()
        let relay = makeRelay(registry: registry, connector: connector)

        relay.handleIngressPackets([makePacket(flags: [.ack], payload: Data([0x01, 0x02, 0x03]))])

        waitUntil("session created and connect started") {
            relay.snapshot().connectAttempts == 1 && relay.snapshot().activeSessions == 1
        }
        XCTAssertEqual(relay.snapshot().upstreamSendAttempts, 0)
        XCTAssertTrue(stream.sent.isEmpty)

        connector.completeNext(with: .success(stream))

        waitUntil("buffer flushed after connect") {
            relay.snapshot().upstreamSendAttempts == 1
        }

        let snapshot = relay.snapshot()
        XCTAssertEqual(snapshot.upstreamSendAttempts, 1)
        XCTAssertEqual(snapshot.upstreamBytesSent, 3)
        XCTAssertEqual(stream.sent, [Data([0x01, 0x02, 0x03])])

        relay.stop()
    }

    func testConnectFailureIncrementsCounterAndClosesSession() {
        let registry = PacketFlowSessionRegistry()
        let connector = FakeConnector()
        connector.enqueue(result: .failure(TestError.connectFailed))
        let relay = makeRelay(registry: registry, connector: connector)

        relay.handleIngressPackets([makePacket(flags: [.syn])])

        waitUntil("connect failure handled") {
            let snapshot = relay.snapshot()
            return snapshot.connectFailures == 1 && snapshot.activeSessions == 0
        }

        let snapshot = relay.snapshot()
        XCTAssertEqual(snapshot.connectAttempts, 1)
        XCTAssertEqual(snapshot.connectFailures, 1)
        XCTAssertEqual(snapshot.activeSessions, 0)
        XCTAssertEqual(snapshot.sessionCloseTotal, 1)
        XCTAssertEqual(snapshot.sessionCloseStateClose, 1)

        relay.stop()
    }

    func testSendFailureIncrementsCounterAndClosesSession() {
        let registry = PacketFlowSessionRegistry()
        let connector = FakeConnector()
        let stream = FakeStream()
        stream.sendError = TestError.sendFailed
        connector.enqueue(result: .success(stream))
        let relay = makeRelay(registry: registry, connector: connector)

        relay.handleIngressPackets([makePacket(flags: [.syn])])
        waitUntil("connected") {
            relay.snapshot().connectAttempts == 1
        }

        relay.handleIngressPackets([makePacket(flags: [.ack], sequence: 2, payload: Data([0x10]))])

        waitUntil("send failure handled") {
            let snapshot = relay.snapshot()
            return snapshot.upstreamSendFailures == 1 && snapshot.activeSessions == 0
        }

        let snapshot = relay.snapshot()
        XCTAssertEqual(snapshot.upstreamSendAttempts, 1)
        XCTAssertEqual(snapshot.upstreamSendFailures, 1)
        XCTAssertEqual(snapshot.activeSessions, 0)
        XCTAssertEqual(snapshot.sessionCloseTotal, 1)
        XCTAssertEqual(snapshot.sessionCloseSendFailed, 1)

        relay.stop()
    }

    func testBackpressureDropIncrementsCloseReasonCounters() {
        let registry = PacketFlowSessionRegistry()
        let connector = FakeConnector()
        connector.autoComplete = false
        let relay = makeRelay(registry: registry, connector: connector)
        let chunk = Data(repeating: 0xAB, count: 60_000)
        let packets = (0..<5).map { index in
            makePacket(flags: [.ack], sequence: UInt32(1 + index * 60_000), payload: chunk)
        }

        relay.handleIngressPackets(packets)

        waitUntil("backpressure drop closes session") {
            let snapshot = relay.snapshot()
            return snapshot.backpressureDrops == 1 && snapshot.activeSessions == 0
        }

        let snapshot = relay.snapshot()
        XCTAssertEqual(snapshot.droppedPayloadChunks, 1)
        XCTAssertEqual(snapshot.backpressureDrops, 1)
        XCTAssertEqual(snapshot.sessionCloseTotal, 1)
        XCTAssertEqual(snapshot.sessionCloseBackpressureDrop, 1)

        relay.stop()
    }

    func testStopRecordsRelayStopCloseReason() {
        let registry = PacketFlowSessionRegistry()
        let connector = FakeConnector()
        connector.autoComplete = false
        let relay = makeRelay(registry: registry, connector: connector)

        relay.handleIngressPackets([makePacket(flags: [.syn])])

        waitUntil("session active before stop") {
            relay.snapshot().activeSessions == 1
        }
        relay.stop()

        let snapshot = relay.snapshot()
        XCTAssertEqual(snapshot.activeSessions, 0)
        XCTAssertEqual(snapshot.sessionCloseTotal, 1)
        XCTAssertEqual(snapshot.sessionCloseRelayStop, 1)
    }

    func testMalformedTcpIncrementsCounter() {
        let registry = PacketFlowSessionRegistry()
        let connector = FakeConnector()
        let relay = makeRelay(registry: registry, connector: connector)

        let valid = TestPacketBuilders.makeTCPPacket(
            ipVersion: .ipv4,
            sourceAddress: "10.0.0.2",
            destinationAddress: "93.184.216.34",
            sourcePort: 55000,
            destinationPort: 443,
            sequenceNumber: 1,
            acknowledgementNumber: 0,
            flags: [.ack]
        )
        XCTAssertNotNil(valid)

        var malformed = valid!
        // IPv4 header is 20 bytes; TCP data offset byte is at TCP + 12.
        malformed[32] = 0x40

        relay.handleIngressPackets([malformed])

        waitUntil("malformed counter updated") {
            relay.snapshot().malformedPackets == 1
        }

        XCTAssertEqual(relay.snapshot().malformedPackets, 1)
        XCTAssertEqual(relay.snapshot().activeSessions, 0)

        relay.stop()
    }

    func testAckWithoutPayloadIgnoredForRecentlyClosedFlow() {
        let registry = PacketFlowSessionRegistry()
        let connector = FakeConnector()
        connector.enqueue(result: .failure(TestError.connectFailed))
        let relay = makeRelay(registry: registry, connector: connector)

        relay.handleIngressPackets([makePacket(flags: [.syn])])
        waitUntil("flow closed after connect failure") {
            let snapshot = relay.snapshot()
            return snapshot.connectFailures == 1 && snapshot.activeSessions == 0
        }

        relay.handleIngressPackets([makePacket(flags: [.ack], sequence: 2)])

        usleep(60_000)
        let snapshot = relay.snapshot()
        XCTAssertEqual(snapshot.connectAttempts, 1)
        XCTAssertEqual(snapshot.connectFailures, 1)
        XCTAssertEqual(snapshot.activeSessions, 0)

        relay.stop()
    }

    private func makeRelay(registry: PacketFlowSessionRegistry, connector: FakeConnector) -> PacketFlowTCPRelay {
        let relay = PacketFlowTCPRelay(sessionRegistry: registry, connector: connector)
        relay.start(profile: .default, log: { _ in })
        return relay
    }

    private func makePacket(flags: TCPFlags, sequence: UInt32 = 1, payload: Data = Data()) -> Data {
        let packet = TestPacketBuilders.makeTCPPacket(
            ipVersion: .ipv4,
            sourceAddress: "10.0.0.2",
            destinationAddress: "93.184.216.34",
            sourcePort: 55000,
            destinationPort: 443,
            sequenceNumber: sequence,
            acknowledgementNumber: 0,
            flags: flags,
            payload: payload
        )
        XCTAssertNotNil(packet)
        return packet!
    }

    private func waitUntil(_ description: String, timeout: TimeInterval = 1.0, condition: @escaping () -> Bool) {
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
        wait(for: [exp], timeout: timeout + 0.2)
    }
}

private enum TestError: Error {
    case connectFailed
    case sendFailed
}

private final class FakeConnector: SOCKS5TCPConnecting {
    struct Call {
        let socksPort: Int
        let destinationHost: String
        let destinationPort: UInt16
    }

    private var queuedResults: [Result<any SOCKS5TCPStreaming, Error>] = []
    private var pendingCompletions: [((Result<any SOCKS5TCPStreaming, Error>) -> Void)] = []

    var autoComplete = true
    var calls: [Call] = []

    func enqueue(result: Result<any SOCKS5TCPStreaming, Error>) {
        queuedResults.append(result)
    }

    func completeNext(with result: Result<any SOCKS5TCPStreaming, Error>) {
        guard !pendingCompletions.isEmpty else {
            queuedResults.append(result)
            return
        }
        let completion = pendingCompletions.removeFirst()
        completion(result)
    }

    func connect(
        socksPort: Int,
        destinationHost: String,
        destinationPort: UInt16,
        completion: @escaping (Result<any SOCKS5TCPStreaming, Error>) -> Void
    ) {
        calls.append(Call(socksPort: socksPort, destinationHost: destinationHost, destinationPort: destinationPort))

        if autoComplete {
            let result = queuedResults.isEmpty ? .success(FakeStream()) : queuedResults.removeFirst()
            completion(result)
            return
        }

        pendingCompletions.append(completion)
    }
}

private final class FakeStream: SOCKS5TCPStreaming {
    var sent: [Data] = []
    var sendError: Error?
    var cancelCount: Int = 0

    func send(_ data: Data, completion: @escaping (Error?) -> Void) {
        sent.append(data)
        completion(sendError)
    }

    func receiveLoop(onData: @escaping (Data) -> Void, onComplete: @escaping (Error?) -> Void) {
        // No-op in tests; scenarios here focus on connect/send behavior.
    }

    func cancel() {
        cancelCount += 1
    }
}
