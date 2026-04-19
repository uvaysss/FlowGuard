import Foundation
import XCTest

final class UDPPacketCodecTests: XCTestCase {
    func testParseIPv4UDPPacket() throws {
        let payload = Data([0xDE, 0xAD, 0xBE, 0xEF])
        let packet = try XCTUnwrap(
            TestPacketBuilders.makeUDPPacket(
                ipVersion: .ipv4,
                sourceAddress: "192.168.1.10",
                destinationAddress: "8.8.8.8",
                sourcePort: 50000,
                destinationPort: 53,
                payload: payload
            )
        )

        let parsed = try XCTUnwrap(UDPPacketCodec.parse(packet: packet))
        XCTAssertEqual(parsed.flowKey.ipVersion, .ipv4)
        XCTAssertEqual(parsed.flowKey.sourceAddress, "192.168.1.10")
        XCTAssertEqual(parsed.flowKey.destinationAddress, "8.8.8.8")
        XCTAssertEqual(parsed.flowKey.sourcePort, 50000)
        XCTAssertEqual(parsed.flowKey.destinationPort, 53)
        XCTAssertEqual(parsed.payload, payload)
    }

    func testParseIPv6UDPPacket() throws {
        let payload = Data("dns-query".utf8)
        let packet = try XCTUnwrap(
            TestPacketBuilders.makeUDPPacket(
                ipVersion: .ipv6,
                sourceAddress: "2001:db8::123",
                destinationAddress: "2001:4860:4860::8888",
                sourcePort: 53000,
                destinationPort: 53,
                payload: payload
            )
        )

        let parsed = try XCTUnwrap(UDPPacketCodec.parse(packet: packet))
        XCTAssertEqual(parsed.flowKey.ipVersion, .ipv6)
        XCTAssertEqual(parsed.flowKey.sourceAddress, "2001:db8::123")
        XCTAssertEqual(parsed.flowKey.destinationAddress, "2001:4860:4860::8888")
        XCTAssertEqual(parsed.flowKey.sourcePort, 53000)
        XCTAssertEqual(parsed.flowKey.destinationPort, 53)
        XCTAssertEqual(parsed.payload, payload)
    }

    func testParseReturnsNilWhenIPProtocolIsNotUDP() throws {
        let tcpPacket = try XCTUnwrap(
            TestPacketBuilders.makeTCPPacket(
                ipVersion: .ipv4,
                sourceAddress: "10.0.0.1",
                destinationAddress: "10.0.0.2",
                sourcePort: 80,
                destinationPort: 60000,
                sequenceNumber: 10,
                acknowledgementNumber: 0,
                flags: [.syn]
            )
        )

        XCTAssertNil(UDPPacketCodec.parse(packet: tcpPacket))
    }

    func testParseReturnsNilForTruncatedUDPHeader() throws {
        let packet = try XCTUnwrap(
            TestPacketBuilders.makeUDPPacket(
                ipVersion: .ipv4,
                sourceAddress: "10.0.0.1",
                destinationAddress: "10.0.0.2",
                sourcePort: 1000,
                destinationPort: 2000,
                payload: Data([0x01])
            )
        )
        let truncated = Data(packet.prefix(27))

        XCTAssertNil(UDPPacketCodec.parse(packet: truncated))
    }

    func testParseReturnsNilWhenUDPLengthIsLessThanHeader() throws {
        let packet = try XCTUnwrap(
            TestPacketBuilders.makeUDPPacket(
                ipVersion: .ipv4,
                sourceAddress: "10.0.0.1",
                destinationAddress: "10.0.0.2",
                sourcePort: 1000,
                destinationPort: 2000,
                payload: Data([0x01, 0x02]),
                overrideUDPLength: 7
            )
        )

        XCTAssertNil(UDPPacketCodec.parse(packet: packet))
    }

    func testParseReturnsNilWhenUDPLengthExceedsPacket() throws {
        let packet = try XCTUnwrap(
            TestPacketBuilders.makeUDPPacket(
                ipVersion: .ipv6,
                sourceAddress: "2001:db8::1",
                destinationAddress: "2001:db8::2",
                sourcePort: 1000,
                destinationPort: 2000,
                payload: Data([0x01, 0x02]),
                overrideUDPLength: 32
            )
        )

        XCTAssertNil(UDPPacketCodec.parse(packet: packet))
    }
}
