import XCTest

final class TCPStateMachineTests: XCTestCase {
    func testIdleToSynReceivedToConnectingToEstablished() {
        var state: TCPSessionState = .idle

        let syn = TCPStateMachine.transition(from: state, event: .inbound(flags: [.syn], hasPayload: false))
        XCTAssertEqual(syn.nextState, .synReceived)
        XCTAssertEqual(syn.actions, [.connectSocks])
        state = syn.nextState

        let ack = TCPStateMachine.transition(from: state, event: .inbound(flags: [.ack], hasPayload: false))
        XCTAssertEqual(ack.nextState, .connecting)
        XCTAssertEqual(ack.actions, [.none])
        state = ack.nextState

        let connected = TCPStateMachine.transition(from: state, event: .socksConnected)
        XCTAssertEqual(connected.nextState, .established)
        XCTAssertEqual(connected.actions, [.flushBufferedPayload])
    }

    func testInboundRstForcesResetAndCloseAction() {
        let transition = TCPStateMachine.transition(
            from: .established,
            event: .inbound(flags: [.rst], hasPayload: false)
        )

        XCTAssertEqual(transition.nextState, .reset)
        XCTAssertEqual(transition.actions, [.closeConnection])
    }

    func testInboundFinFromEstablishedMovesToHalfClosedLocal() {
        let transition = TCPStateMachine.transition(
            from: .established,
            event: .inbound(flags: [.fin, .ack], hasPayload: false)
        )

        XCTAssertEqual(transition.nextState, .halfClosedLocal)
        XCTAssertEqual(transition.actions, [.none])
    }

    func testInboundFinFromHalfClosedRemoteMovesToClosingAndClosesConnection() {
        let transition = TCPStateMachine.transition(
            from: .halfClosedRemote,
            event: .inbound(flags: [.fin], hasPayload: false)
        )

        XCTAssertEqual(transition.nextState, .closing)
        XCTAssertEqual(transition.actions, [.closeConnection])
    }

    func testRemoteClosedFromEstablishedMovesToHalfClosedRemote() {
        let transition = TCPStateMachine.transition(from: .established, event: .remoteClosed)

        XCTAssertEqual(transition.nextState, .halfClosedRemote)
        XCTAssertEqual(transition.actions, [.none])
    }

    func testRemoteClosedFromHalfClosedLocalMovesToClosingAndClosesConnection() {
        let transition = TCPStateMachine.transition(from: .halfClosedLocal, event: .remoteClosed)

        XCTAssertEqual(transition.nextState, .closing)
        XCTAssertEqual(transition.actions, [.closeConnection])
    }

    func testRemoteClosedFromClosingMovesToClosedAndClosesConnection() {
        let transition = TCPStateMachine.transition(from: .closing, event: .remoteClosed)

        XCTAssertEqual(transition.nextState, .closed)
        XCTAssertEqual(transition.actions, [.closeConnection])
    }

    func testIdleWithPayloadStartsConnectingAndRequestsSocksConnect() {
        let transition = TCPStateMachine.transition(
            from: .idle,
            event: .inbound(flags: [], hasPayload: true)
        )

        XCTAssertEqual(transition.nextState, .connecting)
        XCTAssertEqual(transition.actions, [.connectSocks])
    }
}
