import Foundation

enum TCPSessionState: Equatable, Sendable {
    case idle
    case synReceived
    case connecting
    case established
    case halfClosedLocal
    case halfClosedRemote
    case closing
    case closed
    case reset
    case failed(String)
}

enum TCPSessionEvent: Sendable {
    case inbound(flags: TCPFlags, hasPayload: Bool)
    case socksConnected
    case socksConnectFailed(String)
    case remoteClosed
}

enum TCPSessionAction: Sendable {
    case connectSocks
    case flushBufferedPayload
    case closeConnection
    case none
}

struct TCPSessionTransition: Sendable {
    let nextState: TCPSessionState
    let actions: [TCPSessionAction]
}

enum TCPStateMachine {
    static func transition(from state: TCPSessionState, event: TCPSessionEvent) -> TCPSessionTransition {
        switch event {
        case let .inbound(flags, hasPayload):
            return transitionOnInbound(from: state, flags: flags, hasPayload: hasPayload)
        case .socksConnected:
            switch state {
            case .connecting, .synReceived:
                return TCPSessionTransition(nextState: .established, actions: [.flushBufferedPayload])
            case .closing, .reset, .closed:
                return TCPSessionTransition(nextState: state, actions: [.closeConnection])
            default:
                return TCPSessionTransition(nextState: state, actions: [.none])
            }
        case let .socksConnectFailed(reason):
            return TCPSessionTransition(nextState: .failed(reason), actions: [.closeConnection])
        case .remoteClosed:
            switch state {
            case .halfClosedLocal:
                return TCPSessionTransition(nextState: .closing, actions: [.closeConnection])
            case .established:
                return TCPSessionTransition(nextState: .halfClosedRemote, actions: [.none])
            case .closing:
                return TCPSessionTransition(nextState: .closed, actions: [.closeConnection])
            case .reset, .closed:
                return TCPSessionTransition(nextState: state, actions: [.none])
            default:
                return TCPSessionTransition(nextState: .closed, actions: [.closeConnection])
            }
        }
    }

    private static func transitionOnInbound(
        from state: TCPSessionState,
        flags: TCPFlags,
        hasPayload: Bool
    ) -> TCPSessionTransition {
        if flags.contains(.rst) {
            return TCPSessionTransition(nextState: .reset, actions: [.closeConnection])
        }

        if flags.contains(.syn) && !flags.contains(.ack) {
            switch state {
            case .idle, .closed, .failed:
                return TCPSessionTransition(nextState: .synReceived, actions: [.connectSocks])
            default:
                return TCPSessionTransition(nextState: state, actions: [.none])
            }
        }

        if flags.contains(.fin) {
            switch state {
            case .established:
                return TCPSessionTransition(nextState: .halfClosedLocal, actions: [.none])
            case .halfClosedRemote:
                return TCPSessionTransition(nextState: .closing, actions: [.closeConnection])
            case .synReceived, .connecting:
                return TCPSessionTransition(nextState: .halfClosedLocal, actions: [.none])
            case .closing, .closed, .reset:
                return TCPSessionTransition(nextState: state, actions: [.none])
            case .failed:
                return TCPSessionTransition(nextState: state, actions: [.closeConnection])
            case .halfClosedLocal:
                return TCPSessionTransition(nextState: state, actions: [.none])
            case .idle:
                return TCPSessionTransition(nextState: .halfClosedLocal, actions: [.none])
            }
        }

        if flags.contains(.ack) || hasPayload {
            switch state {
            case .synReceived:
                return TCPSessionTransition(nextState: .connecting, actions: [.none])
            case .connecting, .established, .halfClosedLocal, .halfClosedRemote:
                return TCPSessionTransition(nextState: state, actions: [.none])
            case .idle:
                if hasPayload {
                    return TCPSessionTransition(nextState: .connecting, actions: [.connectSocks])
                }
                return TCPSessionTransition(nextState: state, actions: [.none])
            case .closing, .closed, .reset:
                return TCPSessionTransition(nextState: state, actions: [.none])
            case .failed:
                return TCPSessionTransition(nextState: state, actions: [.closeConnection])
            }
        }

        return TCPSessionTransition(nextState: state, actions: [.none])
    }
}
