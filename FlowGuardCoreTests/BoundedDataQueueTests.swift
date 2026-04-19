import Foundation
import XCTest

final class BoundedDataQueueTests: XCTestCase {
    func testAcceptsDataWithinCapacity() {
        let queue = BoundedDataQueue(maxBytes: 8)

        XCTAssertEqual(queue.enqueue(Data([1, 2, 3])), .accepted)
        XCTAssertEqual(queue.enqueue(Data([4, 5])), .accepted)
        XCTAssertEqual(queue.byteCount(), 5)
    }

    func testDropsDataWhenOverflowWouldHappen() {
        let queue = BoundedDataQueue(maxBytes: 4)

        XCTAssertEqual(queue.enqueue(Data([1, 2, 3, 4])), .accepted)
        XCTAssertEqual(queue.enqueue(Data([5])), .dropped)
        XCTAssertEqual(queue.byteCount(), 4)
    }

    func testDrainReturnsAllChunksAndResetsByteCount() {
        let queue = BoundedDataQueue(maxBytes: 16)
        let first = Data([1, 2])
        let second = Data([3, 4, 5])

        _ = queue.enqueue(first)
        _ = queue.enqueue(second)

        let drained = queue.drain()
        XCTAssertEqual(drained, [first, second])
        XCTAssertEqual(queue.byteCount(), 0)
        XCTAssertTrue(queue.drain().isEmpty)
    }

    func testClearResetsQueueState() {
        let queue = BoundedDataQueue(maxBytes: 8)

        _ = queue.enqueue(Data([1, 2, 3]))
        queue.clear()

        XCTAssertEqual(queue.byteCount(), 0)
        XCTAssertTrue(queue.drain().isEmpty)
        XCTAssertEqual(queue.enqueue(Data([9, 9, 9, 9])), .accepted)
    }

    func testEmptyPayloadIsAcceptedWithoutAffectingCapacity() {
        let queue = BoundedDataQueue(maxBytes: 1)

        XCTAssertEqual(queue.enqueue(Data()), .accepted)
        XCTAssertEqual(queue.byteCount(), 0)
    }
}
