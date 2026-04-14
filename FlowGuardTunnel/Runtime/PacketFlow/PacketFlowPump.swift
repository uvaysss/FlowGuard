import Foundation
import NetworkExtension

struct PacketFlowPumpSnapshot: Sendable {
    let ingressPackets: Int64
    let ingressBytes: Int64
    let egressPackets: Int64
    let egressBytes: Int64
    let parseFailures: Int64
}

final class PacketFlowPump {
    private let queue = DispatchQueue(label: "com.uvays.FlowGuard.packetflow.pump")
    private var running = false
    private var sourceFlow: NEPacketTunnelFlow?
    private var logHandler: ((String) -> Void)?
    private var summaryTimer: DispatchSourceTimer?
    private var ingressHandler: (([Data]) -> Void)?
    private var ingressPackets: Int64 = 0
    private var ingressBytes: Int64 = 0
    private var egressPackets: Int64 = 0
    private var egressBytes: Int64 = 0
    private var parseFailures: Int64 = 0

    func start(
        flow: NEPacketTunnelFlow?,
        log: @escaping (String) -> Void,
        onIngressPackets: (([Data]) -> Void)? = nil
    ) {
        queue.sync {
            guard !running else { return }
            running = true
            sourceFlow = flow
            logHandler = log
            ingressHandler = onIngressPackets
            scheduleSummaryTimerLocked()
            if let flow {
                log("PacketFlowPump started")
                scheduleReadLocked(flow: flow)
            } else {
                log("PacketFlowPump started without packetFlow reference; running in idle mode")
            }
        }
    }

    func stop() {
        queue.sync {
            guard running else { return }
            running = false
            sourceFlow = nil
            ingressHandler = nil
            summaryTimer?.cancel()
            summaryTimer = nil
            logHandler?("PacketFlowPump stopped")
        }
    }

    func snapshot() -> PacketFlowPumpSnapshot {
        queue.sync {
            PacketFlowPumpSnapshot(
                ingressPackets: ingressPackets,
                ingressBytes: ingressBytes,
                egressPackets: egressPackets,
                egressBytes: egressBytes,
                parseFailures: parseFailures
            )
        }
    }

    func recordEgress(packets: Int, bytes: Int) {
        guard packets >= 0, bytes >= 0 else { return }
        queue.async {
            self.egressPackets += Int64(packets)
            self.egressBytes += Int64(bytes)
        }
    }

    private func scheduleReadLocked(flow: NEPacketTunnelFlow) {
        guard running else { return }
        flow.readPackets { [weak self] packets, _ in
            guard let self else { return }
            self.queue.async {
                guard self.running else { return }
                self.processIngressLocked(packets: packets)
                self.scheduleReadLocked(flow: flow)
            }
        }
    }

    private func processIngressLocked(packets: [Data]) {
        guard !packets.isEmpty else { return }
        ingressPackets += Int64(packets.count)
        let bytes = packets.reduce(into: 0) { partial, data in
            partial += data.count
        }
        ingressBytes += Int64(bytes)

        for packet in packets {
            if IPPacketCodec.parse(packet: packet) == nil {
                parseFailures += 1
            }
        }
        ingressHandler?(packets)
    }

    private func scheduleSummaryTimerLocked() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 5, repeating: 5)
        timer.setEventHandler { [weak self] in
            guard let self, self.running else { return }
            self.logHandler?(
                "PacketFlowPump stats ingressPackets=\(self.ingressPackets) ingressBytes=\(self.ingressBytes) egressPackets=\(self.egressPackets) egressBytes=\(self.egressBytes) parseFailures=\(self.parseFailures)"
            )
        }
        summaryTimer = timer
        timer.resume()
    }
}
