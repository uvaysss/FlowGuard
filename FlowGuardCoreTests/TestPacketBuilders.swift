import Foundation

enum TestPacketBuilders {
    static func makeTCPPacket(
        ipVersion: IPVersion,
        sourceAddress: String,
        destinationAddress: String,
        sourcePort: UInt16,
        destinationPort: UInt16,
        sequenceNumber: UInt32,
        acknowledgementNumber: UInt32,
        flags: TCPFlags,
        windowSize: UInt16 = 4096,
        payload: Data = Data(),
        dataOffsetWords: UInt8 = 5,
        overrideIPTransportProtocol: IPTransportProtocol? = nil
    ) -> Data? {
        let tcpHeaderLength = Int(dataOffsetWords) * 4
        guard tcpHeaderLength >= 20, tcpHeaderLength <= 60 else { return nil }

        var tcpSegment = Data(count: tcpHeaderLength + payload.count)
        writeUInt16(sourcePort, into: &tcpSegment, offset: 0)
        writeUInt16(destinationPort, into: &tcpSegment, offset: 2)
        writeUInt32(sequenceNumber, into: &tcpSegment, offset: 4)
        writeUInt32(acknowledgementNumber, into: &tcpSegment, offset: 8)
        tcpSegment[12] = dataOffsetWords << 4
        tcpSegment[13] = tcpFlagsByte(flags)
        writeUInt16(windowSize, into: &tcpSegment, offset: 14)
        writeUInt16(0, into: &tcpSegment, offset: 16)
        writeUInt16(0, into: &tcpSegment, offset: 18)
        if !payload.isEmpty {
            tcpSegment.replaceSubrange(tcpHeaderLength..<(tcpHeaderLength + payload.count), with: payload)
        }

        let metadata = IPPacketMetadata(
            version: ipVersion,
            headerLength: ipVersion == .ipv4 ? 20 : 40,
            totalLength: (ipVersion == .ipv4 ? 20 : 40) + tcpSegment.count,
            payloadLength: tcpSegment.count,
            transportProtocol: overrideIPTransportProtocol ?? .tcp,
            sourceAddress: sourceAddress,
            destinationAddress: destinationAddress
        )
        return IPPacketCodec.serializeSkeleton(metadata: metadata, payload: tcpSegment)
    }

    static func makeUDPPacket(
        ipVersion: IPVersion,
        sourceAddress: String,
        destinationAddress: String,
        sourcePort: UInt16,
        destinationPort: UInt16,
        payload: Data,
        overrideUDPLength: UInt16? = nil,
        overrideIPTransportProtocol: IPTransportProtocol? = nil
    ) -> Data? {
        let udpLength = overrideUDPLength ?? UInt16(8 + payload.count)
        var udpDatagram = Data(count: 8)
        writeUInt16(sourcePort, into: &udpDatagram, offset: 0)
        writeUInt16(destinationPort, into: &udpDatagram, offset: 2)
        writeUInt16(udpLength, into: &udpDatagram, offset: 4)
        writeUInt16(0, into: &udpDatagram, offset: 6)
        udpDatagram.append(payload)

        let metadata = IPPacketMetadata(
            version: ipVersion,
            headerLength: ipVersion == .ipv4 ? 20 : 40,
            totalLength: (ipVersion == .ipv4 ? 20 : 40) + udpDatagram.count,
            payloadLength: udpDatagram.count,
            transportProtocol: overrideIPTransportProtocol ?? .udp,
            sourceAddress: sourceAddress,
            destinationAddress: destinationAddress
        )
        return IPPacketCodec.serializeSkeleton(metadata: metadata, payload: udpDatagram)
    }

    private static func tcpFlagsByte(_ flags: TCPFlags) -> UInt8 {
        var byte: UInt8 = 0
        if flags.contains(.fin) { byte |= 0x01 }
        if flags.contains(.syn) { byte |= 0x02 }
        if flags.contains(.rst) { byte |= 0x04 }
        if flags.contains(.psh) { byte |= 0x08 }
        if flags.contains(.ack) { byte |= 0x10 }
        return byte
    }

    private static func writeUInt16(_ value: UInt16, into data: inout Data, offset: Int) {
        guard offset + 1 < data.count else { return }
        data[offset] = UInt8((value >> 8) & 0xFF)
        data[offset + 1] = UInt8(value & 0xFF)
    }

    private static func writeUInt32(_ value: UInt32, into data: inout Data, offset: Int) {
        guard offset + 3 < data.count else { return }
        data[offset] = UInt8((value >> 24) & 0xFF)
        data[offset + 1] = UInt8((value >> 16) & 0xFF)
        data[offset + 2] = UInt8((value >> 8) & 0xFF)
        data[offset + 3] = UInt8(value & 0xFF)
    }
}
