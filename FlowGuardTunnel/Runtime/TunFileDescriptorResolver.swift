import Foundation
import NetworkExtension
import Darwin

enum TunFileDescriptorResolver {
    static func resolveUTUNFileDescriptor(
        from packetFlow: NEPacketTunnelFlow,
        attempts: Int = 20,
        retryDelayMicroseconds: useconds_t = 100_000
    ) -> Int32? {
        let retries = max(1, attempts)
        for attempt in 1...retries {
            if let fd = resolveOnce(from: packetFlow) {
                return fd
            }

            if attempt < retries {
                usleep(retryDelayMicroseconds)
            }
        }

        return nil
    }

    private static func resolveOnce(from packetFlow: NEPacketTunnelFlow) -> Int32? {
        let keyPaths = [
            "socket.fileDescriptor",
            "socket.fileDescriptorNumber",
            "socket.socket.fileDescriptor",
            "_socket.fileDescriptor",
            "_socket.fileDescriptorNumber",
            "fileDescriptor",
            "_fileDescriptor"
        ]

        for keyPath in keyPaths {
            guard let raw = safeValue(forKeyPath: keyPath, on: packetFlow as NSObject) else {
                continue
            }
            if let fd = extractFileDescriptor(from: raw), isUTUNFileDescriptor(fd) {
                return fd
            }
        }

        if let socketObject = safeValue(forKey: "socket", on: packetFlow as NSObject),
           let fd = extractFileDescriptor(from: socketObject),
           isUTUNFileDescriptor(fd) {
            return fd
        }

        if let scanned = scanForUTUNFileDescriptor() {
            return scanned
        }

        return nil
    }

    private static func extractFileDescriptor(from raw: Any) -> Int32? {
        if let number = raw as? NSNumber {
            let fd = number.int32Value
            return fd >= 0 ? fd : nil
        }

        if let value = raw as? Int32 {
            return value >= 0 ? value : nil
        }

        if let value = raw as? Int {
            return value >= 0 ? Int32(value) : nil
        }

        if let object = raw as? NSObject {
            let nestedKeys = ["fileDescriptor", "fileDescriptorNumber", "_fileDescriptor"]
            for key in nestedKeys {
                if let nested = safeValue(forKey: key, on: object),
                   let fd = extractFileDescriptor(from: nested) {
                    return fd
                }
            }
        }

        return nil
    }

    private static func safeValue(forKey key: String, on object: NSObject) -> Any? {
        let selector = NSSelectorFromString(key)
        guard object.responds(to: selector) else {
            return nil
        }
        return object.value(forKey: key)
    }

    private static func safeValue(forKeyPath keyPath: String, on object: NSObject) -> Any? {
        let segments = keyPath.split(separator: ".").map(String.init)
        guard !segments.isEmpty else {
            return nil
        }

        var current: Any? = object
        for segment in segments {
            guard let currentObject = current as? NSObject else {
                return nil
            }
            guard let next = safeValue(forKey: segment, on: currentObject) else {
                return nil
            }
            current = next
        }

        return current
    }

    private static func scanForUTUNFileDescriptor(maxFD: Int32 = 4096) -> Int32? {
        var fd: Int32 = 0
        while fd < maxFD {
            if isUTUNFileDescriptor(fd) {
                return fd
            }

            fd += 1
        }
        return nil
    }

    static func utunInterfaceName(from fd: Int32) -> String? {
        guard fd >= 0 else {
            return nil
        }

        var name = [CChar](repeating: 0, count: Int(Self.ifNameMax))
        var length = socklen_t(name.count)
        let result = getsockopt(fd, Self.sysProtoControl, Self.utunOptIfName, &name, &length)
        guard result == 0 else {
            return nil
        }

        return String(cString: name)
    }

    static func interfaceTrafficCounters(interfaceName: String) -> (bytesIn: UInt64, bytesOut: UInt64)? {
        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0, let first = pointer else {
            return nil
        }
        defer { freeifaddrs(first) }

        var current = first
        while true {
            let interface = current.pointee
            let name = String(cString: interface.ifa_name)

            if name == interfaceName,
               let data = interface.ifa_data {
                let ifData = data.assumingMemoryBound(to: if_data.self).pointee
                return (bytesIn: UInt64(ifData.ifi_ibytes), bytesOut: UInt64(ifData.ifi_obytes))
            }

            guard let next = interface.ifa_next else {
                break
            }
            current = next
        }

        return nil
    }

    private static func isUTUNFileDescriptor(_ fd: Int32) -> Bool {
        guard fd >= 0 else {
            return false
        }

        guard let ifName = utunInterfaceName(from: fd), ifName.hasPrefix("utun") else {
            return false
        }

        var addr = SockAddrCtlLite()
        var length = socklen_t(MemoryLayout<SockAddrCtlLite>.size)
        let result = withUnsafeMutablePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
                getpeername(fd, saPtr, &length)
            }
        }

        return result == 0
            && addr.scFamily == Self.afSystem
            && addr.ssSysaddr == Self.afSysControl
    }

    private static let afSystem: UInt8 = 32
    private static let afSysControl: UInt16 = 2
    private static let sysProtoControl: Int32 = 2
    private static let utunOptIfName: Int32 = 2
    private static let ifNameMax: UInt32 = 16
}

private struct SockAddrCtlLite {
    var scLen: UInt8 = 0
    var scFamily: UInt8 = 0
    var ssSysaddr: UInt16 = 0
    var scID: UInt32 = 0
    var scUnit: UInt32 = 0
    var reserved0: UInt32 = 0
    var reserved1: UInt32 = 0
    var reserved2: UInt32 = 0
    var reserved3: UInt32 = 0
    var reserved4: UInt32 = 0
}
