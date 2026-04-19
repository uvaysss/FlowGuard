import Foundation

final class PacketFlowTCPSession {
    let key: TCPFlowKey
    let createdAt: Date
    private(set) var lastSeenAt: Date
    private(set) var state: TCPSessionState
    private(set) var stream: (any SOCKS5TCPStreaming)?
    private let upstreamBuffer: BoundedDataQueue
    private(set) var clientNextSequence: UInt32 = 0
    private(set) var remoteNextSequence: UInt32 = 0
    private(set) var hasClientSequence = false
    private(set) var didSendSyntheticSynAck = false
    private(set) var observedInitialSyn = false

    init(key: TCPFlowKey, now: Date = Date(), maxBufferedBytes: Int = 256 * 1024) {
        self.key = key
        self.createdAt = now
        self.lastSeenAt = now
        self.state = .idle
        self.upstreamBuffer = BoundedDataQueue(maxBytes: maxBufferedBytes)
        let seed = key.sourcePort ^ key.destinationPort
        self.remoteNextSequence = UInt32(100_000 + Int(seed))
    }

    func touch(at date: Date = Date()) {
        lastSeenAt = date
    }

    func apply(_ event: TCPSessionEvent) -> TCPSessionTransition {
        let transition = TCPStateMachine.transition(from: state, event: event)
        state = transition.nextState
        touch()
        return transition
    }

    func enqueueUpstreamPayload(_ payload: Data) -> BoundedDataQueueResult {
        touch()
        return upstreamBuffer.enqueue(payload)
    }

    func drainUpstreamPayload() -> [Data] {
        touch()
        return upstreamBuffer.drain()
    }

    func attachStream(_ stream: any SOCKS5TCPStreaming) {
        self.stream = stream
        touch()
    }

    func observeInboundPacket(_ packet: TCPPacket) {
        if packet.flags.contains(.syn) && !packet.flags.contains(.ack) {
            observedInitialSyn = true
        }
        let advanceBy = UInt32(packet.payload.count)
            + (packet.flags.contains(.syn) ? 1 : 0)
            + (packet.flags.contains(.fin) ? 1 : 0)
        let candidate = packet.sequenceNumber &+ advanceBy
        if !hasClientSequence || candidate > clientNextSequence {
            clientNextSequence = candidate
            hasClientSequence = true
        }
        touch()
    }

    func markSynAckSent() {
        didSendSyntheticSynAck = true
        remoteNextSequence = remoteNextSequence &+ 1
    }

    func consumeRemoteSequence(bytes: Int) {
        guard bytes > 0 else { return }
        remoteNextSequence = remoteNextSequence &+ UInt32(bytes)
    }

    func detachStream() {
        stream = nil
        upstreamBuffer.clear()
        touch()
    }

    func closeStream() {
        stream?.cancel()
        detachStream()
    }
}
