import Foundation
import XCTest

final class BoundedDatagramQueueTests: XCTestCase {
    func testAcceptsDatagramsWithinCapacity() {
        let queue = BoundedDatagramQueue(maxBytes: 6)

        XCTAssertEqual(queue.enqueue(makeDatagram([1, 2, 3])), .accepted)
        XCTAssertEqual(queue.enqueue(makeDatagram([4, 5])), .accepted)

        let drained = queue.drain()
        XCTAssertEqual(drained.count, 2)
        XCTAssertEqual(drained[0].payload, Data([1, 2, 3]))
        XCTAssertEqual(drained[1].payload, Data([4, 5]))
    }

    func testDropsDatagramWhenOverflowWouldHappen() {
        let queue = BoundedDatagramQueue(maxBytes: 3)

        XCTAssertEqual(queue.enqueue(makeDatagram([1, 2, 3])), .accepted)
        XCTAssertEqual(queue.enqueue(makeDatagram([4])), .dropped)

        let drained = queue.drain()
        XCTAssertEqual(drained.count, 1)
        XCTAssertEqual(drained[0].payload, Data([1, 2, 3]))
    }

    func testDrainClearsQueue() {
        let queue = BoundedDatagramQueue(maxBytes: 16)

        _ = queue.enqueue(makeDatagram([1]))
        _ = queue.enqueue(makeDatagram([2]))

        XCTAssertEqual(queue.drain().count, 2)
        XCTAssertTrue(queue.drain().isEmpty)
    }

    func testClearResetsQueueAndAllowsReuse() {
        let queue = BoundedDatagramQueue(maxBytes: 3)

        _ = queue.enqueue(makeDatagram([1, 2]))
        queue.clear()

        XCTAssertTrue(queue.drain().isEmpty)
        XCTAssertEqual(queue.enqueue(makeDatagram([7, 8, 9])), .accepted)
    }

    func testEmptyDatagramPayloadIsAcceptedAndNotEnqueued() {
        let queue = BoundedDatagramQueue(maxBytes: 1)

        XCTAssertEqual(queue.enqueue(makeDatagram([])), .accepted)
        XCTAssertTrue(queue.drain().isEmpty)
    }

    private func makeDatagram(_ bytes: [UInt8]) -> PendingUDPSendDatagram {
        PendingUDPSendDatagram(
            destinationHost: "1.1.1.1",
            destinationPort: 53,
            payload: Data(bytes)
        )
    }
}
