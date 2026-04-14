import Darwin
import Foundation

enum IPVersion: Int, Sendable {
    case ipv4 = 4
    case ipv6 = 6
}

enum IPTransportProtocol: UInt8, Sendable {
    case icmp = 1
    case tcp = 6
    case udp = 17
    case icmpv6 = 58
    case unknown = 255

    static func from(rawValue: UInt8) -> IPTransportProtocol {
        IPTransportProtocol(rawValue: rawValue) ?? .unknown
    }
}

struct IPPacketMetadata: Sendable {
    let version: IPVersion
    let headerLength: Int
    let totalLength: Int
    let payloadLength: Int
    let transportProtocol: IPTransportProtocol
    let sourceAddress: String
    let destinationAddress: String
}

enum IPPacketCodec {
    static func parse(packet: Data) -> IPPacketMetadata? {
        guard let firstByte = packet.first else { return nil }
        let version = Int((firstByte & 0xF0) >> 4)
        switch version {
        case IPVersion.ipv4.rawValue:
            return parseIPv4(packet: packet)
        case IPVersion.ipv6.rawValue:
            return parseIPv6(packet: packet)
        default:
            return nil
        }
    }

    static func serializeSkeleton(metadata: IPPacketMetadata, payload: Data = Data()) -> Data? {
        switch metadata.version {
        case .ipv4:
            return serializeIPv4Skeleton(metadata: metadata, payload: payload)
        case .ipv6:
            return serializeIPv6Skeleton(metadata: metadata, payload: payload)
        }
    }

    private static func parseIPv4(packet: Data) -> IPPacketMetadata? {
        guard packet.count >= 20 else { return nil }
        let ihlWords = Int(packet[0] & 0x0F)
        let headerLength = ihlWords * 4
        guard headerLength >= 20, headerLength <= packet.count else { return nil }

        let totalLength = Int(packet[2]) << 8 | Int(packet[3])
        guard totalLength >= headerLength, totalLength <= packet.count else { return nil }

        let protocolRaw = packet[9]
        let sourceAddress = ipv4AddressString(from: packet[12..<16]) ?? "0.0.0.0"
        let destinationAddress = ipv4AddressString(from: packet[16..<20]) ?? "0.0.0.0"
        let payloadLength = totalLength - headerLength

        return IPPacketMetadata(
            version: .ipv4,
            headerLength: headerLength,
            totalLength: totalLength,
            payloadLength: payloadLength,
            transportProtocol: IPTransportProtocol.from(rawValue: protocolRaw),
            sourceAddress: sourceAddress,
            destinationAddress: destinationAddress
        )
    }

    private static func parseIPv6(packet: Data) -> IPPacketMetadata? {
        guard packet.count >= 40 else { return nil }
        let payloadLength = Int(packet[4]) << 8 | Int(packet[5])
        let totalLength = 40 + payloadLength
        guard totalLength <= packet.count else { return nil }

        let nextHeader = packet[6]
        let sourceAddress = ipv6AddressString(from: packet[8..<24]) ?? "::"
        let destinationAddress = ipv6AddressString(from: packet[24..<40]) ?? "::"

        return IPPacketMetadata(
            version: .ipv6,
            headerLength: 40,
            totalLength: totalLength,
            payloadLength: payloadLength,
            transportProtocol: IPTransportProtocol.from(rawValue: nextHeader),
            sourceAddress: sourceAddress,
            destinationAddress: destinationAddress
        )
    }

    private static func serializeIPv4Skeleton(metadata: IPPacketMetadata, payload: Data) -> Data? {
        guard payload.count <= 0xFFFF - 20 else { return nil }
        guard let source = ipv4AddressData(from: metadata.sourceAddress),
              let destination = ipv4AddressData(from: metadata.destinationAddress) else {
            return nil
        }

        let totalLength = 20 + payload.count
        var bytes = Data(count: totalLength)
        bytes[0] = 0x45
        bytes[1] = 0
        bytes[2] = UInt8((totalLength >> 8) & 0xFF)
        bytes[3] = UInt8(totalLength & 0xFF)
        bytes[4] = 0
        bytes[5] = 0
        bytes[6] = 0
        bytes[7] = 0
        bytes[8] = 64
        bytes[9] = metadata.transportProtocol == .unknown ? 0 : metadata.transportProtocol.rawValue
        bytes[10] = 0
        bytes[11] = 0
        bytes.replaceSubrange(12..<16, with: source)
        bytes.replaceSubrange(16..<20, with: destination)
        bytes.replaceSubrange(20..<totalLength, with: payload)
        return bytes
    }

    private static func serializeIPv6Skeleton(metadata: IPPacketMetadata, payload: Data) -> Data? {
        guard payload.count <= 0xFFFF else { return nil }
        guard let source = ipv6AddressData(from: metadata.sourceAddress),
              let destination = ipv6AddressData(from: metadata.destinationAddress) else {
            return nil
        }

        let totalLength = 40 + payload.count
        var bytes = Data(count: totalLength)
        bytes[0] = 0x60
        bytes[1] = 0
        bytes[2] = 0
        bytes[3] = 0
        bytes[4] = UInt8((payload.count >> 8) & 0xFF)
        bytes[5] = UInt8(payload.count & 0xFF)
        bytes[6] = metadata.transportProtocol == .unknown ? 0 : metadata.transportProtocol.rawValue
        bytes[7] = 64
        bytes.replaceSubrange(8..<24, with: source)
        bytes.replaceSubrange(24..<40, with: destination)
        bytes.replaceSubrange(40..<totalLength, with: payload)
        return bytes
    }

    private static func ipv4AddressString(from slice: Data.SubSequence) -> String? {
        guard slice.count == 4 else { return nil }
        var addr = in_addr()
        withUnsafeMutableBytes(of: &addr) { buffer in
            _ = slice.copyBytes(to: buffer)
        }
        var stringBuffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        guard inet_ntop(AF_INET, &addr, &stringBuffer, socklen_t(INET_ADDRSTRLEN)) != nil else {
            return nil
        }
        return String(cString: stringBuffer)
    }

    private static func ipv6AddressString(from slice: Data.SubSequence) -> String? {
        guard slice.count == 16 else { return nil }
        var addr = in6_addr()
        withUnsafeMutableBytes(of: &addr) { buffer in
            _ = slice.copyBytes(to: buffer)
        }
        var stringBuffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        guard inet_ntop(AF_INET6, &addr, &stringBuffer, socklen_t(INET6_ADDRSTRLEN)) != nil else {
            return nil
        }
        return String(cString: stringBuffer)
    }

    private static func ipv4AddressData(from string: String) -> Data? {
        var addr = in_addr()
        let result = string.withCString { cString in
            inet_pton(AF_INET, cString, &addr)
        }
        guard result == 1 else { return nil }
        return withUnsafeBytes(of: addr) { Data($0) }
    }

    private static func ipv6AddressData(from string: String) -> Data? {
        var addr = in6_addr()
        let result = string.withCString { cString in
            inet_pton(AF_INET6, cString, &addr)
        }
        guard result == 1 else { return nil }
        return withUnsafeBytes(of: addr) { Data($0) }
    }
}
