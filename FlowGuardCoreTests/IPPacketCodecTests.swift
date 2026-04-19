import Foundation
import XCTest

final class IPPacketCodecTests: XCTestCase {
    func testParseIPv4PacketMetadata() throws {
        let payload = Data([0xAA, 0xBB, 0xCC, 0xDD])
        let metadata = IPPacketMetadata(
            version: .ipv4,
            headerLength: 20,
            totalLength: 24,
            payloadLength: 4,
            transportProtocol: .tcp,
            sourceAddress: "10.0.0.1",
            destinationAddress: "8.8.8.8"
        )

        let packet = try XCTUnwrap(IPPacketCodec.serializeSkeleton(metadata: metadata, payload: payload))
        let parsed = try XCTUnwrap(IPPacketCodec.parse(packet: packet))

        XCTAssertEqual(parsed.version, .ipv4)
        XCTAssertEqual(parsed.headerLength, 20)
        XCTAssertEqual(parsed.totalLength, 24)
        XCTAssertEqual(parsed.payloadLength, 4)
        XCTAssertEqual(parsed.transportProtocol, .tcp)
        XCTAssertEqual(parsed.sourceAddress, "10.0.0.1")
        XCTAssertEqual(parsed.destinationAddress, "8.8.8.8")
    }

    func testParseIPv6PacketMetadata() throws {
        let payload = Data([0x01, 0x02, 0x03])
        let metadata = IPPacketMetadata(
            version: .ipv6,
            headerLength: 40,
            totalLength: 43,
            payloadLength: 3,
            transportProtocol: .udp,
            sourceAddress: "2001:db8::1",
            destinationAddress: "2001:db8::2"
        )

        let packet = try XCTUnwrap(IPPacketCodec.serializeSkeleton(metadata: metadata, payload: payload))
        let parsed = try XCTUnwrap(IPPacketCodec.parse(packet: packet))

        XCTAssertEqual(parsed.version, .ipv6)
        XCTAssertEqual(parsed.headerLength, 40)
        XCTAssertEqual(parsed.totalLength, 43)
        XCTAssertEqual(parsed.payloadLength, 3)
        XCTAssertEqual(parsed.transportProtocol, .udp)
        XCTAssertEqual(parsed.sourceAddress, "2001:db8::1")
        XCTAssertEqual(parsed.destinationAddress, "2001:db8::2")
    }

    func testParseReturnsNilForUnknownVersion() {
        let packet = Data([0x30, 0, 0, 0, 0, 0, 0, 0])
        XCTAssertNil(IPPacketCodec.parse(packet: packet))
    }

    func testParseIPv4ReturnsNilForTooShortPacket() {
        let packet = Data(repeating: 0, count: 19)
        XCTAssertNil(IPPacketCodec.parse(packet: packet))
    }

    func testParseIPv4ReturnsNilForInvalidHeaderLength() throws {
        let metadata = IPPacketMetadata(
            version: .ipv4,
            headerLength: 20,
            totalLength: 20,
            payloadLength: 0,
            transportProtocol: .tcp,
            sourceAddress: "1.1.1.1",
            destinationAddress: "2.2.2.2"
        )
        var packet = try XCTUnwrap(IPPacketCodec.serializeSkeleton(metadata: metadata))
        packet[0] = 0x44

        XCTAssertNil(IPPacketCodec.parse(packet: packet))
    }

    func testParseIPv4ReturnsNilForTotalLengthBeyondPacket() throws {
        let metadata = IPPacketMetadata(
            version: .ipv4,
            headerLength: 20,
            totalLength: 20,
            payloadLength: 0,
            transportProtocol: .udp,
            sourceAddress: "1.1.1.1",
            destinationAddress: "2.2.2.2"
        )
        var packet = try XCTUnwrap(IPPacketCodec.serializeSkeleton(metadata: metadata))
        packet[2] = 0
        packet[3] = 64

        XCTAssertNil(IPPacketCodec.parse(packet: packet))
    }

    func testParseIPv6ReturnsNilWhenPayloadLengthExceedsPacket() throws {
        let metadata = IPPacketMetadata(
            version: .ipv6,
            headerLength: 40,
            totalLength: 40,
            payloadLength: 0,
            transportProtocol: .udp,
            sourceAddress: "2001:db8::1",
            destinationAddress: "2001:db8::2"
        )
        var packet = try XCTUnwrap(IPPacketCodec.serializeSkeleton(metadata: metadata))
        packet[4] = 0
        packet[5] = 10

        XCTAssertNil(IPPacketCodec.parse(packet: packet))
    }

    func testSerializeSkeletonReturnsNilForInvalidIPv4Address() {
        let metadata = IPPacketMetadata(
            version: .ipv4,
            headerLength: 20,
            totalLength: 20,
            payloadLength: 0,
            transportProtocol: .tcp,
            sourceAddress: "999.1.1.1",
            destinationAddress: "8.8.8.8"
        )

        XCTAssertNil(IPPacketCodec.serializeSkeleton(metadata: metadata))
    }

    func testSerializeSkeletonUnknownTransportEncodesAsUnknownOnParse() throws {
        let metadata = IPPacketMetadata(
            version: .ipv4,
            headerLength: 20,
            totalLength: 20,
            payloadLength: 0,
            transportProtocol: .unknown,
            sourceAddress: "10.0.0.2",
            destinationAddress: "10.0.0.3"
        )

        let packet = try XCTUnwrap(IPPacketCodec.serializeSkeleton(metadata: metadata))
        let parsed = try XCTUnwrap(IPPacketCodec.parse(packet: packet))
        XCTAssertEqual(parsed.transportProtocol, .unknown)
    }
}
