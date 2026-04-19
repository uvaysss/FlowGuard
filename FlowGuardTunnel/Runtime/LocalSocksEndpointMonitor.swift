import Darwin
import Foundation

enum LocalSocksReadiness {
    case ready
    case timeout
    case exited(Int32)
}

protocol LocalSocksEndpointMonitoring {
    func waitUntilReady(
        port: Int,
        attempts: Int,
        delayMicroseconds: useconds_t,
        exitCode: () -> Int32?
    ) -> LocalSocksReadiness
}

struct DefaultLocalSocksEndpointMonitor: LocalSocksEndpointMonitoring {
    func waitUntilReady(
        port: Int,
        attempts: Int = 30,
        delayMicroseconds: useconds_t = 100_000,
        exitCode: () -> Int32?
    ) -> LocalSocksReadiness {
        for _ in 0..<attempts {
            if let code = exitCode() {
                return .exited(code)
            }
            if canConnectLocalhost(port: port) {
                return .ready
            }
            usleep(delayMicroseconds)
        }
        return .timeout
    }

    private func canConnectLocalhost(port: Int) -> Bool {
        let sock = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard sock >= 0 else {
            return false
        }
        defer { close(sock) }

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port).bigEndian)
        addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

        var socketAddress = sockaddr()
        memcpy(&socketAddress, &addr, MemoryLayout<sockaddr_in>.size)

        let result = withUnsafePointer(to: &socketAddress) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { pointer in
                connect(sock, pointer, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }

        return result == 0
    }
}
