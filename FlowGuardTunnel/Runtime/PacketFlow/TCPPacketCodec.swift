import Foundation

struct TCPFlags: OptionSet, Sendable {
    let rawValue: UInt16

    static let fin = TCPFlags(rawValue: 1 << 0)
    static let syn = TCPFlags(rawValue: 1 << 1)
    static let rst = TCPFlags(rawValue: 1 << 2)
    static let psh = TCPFlags(rawValue: 1 << 3)
    static let ack = TCPFlags(rawValue: 1 << 4)
}

struct TCPFlowKey: Hashable, Sendable {
    let ipVersion: IPVersion
    let sourceAddress: String
    let destinationAddress: String
    let sourcePort: UInt16
    let destinationPort: UInt16
}

struct TCPPacket: Sendable {
    let flowKey: TCPFlowKey
    let sequenceNumber: UInt32
    let acknowledgementNumber: UInt32
    let flags: TCPFlags
    let windowSize: UInt16
    let payload: Data
}

enum TCPPacketCodec {
    static func parse(packet: Data) -> TCPPacket? {
        guard let ipMetadata = IPPacketCodec.parse(packet: packet),
              ipMetadata.transportProtocol == .tcp else {
            return nil
        }

        let ipPayloadOffset: Int
        switch ipMetadata.version {
        case .ipv4:
            ipPayloadOffset = ipMetadata.headerLength
        case .ipv6:
            ipPayloadOffset = 40
        }

        guard ipPayloadOffset + 20 <= packet.count else { return nil }

        let sourcePort = readUInt16(packet, offset: ipPayloadOffset)
        let destinationPort = readUInt16(packet, offset: ipPayloadOffset + 2)
        let sequenceNumber = readUInt32(packet, offset: ipPayloadOffset + 4)
        let acknowledgementNumber = readUInt32(packet, offset: ipPayloadOffset + 8)

        let dataOffsetAndReserved = packet[ipPayloadOffset + 12]
        let tcpHeaderLength = Int((dataOffsetAndReserved >> 4) & 0x0F) * 4
        guard tcpHeaderLength >= 20 else { return nil }
        guard ipPayloadOffset + tcpHeaderLength <= packet.count else { return nil }

        let flagsByte = packet[ipPayloadOffset + 13]
        var flags = TCPFlags()
        if (flagsByte & 0x01) != 0 { flags.insert(.fin) }
        if (flagsByte & 0x02) != 0 { flags.insert(.syn) }
        if (flagsByte & 0x04) != 0 { flags.insert(.rst) }
        if (flagsByte & 0x08) != 0 { flags.insert(.psh) }
        if (flagsByte & 0x10) != 0 { flags.insert(.ack) }

        let windowSize = readUInt16(packet, offset: ipPayloadOffset + 14)
        let payloadStart = ipPayloadOffset + tcpHeaderLength
        let payload = payloadStart <= packet.count ? packet[payloadStart..<packet.count] : Data()

        return TCPPacket(
            flowKey: TCPFlowKey(
                ipVersion: ipMetadata.version,
                sourceAddress: ipMetadata.sourceAddress,
                destinationAddress: ipMetadata.destinationAddress,
                sourcePort: sourcePort,
                destinationPort: destinationPort
            ),
            sequenceNumber: sequenceNumber,
            acknowledgementNumber: acknowledgementNumber,
            flags: flags,
            windowSize: windowSize,
            payload: Data(payload)
        )
    }

    private static func readUInt16(_ data: Data, offset: Int) -> UInt16 {
        guard offset + 1 < data.count else { return 0 }
        return (UInt16(data[offset]) << 8) | UInt16(data[offset + 1])
    }

    private static func readUInt32(_ data: Data, offset: Int) -> UInt32 {
        guard offset + 3 < data.count else { return 0 }
        return (UInt32(data[offset]) << 24)
            | (UInt32(data[offset + 1]) << 16)
            | (UInt32(data[offset + 2]) << 8)
            | UInt32(data[offset + 3])
    }
}
