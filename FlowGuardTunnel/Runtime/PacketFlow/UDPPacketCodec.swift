import Foundation

struct UDPFlowKey: Hashable, Sendable {
    let ipVersion: IPVersion
    let sourceAddress: String
    let destinationAddress: String
    let sourcePort: UInt16
    let destinationPort: UInt16
}

struct UDPPacket: Sendable {
    let flowKey: UDPFlowKey
    let payload: Data
}

enum UDPPacketCodec {
    static func parse(packet: Data) -> UDPPacket? {
        guard let ipMetadata = IPPacketCodec.parse(packet: packet),
              ipMetadata.transportProtocol == .udp else {
            return nil
        }

        let ipPayloadOffset: Int
        switch ipMetadata.version {
        case .ipv4:
            ipPayloadOffset = ipMetadata.headerLength
        case .ipv6:
            ipPayloadOffset = 40
        }

        guard ipPayloadOffset + 8 <= packet.count else { return nil }

        let sourcePort = readUInt16(packet, offset: ipPayloadOffset)
        let destinationPort = readUInt16(packet, offset: ipPayloadOffset + 2)
        let udpLength = Int(readUInt16(packet, offset: ipPayloadOffset + 4))
        guard udpLength >= 8 else { return nil }
        guard ipPayloadOffset + udpLength <= packet.count else { return nil }

        let payloadStart = ipPayloadOffset + 8
        let payloadEnd = ipPayloadOffset + udpLength
        guard payloadStart <= payloadEnd, payloadEnd <= packet.count else { return nil }

        return UDPPacket(
            flowKey: UDPFlowKey(
                ipVersion: ipMetadata.version,
                sourceAddress: ipMetadata.sourceAddress,
                destinationAddress: ipMetadata.destinationAddress,
                sourcePort: sourcePort,
                destinationPort: destinationPort
            ),
            payload: Data(packet[payloadStart..<payloadEnd])
        )
    }

    private static func readUInt16(_ data: Data, offset: Int) -> UInt16 {
        guard offset + 1 < data.count else { return 0 }
        return (UInt16(data[offset]) << 8) | UInt16(data[offset + 1])
    }
}
