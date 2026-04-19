import Foundation

enum PacketFlowUDPSessionState: Sendable {
    case idle
    case associating
    case ready
    case closing
    case closed
    case failed(String)
}

final class PacketFlowUDPSession {
    let key: UDPFlowKey
    let createdAt: Date
    private(set) var lastSeenAt: Date
    private(set) var state: PacketFlowUDPSessionState
    private(set) var association: (any SOCKS5UDPAssociationing)?
    private let queue: BoundedDatagramQueue

    init(key: UDPFlowKey, now: Date = Date(), maxBufferedBytes: Int = 256 * 1024) {
        self.key = key
        self.createdAt = now
        self.lastSeenAt = now
        self.state = .idle
        self.queue = BoundedDatagramQueue(maxBytes: maxBufferedBytes)
    }

    func touch(at now: Date = Date()) {
        lastSeenAt = now
    }

    func setState(_ state: PacketFlowUDPSessionState) {
        self.state = state
        touch()
    }

    func enqueue(_ datagram: PendingUDPSendDatagram) -> BoundedDatagramQueueResult {
        touch()
        return queue.enqueue(datagram)
    }

    func drain() -> [PendingUDPSendDatagram] {
        touch()
        return queue.drain()
    }

    func attachAssociation(_ association: any SOCKS5UDPAssociationing) {
        self.association = association
        setState(.ready)
    }

    func close() {
        setState(.closing)
        association?.close()
        association = nil
        queue.clear()
        setState(.closed)
    }
}
