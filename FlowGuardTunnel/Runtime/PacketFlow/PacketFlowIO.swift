import Foundation
@preconcurrency import NetworkExtension

protocol PacketFlowIO: AnyObject {
    func readPacketBatch(_ completion: @escaping ([Data], [NSNumber]) -> Void)
    func writePacketBatch(_ packets: [Data], protocols: [NSNumber]) -> Bool
}

extension NEPacketTunnelFlow: PacketFlowIO {
    func readPacketBatch(_ completion: @escaping ([Data], [NSNumber]) -> Void) {
        readPackets(completionHandler: completion)
    }

    func writePacketBatch(_ packets: [Data], protocols: [NSNumber]) -> Bool {
        writePackets(packets, withProtocols: protocols)
    }
}
