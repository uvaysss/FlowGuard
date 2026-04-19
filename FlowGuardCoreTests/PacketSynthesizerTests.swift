import Foundation
import XCTest

final class PacketSynthesizerTests: XCTestCase {
    func testSynthesizeTCPv4RoundTripParse() throws {
        let flowKey = TCPFlowKey(
            ipVersion: .ipv4,
            sourceAddress: "10.10.0.5",
            destinationAddress: "93.184.216.34",
            sourcePort: 55000,
            destinationPort: 443
        )
        let payload = Data("response".utf8)

        let synthesized = try XCTUnwrap(
            PacketSynthesizer.synthesizeTCP(
                flowKey: flowKey,
                sequenceNumber: 1234,
                acknowledgementNumber: 4321,
                flags: [.ack, .psh],
                windowSize: 2048,
                payload: payload
            )
        )

        XCTAssertEqual(synthesized.ipVersion, .ipv4)

        let parsed = try XCTUnwrap(TCPPacketCodec.parse(packet: synthesized.data))
        XCTAssertEqual(parsed.flowKey.ipVersion, .ipv4)
        XCTAssertEqual(parsed.flowKey.sourceAddress, flowKey.destinationAddress)
        XCTAssertEqual(parsed.flowKey.destinationAddress, flowKey.sourceAddress)
        XCTAssertEqual(parsed.flowKey.sourcePort, flowKey.destinationPort)
        XCTAssertEqual(parsed.flowKey.destinationPort, flowKey.sourcePort)
        XCTAssertEqual(parsed.sequenceNumber, 1234)
        XCTAssertEqual(parsed.acknowledgementNumber, 4321)
        XCTAssertTrue(parsed.flags.contains(.ack))
        XCTAssertTrue(parsed.flags.contains(.psh))
        XCTAssertEqual(parsed.windowSize, 2048)
        XCTAssertEqual(parsed.payload, payload)
    }

    func testSynthesizeTCPv6RoundTripParse() throws {
        let flowKey = TCPFlowKey(
            ipVersion: .ipv6,
            sourceAddress: "2001:db8::100",
            destinationAddress: "2001:db8::200",
            sourcePort: 52000,
            destinationPort: 8443
        )

        let synthesized = try XCTUnwrap(
            PacketSynthesizer.synthesizeTCP(
                flowKey: flowKey,
                sequenceNumber: 77,
                acknowledgementNumber: 55,
                flags: [.syn, .ack]
            )
        )

        XCTAssertEqual(synthesized.ipVersion, .ipv6)

        let parsed = try XCTUnwrap(TCPPacketCodec.parse(packet: synthesized.data))
        XCTAssertEqual(parsed.flowKey.ipVersion, .ipv6)
        XCTAssertEqual(parsed.flowKey.sourceAddress, flowKey.destinationAddress)
        XCTAssertEqual(parsed.flowKey.destinationAddress, flowKey.sourceAddress)
        XCTAssertEqual(parsed.flowKey.sourcePort, flowKey.destinationPort)
        XCTAssertEqual(parsed.flowKey.destinationPort, flowKey.sourcePort)
        XCTAssertEqual(parsed.sequenceNumber, 77)
        XCTAssertEqual(parsed.acknowledgementNumber, 55)
        XCTAssertTrue(parsed.flags.contains(.syn))
        XCTAssertTrue(parsed.flags.contains(.ack))
    }

    func testSynthesizeUDPv4RoundTripParse() throws {
        let flowKey = UDPFlowKey(
            ipVersion: .ipv4,
            sourceAddress: "10.0.0.9",
            destinationAddress: "1.1.1.1",
            sourcePort: 53000,
            destinationPort: 53
        )
        let payload = Data([0x01, 0x00, 0x00, 0x01])

        let synthesized = try XCTUnwrap(PacketSynthesizer.synthesizeUDP(flowKey: flowKey, payload: payload))
        XCTAssertEqual(synthesized.ipVersion, .ipv4)

        let parsed = try XCTUnwrap(UDPPacketCodec.parse(packet: synthesized.data))
        XCTAssertEqual(parsed.flowKey.ipVersion, .ipv4)
        XCTAssertEqual(parsed.flowKey.sourceAddress, flowKey.destinationAddress)
        XCTAssertEqual(parsed.flowKey.destinationAddress, flowKey.sourceAddress)
        XCTAssertEqual(parsed.flowKey.sourcePort, flowKey.destinationPort)
        XCTAssertEqual(parsed.flowKey.destinationPort, flowKey.sourcePort)
        XCTAssertEqual(parsed.payload, payload)
    }

    func testSynthesizeUDPv6RoundTripParse() throws {
        let flowKey = UDPFlowKey(
            ipVersion: .ipv6,
            sourceAddress: "2001:db8::1",
            destinationAddress: "2001:db8::53",
            sourcePort: 53000,
            destinationPort: 53
        )
        let payload = Data("answer".utf8)

        let synthesized = try XCTUnwrap(PacketSynthesizer.synthesizeUDP(flowKey: flowKey, payload: payload))
        XCTAssertEqual(synthesized.ipVersion, .ipv6)

        let parsed = try XCTUnwrap(UDPPacketCodec.parse(packet: synthesized.data))
        XCTAssertEqual(parsed.flowKey.ipVersion, .ipv6)
        XCTAssertEqual(parsed.flowKey.sourceAddress, flowKey.destinationAddress)
        XCTAssertEqual(parsed.flowKey.destinationAddress, flowKey.sourceAddress)
        XCTAssertEqual(parsed.flowKey.sourcePort, flowKey.destinationPort)
        XCTAssertEqual(parsed.flowKey.destinationPort, flowKey.sourcePort)
        XCTAssertEqual(parsed.payload, payload)
    }

    func testSynthesizeTCPReturnsNilForInvalidAddress() {
        let flowKey = TCPFlowKey(
            ipVersion: .ipv4,
            sourceAddress: "10.0.0.1",
            destinationAddress: "not-an-ip",
            sourcePort: 50000,
            destinationPort: 443
        )

        XCTAssertNil(
            PacketSynthesizer.synthesizeTCP(
                flowKey: flowKey,
                sequenceNumber: 1,
                acknowledgementNumber: 1,
                flags: [.ack]
            )
        )
    }

    func testSynthesizeUDPReturnsNilForInvalidAddress() {
        let flowKey = UDPFlowKey(
            ipVersion: .ipv6,
            sourceAddress: "2001:db8::1",
            destinationAddress: "invalid",
            sourcePort: 1234,
            destinationPort: 53
        )

        XCTAssertNil(PacketSynthesizer.synthesizeUDP(flowKey: flowKey, payload: Data([1, 2, 3])))
    }
}
