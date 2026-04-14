import Foundation

enum BoundedDataQueueResult: Sendable {
    case accepted
    case dropped
}

final class BoundedDataQueue {
    private let queue = DispatchQueue(label: "com.uvays.FlowGuard.packetflow.bounded-queue")
    private let maxBytes: Int
    private var chunks: [Data] = []
    private var totalBytes = 0

    init(maxBytes: Int) {
        self.maxBytes = max(1, maxBytes)
    }

    func enqueue(_ data: Data) -> BoundedDataQueueResult {
        guard !data.isEmpty else { return .accepted }
        return queue.sync {
            if totalBytes + data.count > maxBytes {
                return .dropped
            }
            chunks.append(data)
            totalBytes += data.count
            return .accepted
        }
    }

    func drain() -> [Data] {
        queue.sync {
            let values = chunks
            chunks.removeAll(keepingCapacity: false)
            totalBytes = 0
            return values
        }
    }

    func clear() {
        _ = drain()
    }

    func byteCount() -> Int {
        queue.sync { totalBytes }
    }
}
