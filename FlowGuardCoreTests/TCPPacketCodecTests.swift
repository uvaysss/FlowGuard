import Foundation
import XCTest

final class TCPPacketCodecTests: XCTestCase {
    func testParseIPv4TCPPacket() throws {
        let payload = Data("hello".utf8)
        let packet = try XCTUnwrap(
            TestPacketBuilders.makeTCPPacket(
                ipVersion: .ipv4,
                sourceAddress: "10.1.1.1",
                destinationAddress: "10.1.1.2",
                sourcePort: 443,
                destinationPort: 49152,
                sequenceNumber: 100,
                acknowledgementNumber: 50,
                flags: [.syn, .ack],
                payload: payload
            )
        )

        let parsed = try XCTUnwrap(TCPPacketCodec.parse(packet: packet))
        XCTAssertEqual(parsed.flowKey.ipVersion, .ipv4)
        XCTAssertEqual(parsed.flowKey.sourceAddress, "10.1.1.1")
        XCTAssertEqual(parsed.flowKey.destinationAddress, "10.1.1.2")
        XCTAssertEqual(parsed.flowKey.sourcePort, 443)
        XCTAssertEqual(parsed.flowKey.destinationPort, 49152)
        XCTAssertEqual(parsed.sequenceNumber, 100)
        XCTAssertEqual(parsed.acknowledgementNumber, 50)
        XCTAssertTrue(parsed.flags.contains(.syn))
        XCTAssertTrue(parsed.flags.contains(.ack))
        XCTAssertEqual(parsed.windowSize, 4096)
        XCTAssertEqual(parsed.payload, payload)
    }

    func testParseIPv6TCPPacket() throws {
        let payload = Data([1, 2, 3, 4])
        let packet = try XCTUnwrap(
            TestPacketBuilders.makeTCPPacket(
                ipVersion: .ipv6,
                sourceAddress: "2001:db8::10",
                destinationAddress: "2001:db8::20",
                sourcePort: 12345,
                destinationPort: 80,
                sequenceNumber: 0x01020304,
                acknowledgementNumber: 0xAABBCCDD,
                flags: [.psh, .ack],
                payload: payload
            )
        )

        let parsed = try XCTUnwrap(TCPPacketCodec.parse(packet: packet))
        XCTAssertEqual(parsed.flowKey.ipVersion, .ipv6)
        XCTAssertEqual(parsed.flowKey.sourceAddress, "2001:db8::10")
        XCTAssertEqual(parsed.flowKey.destinationAddress, "2001:db8::20")
        XCTAssertEqual(parsed.flowKey.sourcePort, 12345)
        XCTAssertEqual(parsed.flowKey.destinationPort, 80)
        XCTAssertEqual(parsed.sequenceNumber, 0x01020304)
        XCTAssertEqual(parsed.acknowledgementNumber, 0xAABBCCDD)
        XCTAssertTrue(parsed.flags.contains(.psh))
        XCTAssertTrue(parsed.flags.contains(.ack))
        XCTAssertEqual(parsed.payload, payload)
    }

    func testParseReturnsNilWhenIPProtocolIsNotTCP() throws {
        let udpPacket = try XCTUnwrap(
            TestPacketBuilders.makeUDPPacket(
                ipVersion: .ipv4,
                sourceAddress: "10.0.0.1",
                destinationAddress: "10.0.0.2",
                sourcePort: 53,
                destinationPort: 50000,
                payload: Data([0xAB])
            )
        )

        XCTAssertNil(TCPPacketCodec.parse(packet: udpPacket))
    }

    func testParseReturnsNilForTruncatedTCPHeader() throws {
        let packet = try XCTUnwrap(
            TestPacketBuilders.makeTCPPacket(
                ipVersion: .ipv4,
                sourceAddress: "10.0.0.1",
                destinationAddress: "10.0.0.2",
                sourcePort: 1000,
                destinationPort: 2000,
                sequenceNumber: 1,
                acknowledgementNumber: 0,
                flags: [.syn]
            )
        )
        let truncated = packet.prefix(39)

        XCTAssertNil(TCPPacketCodec.parse(packet: Data(truncated)))
    }

    func testParseReturnsNilForInvalidDataOffsetBelowMinimum() throws {
        let packet = try XCTUnwrap(
            TestPacketBuilders.makeTCPPacket(
                ipVersion: .ipv4,
                sourceAddress: "10.0.0.1",
                destinationAddress: "10.0.0.2",
                sourcePort: 1000,
                destinationPort: 2000,
                sequenceNumber: 1,
                acknowledgementNumber: 0,
                flags: [.syn],
                dataOffsetWords: 5
            )
        )
        var mutated = packet
        mutated[32] = 0x40

        XCTAssertNil(TCPPacketCodec.parse(packet: mutated))
    }

    func testParseReturnsNilForDataOffsetBeyondPacketBounds() throws {
        let packet = try XCTUnwrap(
            TestPacketBuilders.makeTCPPacket(
                ipVersion: .ipv4,
                sourceAddress: "10.0.0.1",
                destinationAddress: "10.0.0.2",
                sourcePort: 1000,
                destinationPort: 2000,
                sequenceNumber: 1,
                acknowledgementNumber: 0,
                flags: [.ack],
                payload: Data([0x01, 0x02])
            )
        )
        var mutated = packet
        mutated[32] = 0xF0

        XCTAssertNil(TCPPacketCodec.parse(packet: mutated))
    }
}
