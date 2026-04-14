import Darwin
import Foundation
import Network

struct SOCKS5UDPDatagram: Sendable {
    let destinationHost: String
    let destinationPort: UInt16
    let payload: Data
}

enum SOCKS5UDPAssociateError: LocalizedError {
    case invalidServerPort
    case invalidDestination
    case invalidDatagram
    case handshakeFailed(String)
    case connectionFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidServerPort:
            return "Invalid SOCKS5 UDP server port."
        case .invalidDestination:
            return "Invalid SOCKS5 UDP destination."
        case .invalidDatagram:
            return "Invalid SOCKS5 UDP datagram."
        case let .handshakeFailed(message):
            return "SOCKS5 UDP associate handshake failed: \(message)"
        case let .connectionFailed(message):
            return "SOCKS5 UDP associate connection failed: \(message)"
        }
    }
}

enum SOCKS5UDPDatagramCodec {
    static func build(destinationHost: String, destinationPort: UInt16, payload: Data) -> Data? {
        var bytes = Data([0x00, 0x00, 0x00])

        if let ipv4 = ipv4Bytes(destinationHost) {
            bytes.append(0x01)
            bytes.append(ipv4)
        } else if let ipv6 = ipv6Bytes(destinationHost) {
            bytes.append(0x04)
            bytes.append(ipv6)
        } else {
            guard let hostData = destinationHost.data(using: .utf8), hostData.count <= 255 else { return nil }
            bytes.append(0x03)
            bytes.append(UInt8(hostData.count))
            bytes.append(hostData)
        }

        bytes.append(UInt8((destinationPort >> 8) & 0xFF))
        bytes.append(UInt8(destinationPort & 0xFF))
        bytes.append(payload)
        return bytes
    }

    static func parse(_ data: Data) -> SOCKS5UDPDatagram? {
        guard data.count >= 10 else { return nil }
        guard data[0] == 0x00, data[1] == 0x00 else { return nil }
        guard data[2] == 0x00 else { return nil }

        let atyp = data[3]
        var index = 4
        let host: String
        switch atyp {
        case 0x01:
            guard index + 4 + 2 <= data.count else { return nil }
            host = ipv4String(data[index..<(index + 4)]) ?? "0.0.0.0"
            index += 4
        case 0x04:
            guard index + 16 + 2 <= data.count else { return nil }
            host = ipv6String(data[index..<(index + 16)]) ?? "::"
            index += 16
        case 0x03:
            guard index + 1 <= data.count else { return nil }
            let length = Int(data[index])
            index += 1
            guard index + length + 2 <= data.count else { return nil }
            host = String(decoding: data[index..<(index + length)], as: UTF8.self)
            index += length
        default:
            return nil
        }

        let port = (UInt16(data[index]) << 8) | UInt16(data[index + 1])
        index += 2
        guard index <= data.count else { return nil }

        return SOCKS5UDPDatagram(
            destinationHost: host,
            destinationPort: port,
            payload: Data(data[index..<data.count])
        )
    }

    private static func ipv4Bytes(_ host: String) -> Data? {
        var addr = in_addr()
        let result = host.withCString { inet_pton(AF_INET, $0, &addr) }
        guard result == 1 else { return nil }
        return withUnsafeBytes(of: addr) { Data($0) }
    }

    private static func ipv6Bytes(_ host: String) -> Data? {
        var addr = in6_addr()
        let result = host.withCString { inet_pton(AF_INET6, $0, &addr) }
        guard result == 1 else { return nil }
        return withUnsafeBytes(of: addr) { Data($0) }
    }

    private static func ipv4String(_ bytes: Data.SubSequence) -> String? {
        guard bytes.count == 4 else { return nil }
        var addr = in_addr()
        withUnsafeMutableBytes(of: &addr) { buffer in
            _ = bytes.copyBytes(to: buffer)
        }
        var str = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        guard inet_ntop(AF_INET, &addr, &str, socklen_t(INET_ADDRSTRLEN)) != nil else { return nil }
        return String(cString: str)
    }

    private static func ipv6String(_ bytes: Data.SubSequence) -> String? {
        guard bytes.count == 16 else { return nil }
        var addr = in6_addr()
        withUnsafeMutableBytes(of: &addr) { buffer in
            _ = bytes.copyBytes(to: buffer)
        }
        var str = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        guard inet_ntop(AF_INET6, &addr, &str, socklen_t(INET6_ADDRSTRLEN)) != nil else { return nil }
        return String(cString: str)
    }
}

final class SOCKS5UDPAssociation {
    private let controlConnection: NWConnection
    private let udpConnection: NWConnection
    private let queue: DispatchQueue

    init(controlConnection: NWConnection, udpConnection: NWConnection, queue: DispatchQueue) {
        self.controlConnection = controlConnection
        self.udpConnection = udpConnection
        self.queue = queue
    }

    func send(datagram: SOCKS5UDPDatagram, completion: @escaping (Error?) -> Void) {
        guard let payload = SOCKS5UDPDatagramCodec.build(
            destinationHost: datagram.destinationHost,
            destinationPort: datagram.destinationPort,
            payload: datagram.payload
        ) else {
            completion(SOCKS5UDPAssociateError.invalidDestination)
            return
        }

        udpConnection.send(content: payload, completion: .contentProcessed { error in
            completion(error)
        })
    }

    func receiveLoop(onDatagram: @escaping (SOCKS5UDPDatagram) -> Void, onComplete: @escaping (Error?) -> Void) {
        receiveNext(onDatagram: onDatagram, onComplete: onComplete)
    }

    func close() {
        controlConnection.cancel()
        udpConnection.cancel()
    }

    private func receiveNext(onDatagram: @escaping (SOCKS5UDPDatagram) -> Void, onComplete: @escaping (Error?) -> Void) {
        udpConnection.receiveMessage { [weak self] data, _, isComplete, error in
            if let error {
                onComplete(error)
                return
            }
            if let data, !data.isEmpty, let datagram = SOCKS5UDPDatagramCodec.parse(data) {
                onDatagram(datagram)
            }
            _ = isComplete
            self?.receiveNext(onDatagram: onDatagram, onComplete: onComplete)
        }
    }
}

final class SOCKS5UDPAssociateClient {
    private let queue = DispatchQueue(label: "com.uvays.FlowGuard.packetflow.socks5-udp")

    func open(socksPort: Int, completion: @escaping (Result<SOCKS5UDPAssociation, Error>) -> Void) {
        guard let socksEndpointPort = NWEndpoint.Port(rawValue: UInt16(socksPort)) else {
            completion(.failure(SOCKS5UDPAssociateError.invalidServerPort))
            return
        }

        let control = NWConnection(host: NWEndpoint.Host("127.0.0.1"), port: socksEndpointPort, using: .tcp)
        control.stateUpdateHandler = { state in
            switch state {
            case .ready:
                self.performHandshake(control: control, completion: completion)
            case let .failed(error):
                completion(.failure(SOCKS5UDPAssociateError.connectionFailed(error.localizedDescription)))
            case .cancelled:
                completion(.failure(SOCKS5UDPAssociateError.connectionFailed("Control connection cancelled")))
            default:
                break
            }
        }
        control.start(queue: queue)
    }

    private func performHandshake(
        control: NWConnection,
        completion: @escaping (Result<SOCKS5UDPAssociation, Error>) -> Void
    ) {
        control.send(content: Data([0x05, 0x01, 0x00]), completion: .contentProcessed { error in
            if let error {
                completion(.failure(error))
                return
            }

            self.receiveExact(connection: control, length: 2) { methodResult in
                switch methodResult {
                case let .failure(error):
                    completion(.failure(error))
                case let .success(method):
                    guard method.count == 2, method[0] == 0x05, method[1] == 0x00 else {
                        completion(.failure(SOCKS5UDPAssociateError.handshakeFailed("Method negotiation rejected")))
                        return
                    }
                    self.sendUDPAssociate(control: control, completion: completion)
                }
            }
        })
    }

    private func sendUDPAssociate(
        control: NWConnection,
        completion: @escaping (Result<SOCKS5UDPAssociation, Error>) -> Void
    ) {
        let request = Data([0x05, 0x03, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
        control.send(content: request, completion: .contentProcessed { error in
            if let error {
                completion(.failure(error))
                return
            }

            self.receiveExact(connection: control, length: 4) { headerResult in
                switch headerResult {
                case let .failure(error):
                    completion(.failure(error))
                case let .success(header):
                    guard header.count == 4, header[0] == 0x05 else {
                        completion(.failure(SOCKS5UDPAssociateError.handshakeFailed("Invalid ASSOCIATE response")))
                        return
                    }
                    guard header[1] == 0x00 else {
                        completion(.failure(SOCKS5UDPAssociateError.handshakeFailed("ASSOCIATE failed with code \(header[1])")))
                        return
                    }
                    self.receiveAssociateBindAddress(control: control, atyp: header[3], completion: completion)
                }
            }
        })
    }

    private func receiveAssociateBindAddress(
        control: NWConnection,
        atyp: UInt8,
        completion: @escaping (Result<SOCKS5UDPAssociation, Error>) -> Void
    ) {
        switch atyp {
        case 0x01:
            receiveExact(connection: control, length: 6) { result in
                completion(result.flatMap { self.makeAssociation(control: control, bindData: $0, atyp: atyp) })
            }
        case 0x04:
            receiveExact(connection: control, length: 18) { result in
                completion(result.flatMap { self.makeAssociation(control: control, bindData: $0, atyp: atyp) })
            }
        case 0x03:
            receiveExact(connection: control, length: 1) { lengthResult in
                switch lengthResult {
                case let .failure(error):
                    completion(.failure(error))
                case let .success(lengthData):
                    guard let domainLength = lengthData.first else {
                        completion(.failure(SOCKS5UDPAssociateError.handshakeFailed("Missing domain length")))
                        return
                    }
                    self.receiveExact(connection: control, length: Int(domainLength) + 2) { result in
                        completion(result.flatMap { self.makeAssociation(control: control, bindData: $0, atyp: atyp) })
                    }
                }
            }
        default:
            completion(.failure(SOCKS5UDPAssociateError.handshakeFailed("Unsupported BND.ADDR type")))
        }
    }

    private func makeAssociation(
        control: NWConnection,
        bindData: Data,
        atyp: UInt8
    ) -> Result<SOCKS5UDPAssociation, Error> {
        let endpointResult = parseBindEndpoint(bindData: bindData, atyp: atyp)
        switch endpointResult {
        case let .failure(error):
            return .failure(error)
        case let .success(endpoint):
            let udpConnection = NWConnection(to: endpoint, using: .udp)
            udpConnection.start(queue: queue)
            return .success(SOCKS5UDPAssociation(controlConnection: control, udpConnection: udpConnection, queue: queue))
        }
    }

    private func parseBindEndpoint(bindData: Data, atyp: UInt8) -> Result<NWEndpoint, Error> {
        switch atyp {
        case 0x01:
            guard bindData.count == 6 else {
                return .failure(SOCKS5UDPAssociateError.handshakeFailed("Invalid IPv4 bind response size"))
            }
            let host = bindData.prefix(4).map(String.init).joined(separator: ".")
            let port = (UInt16(bindData[4]) << 8) | UInt16(bindData[5])
            guard let endpointPort = NWEndpoint.Port(rawValue: port) else {
                return .failure(SOCKS5UDPAssociateError.invalidServerPort)
            }
            return .success(.hostPort(host: .init(host), port: endpointPort))
        case 0x04:
            guard bindData.count == 18 else {
                return .failure(SOCKS5UDPAssociateError.handshakeFailed("Invalid IPv6 bind response size"))
            }
            var addr = in6_addr()
            withUnsafeMutableBytes(of: &addr) { buffer in
                _ = bindData.prefix(16).copyBytes(to: buffer)
            }
            var str = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            guard inet_ntop(AF_INET6, &addr, &str, socklen_t(INET6_ADDRSTRLEN)) != nil else {
                return .failure(SOCKS5UDPAssociateError.handshakeFailed("Failed to parse IPv6 bind address"))
            }
            let host = String(cString: str)
            let port = (UInt16(bindData[16]) << 8) | UInt16(bindData[17])
            guard let endpointPort = NWEndpoint.Port(rawValue: port) else {
                return .failure(SOCKS5UDPAssociateError.invalidServerPort)
            }
            return .success(.hostPort(host: .init(host), port: endpointPort))
        case 0x03:
            guard bindData.count >= 3 else {
                return .failure(SOCKS5UDPAssociateError.handshakeFailed("Invalid domain bind response size"))
            }
            let domainLength = Int(bindData[0])
            guard 1 + domainLength + 2 == bindData.count else {
                return .failure(SOCKS5UDPAssociateError.handshakeFailed("Invalid domain bind payload length"))
            }
            let host = String(decoding: bindData[1..<(1 + domainLength)], as: UTF8.self)
            let portIndex = 1 + domainLength
            let port = (UInt16(bindData[portIndex]) << 8) | UInt16(bindData[portIndex + 1])
            guard let endpointPort = NWEndpoint.Port(rawValue: port) else {
                return .failure(SOCKS5UDPAssociateError.invalidServerPort)
            }
            return .success(.hostPort(host: .init(host), port: endpointPort))
        default:
            return .failure(SOCKS5UDPAssociateError.handshakeFailed("Unsupported bind address type"))
        }
    }

    private func receiveExact(
        connection: NWConnection,
        length: Int,
        completion: @escaping (Result<Data, Error>) -> Void
    ) {
        guard length > 0 else {
            completion(.success(Data()))
            return
        }

        var collected = Data()
        func receiveStep() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: length - collected.count) { data, _, isComplete, error in
                if let error {
                    completion(.failure(error))
                    return
                }
                if let data, !data.isEmpty {
                    collected.append(data)
                }
                if collected.count >= length {
                    completion(.success(collected.prefix(length)))
                    return
                }
                if isComplete {
                    completion(.failure(SOCKS5UDPAssociateError.handshakeFailed("Connection closed during read")))
                    return
                }
                receiveStep()
            }
        }
        receiveStep()
    }
}
