import Foundation

struct SynthesizedPacket: Sendable {
    let data: Data
    let ipVersion: IPVersion
}

struct PacketFlowEgressWriterSnapshot: Sendable {
    let writeCalls: Int64
    let packetsWritten: Int64
    let bytesWritten: Int64
    let droppedPackets: Int64
}

final class PacketFlowEgressWriter {
    private let queue = DispatchQueue(label: "com.uvays.FlowGuard.packetflow.egress-writer")
    private weak var flow: (any PacketFlowIO)?
    private var logHandler: ((String) -> Void)?

    private var writeCalls: Int64 = 0
    private var packetsWritten: Int64 = 0
    private var bytesWritten: Int64 = 0
    private var droppedPackets: Int64 = 0

    func start(flow: (any PacketFlowIO)?, log: @escaping (String) -> Void) {
        queue.sync {
            self.flow = flow
            self.logHandler = log
            writeCalls = 0
            packetsWritten = 0
            bytesWritten = 0
            droppedPackets = 0
            if flow == nil {
                log("PacketFlowEgressWriter started without packetFlow; egress writes will be dropped")
            }
        }
    }

    func stop() {
        queue.sync {
            flow = nil
            logHandler = nil
        }
    }

    func write(packets: [SynthesizedPacket], onWrite: ((Int, Int) -> Void)? = nil) {
        guard !packets.isEmpty else { return }
        queue.async {
            guard let flow = self.flow else {
                self.droppedPackets += Int64(packets.count)
                return
            }

            let payloads = packets.map(\.data)
            let protocols = packets.map { packet in
                NSNumber(value: packet.ipVersion == .ipv4 ? Int32(AF_INET) : Int32(AF_INET6))
            }

            self.writeCalls += 1
            self.packetsWritten += Int64(payloads.count)
            let bytes = payloads.reduce(into: 0) { $0 += $1.count }
            self.bytesWritten += Int64(bytes)
            _ = flow.writePacketBatch(payloads, protocols: protocols)
            onWrite?(payloads.count, bytes)
        }
    }

    func snapshot() -> PacketFlowEgressWriterSnapshot {
        queue.sync {
            PacketFlowEgressWriterSnapshot(
                writeCalls: writeCalls,
                packetsWritten: packetsWritten,
                bytesWritten: bytesWritten,
                droppedPackets: droppedPackets
            )
        }
    }
}
