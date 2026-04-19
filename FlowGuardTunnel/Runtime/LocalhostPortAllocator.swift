import Darwin
import Foundation

protocol LocalhostPortAllocating {
    func resolveAvailablePort(preferred: Int, scanWindow: Int) -> Int?
}

struct DefaultLocalhostPortAllocator: LocalhostPortAllocating {
    func resolveAvailablePort(preferred: Int, scanWindow: Int = 32) -> Int? {
        guard (1...65535).contains(preferred) else {
            return nil
        }

        let upperBound = min(65535, preferred + scanWindow)
        for port in preferred...upperBound where isPortAvailable(port: port) {
            return port
        }
        return nil
    }

    private func isPortAvailable(port: Int) -> Bool {
        guard !canConnectLocalhost(port: port) else {
            return false
        }
        return canBindLocalhost(port: port)
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

    private func canBindLocalhost(port: Int) -> Bool {
        let sock = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard sock >= 0 else {
            return false
        }
        defer { close(sock) }

        var reuseAddr: Int32 = 1
        _ = setsockopt(
            sock,
            SOL_SOCKET,
            SO_REUSEADDR,
            &reuseAddr,
            socklen_t(MemoryLayout<Int32>.size)
        )

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port).bigEndian)
        addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

        var socketAddress = sockaddr()
        memcpy(&socketAddress, &addr, MemoryLayout<sockaddr_in>.size)

        let result = withUnsafePointer(to: &socketAddress) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { pointer in
                bind(sock, pointer, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }

        return result == 0
    }
}
