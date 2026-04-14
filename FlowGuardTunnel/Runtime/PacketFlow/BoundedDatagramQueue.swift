import Foundation

struct PendingUDPSendDatagram: Sendable {
    let destinationHost: String
    let destinationPort: UInt16
    let payload: Data

    var byteSize: Int {
        payload.count
    }
}

enum BoundedDatagramQueueResult: Sendable {
    case accepted
    case dropped
}

final class BoundedDatagramQueue {
    private let queue = DispatchQueue(label: "com.uvays.FlowGuard.packetflow.bounded-datagram-queue")
    private let maxBytes: Int
    private var items: [PendingUDPSendDatagram] = []
    private var totalBytes = 0

    init(maxBytes: Int) {
        self.maxBytes = max(1, maxBytes)
    }

    func enqueue(_ datagram: PendingUDPSendDatagram) -> BoundedDatagramQueueResult {
        guard !datagram.payload.isEmpty else { return .accepted }
        return queue.sync {
            if totalBytes + datagram.byteSize > maxBytes {
                return .dropped
            }
            items.append(datagram)
            totalBytes += datagram.byteSize
            return .accepted
        }
    }

    func drain() -> [PendingUDPSendDatagram] {
        queue.sync {
            let current = items
            items.removeAll(keepingCapacity: false)
            totalBytes = 0
            return current
        }
    }

    func clear() {
        _ = drain()
    }
}
