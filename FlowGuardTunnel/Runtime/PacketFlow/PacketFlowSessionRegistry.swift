import Foundation

final class PacketFlowSessionRegistry {
    private let queue = DispatchQueue(label: "com.uvays.FlowGuard.packetflow.registry", attributes: .concurrent)
    private var tcpSessions: [TCPFlowKey: PacketFlowTCPSession] = [:]

    func session(for key: TCPFlowKey) -> PacketFlowTCPSession? {
        queue.sync { tcpSessions[key] }
    }

    @discardableResult
    func upsertSession(for key: TCPFlowKey, makeSession: () -> PacketFlowTCPSession) -> (PacketFlowTCPSession, inserted: Bool) {
        queue.sync(flags: .barrier) {
            if let existing = tcpSessions[key] {
                return (existing, false)
            }
            let session = makeSession()
            tcpSessions[key] = session
            return (session, true)
        }
    }

    @discardableResult
    func removeSession(for key: TCPFlowKey) -> Bool {
        queue.sync(flags: .barrier) {
            tcpSessions.removeValue(forKey: key) != nil
        }
    }

    func forEachSession(_ body: (PacketFlowTCPSession) -> Void) {
        let sessions = queue.sync { Array(tcpSessions.values) }
        sessions.forEach(body)
    }

    @discardableResult
    func removeAllSessions(onRemove: ((PacketFlowTCPSession) -> Void)? = nil) -> Int {
        queue.sync(flags: .barrier) {
            let sessions = Array(tcpSessions.values)
            tcpSessions.removeAll()
            sessions.forEach { onRemove?($0) }
            return sessions.count
        }
    }

    @discardableResult
    func cleanupIdleSessions(now: Date = Date(), maxIdle: TimeInterval, onRemove: ((PacketFlowTCPSession) -> Void)? = nil) -> Int {
        queue.sync(flags: .barrier) {
            var removed: [PacketFlowTCPSession] = []
            tcpSessions = tcpSessions.filter { _, session in
                let shouldKeep = now.timeIntervalSince(session.lastSeenAt) <= maxIdle
                if !shouldKeep {
                    removed.append(session)
                }
                return shouldKeep
            }
            removed.forEach { onRemove?($0) }
            return removed.count
        }
    }

    func count() -> Int {
        queue.sync { tcpSessions.count }
    }
}
