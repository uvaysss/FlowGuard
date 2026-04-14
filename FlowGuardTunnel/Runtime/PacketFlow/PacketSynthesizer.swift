import Darwin
import Foundation

enum PacketSynthesizer {
    static func synthesizeTCP(
        flowKey: TCPFlowKey,
        sequenceNumber: UInt32,
        acknowledgementNumber: UInt32,
        flags: TCPFlags,
        windowSize: UInt16 = 65535,
        payload: Data = Data()
    ) -> SynthesizedPacket? {
        switch flowKey.ipVersion {
        case .ipv4:
            return synthesizeTCPv4(
                sourceAddress: flowKey.destinationAddress,
                sourcePort: flowKey.destinationPort,
                destinationAddress: flowKey.sourceAddress,
                destinationPort: flowKey.sourcePort,
                sequenceNumber: sequenceNumber,
                acknowledgementNumber: acknowledgementNumber,
                flags: flags,
                windowSize: windowSize,
                payload: payload
            )
        case .ipv6:
            return synthesizeTCPv6(
                sourceAddress: flowKey.destinationAddress,
                sourcePort: flowKey.destinationPort,
                destinationAddress: flowKey.sourceAddress,
                destinationPort: flowKey.sourcePort,
                sequenceNumber: sequenceNumber,
                acknowledgementNumber: acknowledgementNumber,
                flags: flags,
                windowSize: windowSize,
                payload: payload
            )
        }
    }

    static func synthesizeUDP(flowKey: UDPFlowKey, payload: Data) -> SynthesizedPacket? {
        switch flowKey.ipVersion {
        case .ipv4:
            return synthesizeUDPv4(
                sourceAddress: flowKey.destinationAddress,
                sourcePort: flowKey.destinationPort,
                destinationAddress: flowKey.sourceAddress,
                destinationPort: flowKey.sourcePort,
                payload: payload
            )
        case .ipv6:
            return synthesizeUDPv6(
                sourceAddress: flowKey.destinationAddress,
                sourcePort: flowKey.destinationPort,
                destinationAddress: flowKey.sourceAddress,
                destinationPort: flowKey.sourcePort,
                payload: payload
            )
        }
    }

    private static func synthesizeTCPv4(
        sourceAddress: String,
        sourcePort: UInt16,
        destinationAddress: String,
        destinationPort: UInt16,
        sequenceNumber: UInt32,
        acknowledgementNumber: UInt32,
        flags: TCPFlags,
        windowSize: UInt16,
        payload: Data
    ) -> SynthesizedPacket? {
        guard let src = ipv4AddressData(from: sourceAddress),
              let dst = ipv4AddressData(from: destinationAddress) else {
            return nil
        }
        let tcpHeaderLength = 20
        let tcpLength = tcpHeaderLength + payload.count
        let totalLength = 20 + tcpLength
        guard totalLength <= 0xFFFF else { return nil }

        var packet = Data(count: totalLength)
        packet[0] = 0x45
        packet[1] = 0
        writeUInt16(UInt16(totalLength), into: &packet, offset: 2)
        writeUInt16(0, into: &packet, offset: 4)
        writeUInt16(0x4000, into: &packet, offset: 6)
        packet[8] = 64
        packet[9] = 6
        writeUInt16(0, into: &packet, offset: 10)
        packet.replaceSubrange(12..<16, with: src)
        packet.replaceSubrange(16..<20, with: dst)

        let tcpOffset = 20
        writeUInt16(sourcePort, into: &packet, offset: tcpOffset)
        writeUInt16(destinationPort, into: &packet, offset: tcpOffset + 2)
        writeUInt32(sequenceNumber, into: &packet, offset: tcpOffset + 4)
        writeUInt32(acknowledgementNumber, into: &packet, offset: tcpOffset + 8)
        packet[tcpOffset + 12] = 0x50
        packet[tcpOffset + 13] = tcpFlagsByte(flags)
        writeUInt16(windowSize, into: &packet, offset: tcpOffset + 14)
        writeUInt16(0, into: &packet, offset: tcpOffset + 16)
        writeUInt16(0, into: &packet, offset: tcpOffset + 18)
        if !payload.isEmpty {
            packet.replaceSubrange((tcpOffset + tcpHeaderLength)..<totalLength, with: payload)
        }

        let ipChecksum = checksum(packet[0..<20])
        writeUInt16(ipChecksum, into: &packet, offset: 10)

        var pseudo = Data()
        pseudo.append(src)
        pseudo.append(dst)
        pseudo.append(0)
        pseudo.append(6)
        pseudo.append(contentsOf: [UInt8((tcpLength >> 8) & 0xFF), UInt8(tcpLength & 0xFF)])
        pseudo.append(packet[tcpOffset..<totalLength])
        let tcpChecksum = checksum(pseudo)
        writeUInt16(tcpChecksum, into: &packet, offset: tcpOffset + 16)
        return SynthesizedPacket(data: packet, ipVersion: .ipv4)
    }

    private static func synthesizeTCPv6(
        sourceAddress: String,
        sourcePort: UInt16,
        destinationAddress: String,
        destinationPort: UInt16,
        sequenceNumber: UInt32,
        acknowledgementNumber: UInt32,
        flags: TCPFlags,
        windowSize: UInt16,
        payload: Data
    ) -> SynthesizedPacket? {
        guard let src = ipv6AddressData(from: sourceAddress),
              let dst = ipv6AddressData(from: destinationAddress) else {
            return nil
        }
        let tcpHeaderLength = 20
        let tcpLength = tcpHeaderLength + payload.count
        guard tcpLength <= 0xFFFF else { return nil }
        let totalLength = 40 + tcpLength
        var packet = Data(count: totalLength)
        packet[0] = 0x60
        packet[1] = 0
        packet[2] = 0
        packet[3] = 0
        writeUInt16(UInt16(tcpLength), into: &packet, offset: 4)
        packet[6] = 6
        packet[7] = 64
        packet.replaceSubrange(8..<24, with: src)
        packet.replaceSubrange(24..<40, with: dst)

        let tcpOffset = 40
        writeUInt16(sourcePort, into: &packet, offset: tcpOffset)
        writeUInt16(destinationPort, into: &packet, offset: tcpOffset + 2)
        writeUInt32(sequenceNumber, into: &packet, offset: tcpOffset + 4)
        writeUInt32(acknowledgementNumber, into: &packet, offset: tcpOffset + 8)
        packet[tcpOffset + 12] = 0x50
        packet[tcpOffset + 13] = tcpFlagsByte(flags)
        writeUInt16(windowSize, into: &packet, offset: tcpOffset + 14)
        writeUInt16(0, into: &packet, offset: tcpOffset + 16)
        writeUInt16(0, into: &packet, offset: tcpOffset + 18)
        if !payload.isEmpty {
            packet.replaceSubrange((tcpOffset + tcpHeaderLength)..<totalLength, with: payload)
        }

        var pseudo = Data()
        pseudo.append(src)
        pseudo.append(dst)
        pseudo.append(contentsOf: [
            UInt8((tcpLength >> 24) & 0xFF),
            UInt8((tcpLength >> 16) & 0xFF),
            UInt8((tcpLength >> 8) & 0xFF),
            UInt8(tcpLength & 0xFF),
            0, 0, 0,
            6
        ])
        pseudo.append(packet[tcpOffset..<totalLength])
        let tcpChecksum = checksum(pseudo)
        writeUInt16(tcpChecksum, into: &packet, offset: tcpOffset + 16)
        return SynthesizedPacket(data: packet, ipVersion: .ipv6)
    }

    private static func synthesizeUDPv4(
        sourceAddress: String,
        sourcePort: UInt16,
        destinationAddress: String,
        destinationPort: UInt16,
        payload: Data
    ) -> SynthesizedPacket? {
        guard let src = ipv4AddressData(from: sourceAddress),
              let dst = ipv4AddressData(from: destinationAddress) else {
            return nil
        }
        let udpLength = 8 + payload.count
        let totalLength = 20 + udpLength
        guard totalLength <= 0xFFFF else { return nil }

        var packet = Data(count: totalLength)
        packet[0] = 0x45
        packet[1] = 0
        writeUInt16(UInt16(totalLength), into: &packet, offset: 2)
        writeUInt16(0, into: &packet, offset: 4)
        writeUInt16(0x4000, into: &packet, offset: 6)
        packet[8] = 64
        packet[9] = 17
        writeUInt16(0, into: &packet, offset: 10)
        packet.replaceSubrange(12..<16, with: src)
        packet.replaceSubrange(16..<20, with: dst)

        let udpOffset = 20
        writeUInt16(sourcePort, into: &packet, offset: udpOffset)
        writeUInt16(destinationPort, into: &packet, offset: udpOffset + 2)
        writeUInt16(UInt16(udpLength), into: &packet, offset: udpOffset + 4)
        writeUInt16(0, into: &packet, offset: udpOffset + 6)
        if !payload.isEmpty {
            packet.replaceSubrange((udpOffset + 8)..<totalLength, with: payload)
        }

        let ipChecksum = checksum(packet[0..<20])
        writeUInt16(ipChecksum, into: &packet, offset: 10)

        var pseudo = Data()
        pseudo.append(src)
        pseudo.append(dst)
        pseudo.append(0)
        pseudo.append(17)
        pseudo.append(contentsOf: [UInt8((udpLength >> 8) & 0xFF), UInt8(udpLength & 0xFF)])
        pseudo.append(packet[udpOffset..<totalLength])
        let udpChecksum = checksum(pseudo)
        writeUInt16(udpChecksum == 0 ? 0xFFFF : udpChecksum, into: &packet, offset: udpOffset + 6)
        return SynthesizedPacket(data: packet, ipVersion: .ipv4)
    }

    private static func synthesizeUDPv6(
        sourceAddress: String,
        sourcePort: UInt16,
        destinationAddress: String,
        destinationPort: UInt16,
        payload: Data
    ) -> SynthesizedPacket? {
        guard let src = ipv6AddressData(from: sourceAddress),
              let dst = ipv6AddressData(from: destinationAddress) else {
            return nil
        }
        let udpLength = 8 + payload.count
        guard udpLength <= 0xFFFF else { return nil }
        let totalLength = 40 + udpLength
        var packet = Data(count: totalLength)
        packet[0] = 0x60
        writeUInt16(UInt16(udpLength), into: &packet, offset: 4)
        packet[6] = 17
        packet[7] = 64
        packet.replaceSubrange(8..<24, with: src)
        packet.replaceSubrange(24..<40, with: dst)

        let udpOffset = 40
        writeUInt16(sourcePort, into: &packet, offset: udpOffset)
        writeUInt16(destinationPort, into: &packet, offset: udpOffset + 2)
        writeUInt16(UInt16(udpLength), into: &packet, offset: udpOffset + 4)
        writeUInt16(0, into: &packet, offset: udpOffset + 6)
        if !payload.isEmpty {
            packet.replaceSubrange((udpOffset + 8)..<totalLength, with: payload)
        }

        var pseudo = Data()
        pseudo.append(src)
        pseudo.append(dst)
        pseudo.append(contentsOf: [
            UInt8((udpLength >> 24) & 0xFF),
            UInt8((udpLength >> 16) & 0xFF),
            UInt8((udpLength >> 8) & 0xFF),
            UInt8(udpLength & 0xFF),
            0, 0, 0,
            17
        ])
        pseudo.append(packet[udpOffset..<totalLength])
        let udpChecksum = checksum(pseudo)
        writeUInt16(udpChecksum == 0 ? 0xFFFF : udpChecksum, into: &packet, offset: udpOffset + 6)
        return SynthesizedPacket(data: packet, ipVersion: .ipv6)
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

    private static func checksum(_ bytes: Data) -> UInt16 {
        var sum: UInt32 = 0
        var index = 0
        while index + 1 < bytes.count {
            let word = (UInt16(bytes[index]) << 8) | UInt16(bytes[index + 1])
            sum += UInt32(word)
            index += 2
        }
        if index < bytes.count {
            sum += UInt32(UInt16(bytes[index]) << 8)
        }
        while (sum >> 16) != 0 {
            sum = (sum & 0xFFFF) + (sum >> 16)
        }
        return ~UInt16(sum & 0xFFFF)
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

    private static func ipv4AddressData(from string: String) -> Data? {
        var addr = in_addr()
        let result = string.withCString { inet_pton(AF_INET, $0, &addr) }
        guard result == 1 else { return nil }
        return withUnsafeBytes(of: addr) { Data($0) }
    }

    private static func ipv6AddressData(from string: String) -> Data? {
        var addr = in6_addr()
        let result = string.withCString { inet_pton(AF_INET6, $0, &addr) }
        guard result == 1 else { return nil }
        return withUnsafeBytes(of: addr) { Data($0) }
    }
}
