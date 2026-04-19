import Foundation
import XCTest

final class PacketFlowUDPRelayTests: XCTestCase {
    func testNonDNSDatagramIsBlocked() {
        let client = FakeUDPAssociateClient()
        let relay = makeRelay(associateClient: client)

        relay.handleIngressPackets([makePacket(destinationPort: 443, payload: Data([0x01]))])

        waitUntil("non-DNS flow processed") {
            relay.snapshot().activeSessions == 0
        }

        let snapshot = relay.snapshot()
        XCTAssertEqual(snapshot.activeSessions, 0)
        XCTAssertEqual(snapshot.associateAttempts, 0)
        XCTAssertEqual(snapshot.txPackets, 0)
        XCTAssertEqual(snapshot.dnsRoutedCount, 0)

        relay.stop()
    }

    func testDNSFlowAssociatesAndSendsDatagram() {
        let association = FakeUDPAssociation()
        let client = FakeUDPAssociateClient()
        client.enqueue(result: .success(association))

        var profile = TunnelProfile.default
        profile.socksPort = 19090
        profile.dnsMode = .plain

        let relay = makeRelay(profile: profile, associateClient: client)
        let payload = Data([0xDE, 0xAD, 0xBE, 0xEF])

        relay.handleIngressPackets([makePacket(destinationPort: 53, payload: payload)])

        waitUntil("dns datagram sent") {
            relay.snapshot().txPackets == 1
        }

        let snapshot = relay.snapshot()
        XCTAssertEqual(snapshot.activeSessions, 1)
        XCTAssertEqual(snapshot.associateAttempts, 1)
        XCTAssertEqual(snapshot.associateFailures, 0)
        XCTAssertEqual(snapshot.txPackets, 1)
        XCTAssertEqual(snapshot.txBytes, Int64(payload.count))
        XCTAssertEqual(snapshot.dnsRoutedCount, 1)

        XCTAssertEqual(client.calls.count, 1)
        XCTAssertEqual(client.calls.first?.socksPort, 19090)

        XCTAssertEqual(association.sent.count, 1)
        XCTAssertEqual(association.sent.first?.destinationHost, "8.8.8.8")
        XCTAssertEqual(association.sent.first?.destinationPort, 53)
        XCTAssertEqual(association.sent.first?.payload, payload)

        relay.stop()
    }

    func testAssociationFailureIncrementsCounterAndClosesSession() {
        let client = FakeUDPAssociateClient()
        client.enqueue(result: .failure(TestError.associateFailed))
        let relay = makeRelay(associateClient: client)

        relay.handleIngressPackets([makePacket(destinationPort: 53, payload: Data([0x01]))])

        waitUntil("associate failure handled") {
            let snapshot = relay.snapshot()
            return snapshot.associateFailures == 1 && snapshot.activeSessions == 0
        }

        let snapshot = relay.snapshot()
        XCTAssertEqual(snapshot.associateAttempts, 1)
        XCTAssertEqual(snapshot.associateFailures, 1)
        XCTAssertEqual(snapshot.activeSessions, 0)
        XCTAssertEqual(snapshot.sessionCloseTotal, 1)
        XCTAssertEqual(snapshot.sessionCloseAssociateFailed, 1)

        relay.stop()
    }

    func testSendFailureIncrementsTxFailuresAndClosesSession() {
        let association = FakeUDPAssociation()
        association.sendError = TestError.sendFailed
        let client = FakeUDPAssociateClient()
        client.enqueue(result: .success(association))

        let relay = makeRelay(associateClient: client)
        relay.handleIngressPackets([makePacket(destinationPort: 53, payload: Data([0x10, 0x11]))])

        waitUntil("send failure handled") {
            let snapshot = relay.snapshot()
            return snapshot.txFailures == 1 && snapshot.activeSessions == 0
        }

        let snapshot = relay.snapshot()
        XCTAssertEqual(snapshot.associateAttempts, 1)
        XCTAssertEqual(snapshot.txPackets, 0)
        XCTAssertEqual(snapshot.txFailures, 1)
        XCTAssertEqual(snapshot.activeSessions, 0)
        XCTAssertEqual(snapshot.sessionCloseTotal, 1)
        XCTAssertEqual(snapshot.sessionCloseSendFailed, 1)

        relay.stop()
    }

    func testIdleCleanupRemovesSession() {
        let association = FakeUDPAssociation()
        let client = FakeUDPAssociateClient()
        client.enqueue(result: .success(association))

        var now = Date()
        let relay = makeRelay(
            associateClient: client,
            now: { now },
            idleSessionMaxAge: 1
        )

        relay.handleIngressPackets([makePacket(destinationPort: 53, payload: Data([0x22]))])

        waitUntil("session is active") {
            relay.snapshot().activeSessions == 1
        }

        now = now.addingTimeInterval(2)
        relay.handleIngressPackets([])

        waitUntil("idle cleanup removed session") {
            relay.snapshot().activeSessions == 0
        }

        XCTAssertEqual(association.closeCount, 1)
        let snapshot = relay.snapshot()
        XCTAssertEqual(snapshot.sessionCloseTotal, 1)
        XCTAssertEqual(snapshot.sessionCloseIdleCleanup, 1)
        relay.stop()
    }

    func testBackpressureDropIncrementsCloseReasonCounters() {
        let client = FakeUDPAssociateClient()
        client.autoComplete = false
        let relay = makeRelay(associateClient: client)
        let payload = Data(repeating: 0x42, count: 60_000)
        let packets = Array(repeating: makePacket(destinationPort: 53, payload: payload), count: 5)

        relay.handleIngressPackets(packets)

        waitUntil("backpressure drop closes session") {
            let snapshot = relay.snapshot()
            return snapshot.backpressureDrops == 1 && snapshot.activeSessions == 0
        }

        let snapshot = relay.snapshot()
        XCTAssertEqual(snapshot.droppedDatagrams, 1)
        XCTAssertEqual(snapshot.backpressureDrops, 1)
        XCTAssertEqual(snapshot.sessionCloseTotal, 1)
        XCTAssertEqual(snapshot.sessionCloseBackpressureDrop, 1)

        relay.stop()
    }

    func testStopRecordsRelayStopCloseReason() {
        let association = FakeUDPAssociation()
        let client = FakeUDPAssociateClient()
        client.enqueue(result: .success(association))
        let relay = makeRelay(associateClient: client)

        relay.handleIngressPackets([makePacket(destinationPort: 53, payload: Data([0x01]))])
        waitUntil("udp session active before stop") {
            relay.snapshot().activeSessions == 1
        }
        relay.stop()

        let snapshot = relay.snapshot()
        XCTAssertEqual(snapshot.activeSessions, 0)
        XCTAssertEqual(snapshot.sessionCloseTotal, 1)
        XCTAssertEqual(snapshot.sessionCloseRelayStop, 1)
    }

    func testUpstreamDatagramCallbackIncrementsRxAndEmitsEvent() {
        let association = FakeUDPAssociation()
        let client = FakeUDPAssociateClient()
        client.enqueue(result: .success(association))

        let eventExpectation = expectation(description: "upstream datagram event")
        let receiveLoopReadyExpectation = expectation(description: "udp receive loop registered")
        association.onReceiveLoopRegistered = {
            receiveLoopReadyExpectation.fulfill()
        }
        var receivedFlowKey: UDPFlowKey?
        var receivedPayload: Data?

        let relay = makeRelay(associateClient: client, onEvent: { event in
            switch event {
            case let .upstreamDatagram(flowKey, payload):
                receivedFlowKey = flowKey
                receivedPayload = payload
                eventExpectation.fulfill()
            }
        })

        relay.handleIngressPackets([makePacket(destinationPort: 53, payload: Data([0x33]))])

        waitUntil("association is ready") {
            relay.snapshot().activeSessions == 1
        }
        wait(for: [receiveLoopReadyExpectation], timeout: 1.2)

        let upstreamPayload = Data([0xAB, 0xCD, 0xEF])
        association.emit(datagram: SOCKS5UDPDatagram(destinationHost: "1.1.1.1", destinationPort: 53, payload: upstreamPayload))

        wait(for: [eventExpectation], timeout: 1.2)

        waitUntil("rx counters updated") {
            let snapshot = relay.snapshot()
            return snapshot.rxPackets == 1 && snapshot.rxBytes == Int64(upstreamPayload.count)
        }

        XCTAssertEqual(receivedFlowKey?.sourceAddress, "10.0.0.2")
        XCTAssertEqual(receivedFlowKey?.destinationPort, 53)
        XCTAssertEqual(receivedPayload, upstreamPayload)

        relay.stop()
    }

    private func makeRelay(
        profile: TunnelProfile = .default,
        associateClient: any SOCKS5UDPAssociating,
        now: @escaping () -> Date = Date.init,
        idleSessionMaxAge: TimeInterval = 90,
        onEvent: ((PacketFlowUDPRelayEvent) -> Void)? = nil
    ) -> PacketFlowUDPRelay {
        let relay = PacketFlowUDPRelay(associateClient: associateClient, now: now, idleSessionMaxAge: idleSessionMaxAge)
        relay.start(profile: profile, log: { _ in }, onEvent: onEvent)
        return relay
    }

    private func makePacket(destinationPort: UInt16, payload: Data) -> Data {
        let packet = TestPacketBuilders.makeUDPPacket(
            ipVersion: .ipv4,
            sourceAddress: "10.0.0.2",
            destinationAddress: "93.184.216.34",
            sourcePort: 55000,
            destinationPort: destinationPort,
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
    case associateFailed
    case sendFailed
}

private final class FakeUDPAssociateClient: SOCKS5UDPAssociating {
    struct Call {
        let socksPort: Int
    }

    private var queuedResults: [Result<any SOCKS5UDPAssociationing, Error>] = []
    private var pendingCompletions: [((Result<any SOCKS5UDPAssociationing, Error>) -> Void)] = []
    var autoComplete = true
    var calls: [Call] = []

    func enqueue(result: Result<any SOCKS5UDPAssociationing, Error>) {
        queuedResults.append(result)
    }

    func open(socksPort: Int, completion: @escaping (Result<any SOCKS5UDPAssociationing, Error>) -> Void) {
        calls.append(Call(socksPort: socksPort))
        if autoComplete {
            if queuedResults.isEmpty {
                completion(.success(FakeUDPAssociation()))
                return
            }
            completion(queuedResults.removeFirst())
            return
        }
        pendingCompletions.append(completion)
    }

    func completeNext(with result: Result<any SOCKS5UDPAssociationing, Error>) {
        guard !pendingCompletions.isEmpty else {
            queuedResults.append(result)
            return
        }
        let completion = pendingCompletions.removeFirst()
        completion(result)
    }
}

private final class FakeUDPAssociation: SOCKS5UDPAssociationing {
    var sent: [SOCKS5UDPDatagram] = []
    var sendError: Error?
    var closeCount: Int = 0
    var onReceiveLoopRegistered: (() -> Void)?

    private var onDatagram: ((SOCKS5UDPDatagram) -> Void)?
    private var onComplete: ((Error?) -> Void)?

    func send(datagram: SOCKS5UDPDatagram, completion: @escaping (Error?) -> Void) {
        sent.append(datagram)
        completion(sendError)
    }

    func receiveLoop(onDatagram: @escaping (SOCKS5UDPDatagram) -> Void, onComplete: @escaping (Error?) -> Void) {
        self.onDatagram = onDatagram
        self.onComplete = onComplete
        onReceiveLoopRegistered?()
    }

    func close() {
        closeCount += 1
    }

    func emit(datagram: SOCKS5UDPDatagram) {
        onDatagram?(datagram)
    }

    func complete(error: Error?) {
        onComplete?(error)
    }
}
