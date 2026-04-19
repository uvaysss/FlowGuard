import Foundation
import Network

protocol SOCKS5TCPStreaming: AnyObject {
    func send(_ data: Data, completion: @escaping (Error?) -> Void)
    func receiveLoop(onData: @escaping (Data) -> Void, onComplete: @escaping (Error?) -> Void)
    func cancel()
}

protocol SOCKS5TCPConnecting {
    func connect(
        socksPort: Int,
        destinationHost: String,
        destinationPort: UInt16,
        completion: @escaping (Result<any SOCKS5TCPStreaming, Error>) -> Void
    )
}

enum SOCKS5ConnectorError: LocalizedError {
    case invalidDestination
    case handshakeFailed(String)
    case connectionFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidDestination:
            return "Invalid SOCKS5 destination."
        case let .handshakeFailed(message):
            return "SOCKS5 handshake failed: \(message)"
        case let .connectionFailed(message):
            return "SOCKS5 connection failed: \(message)"
        }
    }
}

final class SOCKS5TCPStream {
    private let connection: NWConnection
    private let queue: DispatchQueue

    init(connection: NWConnection, queue: DispatchQueue) {
        self.connection = connection
        self.queue = queue
    }

    func send(_ data: Data, completion: @escaping (Error?) -> Void) {
        connection.send(content: data, completion: .contentProcessed { error in
            completion(error)
        })
    }

    func receiveLoop(onData: @escaping (Data) -> Void, onComplete: @escaping (Error?) -> Void) {
        receiveNext(onData: onData, onComplete: onComplete)
    }

    func cancel() {
        connection.cancel()
    }

    private func receiveNext(onData: @escaping (Data) -> Void, onComplete: @escaping (Error?) -> Void) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4 * 1024) { [weak self] data, _, isComplete, error in
            if let error {
                onComplete(error)
                return
            }
            if let data, !data.isEmpty {
                onData(data)
            }
            if isComplete {
                onComplete(nil)
                return
            }
            self?.receiveNext(onData: onData, onComplete: onComplete)
        }
    }
}

extension SOCKS5TCPStream: SOCKS5TCPStreaming {}

final class SOCKS5TCPConnector: SOCKS5TCPConnecting {
    private let queue = DispatchQueue(label: "com.uvays.FlowGuard.packetflow.socks5")

    func connect(
        socksPort: Int,
        destinationHost: String,
        destinationPort: UInt16,
        completion: @escaping (Result<any SOCKS5TCPStreaming, Error>) -> Void
    ) {
        let completionLock = NSLock()
        var didComplete = false
        let finish: (Result<any SOCKS5TCPStreaming, Error>) -> Void = { result in
            completionLock.lock()
            let shouldComplete = !didComplete
            if shouldComplete {
                didComplete = true
            }
            completionLock.unlock()
            guard shouldComplete else { return }
            completion(result)
        }

        let endpointHost = NWEndpoint.Host("127.0.0.1")
        guard let endpointPort = NWEndpoint.Port(rawValue: UInt16(socksPort)) else {
            finish(.failure(SOCKS5ConnectorError.connectionFailed("Invalid SOCKS port")))
            return
        }

        let connection = NWConnection(host: endpointHost, port: endpointPort, using: .tcp)
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                self.performHandshake(
                    connection: connection,
                    destinationHost: destinationHost,
                    destinationPort: destinationPort,
                    completion: finish
                )
            case let .failed(error):
                finish(.failure(SOCKS5ConnectorError.connectionFailed(error.localizedDescription)))
            case .cancelled:
                finish(.failure(SOCKS5ConnectorError.connectionFailed("Connection cancelled")))
            default:
                break
            }
        }

        connection.start(queue: queue)
    }

    private func performHandshake(
        connection: NWConnection,
        destinationHost: String,
        destinationPort: UInt16,
        completion: @escaping (Result<any SOCKS5TCPStreaming, Error>) -> Void
    ) {
        connection.send(content: Data([0x05, 0x01, 0x00]), completion: .contentProcessed { error in
            if let error {
                connection.cancel()
                completion(.failure(error))
                return
            }
            self.receiveExact(connection: connection, length: 2) { result in
                switch result {
                case let .failure(error):
                    connection.cancel()
                    completion(.failure(error))
                case let .success(response):
                    guard response.count == 2, response[0] == 0x05, response[1] == 0x00 else {
                        connection.cancel()
                        completion(.failure(SOCKS5ConnectorError.handshakeFailed("Method negotiation rejected")))
                        return
                    }
                    self.sendConnectRequest(
                        connection: connection,
                        destinationHost: destinationHost,
                        destinationPort: destinationPort,
                        completion: completion
                    )
                }
            }
        })
    }

    private func sendConnectRequest(
        connection: NWConnection,
        destinationHost: String,
        destinationPort: UInt16,
        completion: @escaping (Result<any SOCKS5TCPStreaming, Error>) -> Void
    ) {
        guard let request = buildConnectRequest(host: destinationHost, port: destinationPort) else {
            connection.cancel()
            completion(.failure(SOCKS5ConnectorError.invalidDestination))
            return
        }

        connection.send(content: request, completion: .contentProcessed { error in
            if let error {
                connection.cancel()
                completion(.failure(error))
                return
            }

            self.receiveExact(connection: connection, length: 4) { headerResult in
                switch headerResult {
                case let .failure(error):
                    connection.cancel()
                    completion(.failure(error))
                case let .success(header):
                    guard header.count == 4, header[0] == 0x05 else {
                        connection.cancel()
                        completion(.failure(SOCKS5ConnectorError.handshakeFailed("Invalid CONNECT response header")))
                        return
                    }
                    guard header[1] == 0x00 else {
                        connection.cancel()
                        completion(.failure(SOCKS5ConnectorError.handshakeFailed("CONNECT failed with code \(header[1])")))
                        return
                    }
                    let atyp = header[3]
                    self.receiveConnectTail(connection: connection, atyp: atyp) { tailResult in
                        switch tailResult {
                        case let .failure(error):
                            completion(.failure(error))
                        case .success:
                            completion(.success(SOCKS5TCPStream(connection: connection, queue: self.queue)))
                        }
                    }
                }
            }
        })
    }

    private func receiveConnectTail(
        connection: NWConnection,
        atyp: UInt8,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        switch atyp {
        case 0x01:
            receiveExact(connection: connection, length: 6) { completion($0.map { _ in () }) }
        case 0x04:
            receiveExact(connection: connection, length: 18) { completion($0.map { _ in () }) }
        case 0x03:
            receiveExact(connection: connection, length: 1) { lengthResult in
                switch lengthResult {
                case let .failure(error):
                    completion(.failure(error))
                case let .success(lengthData):
                    guard let domainLength = lengthData.first else {
                        completion(.failure(SOCKS5ConnectorError.handshakeFailed("Missing domain length")))
                        return
                    }
                    self.receiveExact(connection: connection, length: Int(domainLength) + 2) { completion($0.map { _ in () }) }
                }
            }
        default:
            completion(.failure(SOCKS5ConnectorError.handshakeFailed("Unsupported ATYP in response")))
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
                    completion(.failure(SOCKS5ConnectorError.handshakeFailed("Connection closed during read")))
                    return
                }
                receiveStep()
            }
        }
        receiveStep()
    }

    private func buildConnectRequest(host: String, port: UInt16) -> Data? {
        var bytes = Data([0x05, 0x01, 0x00])

        if let ipv4 = ipv4Bytes(host) {
            bytes.append(0x01)
            bytes.append(ipv4)
        } else if let ipv6 = ipv6Bytes(host) {
            bytes.append(0x04)
            bytes.append(ipv6)
        } else {
            guard let hostData = host.data(using: .utf8), hostData.count <= 255 else { return nil }
            bytes.append(0x03)
            bytes.append(UInt8(hostData.count))
            bytes.append(hostData)
        }

        bytes.append(UInt8((port >> 8) & 0xFF))
        bytes.append(UInt8(port & 0xFF))
        return bytes
    }

    private func ipv4Bytes(_ host: String) -> Data? {
        var addr = in_addr()
        let result = host.withCString { inet_pton(AF_INET, $0, &addr) }
        guard result == 1 else { return nil }
        return withUnsafeBytes(of: addr) { Data($0) }
    }

    private func ipv6Bytes(_ host: String) -> Data? {
        var addr = in6_addr()
        let result = host.withCString { inet_pton(AF_INET6, $0, &addr) }
        guard result == 1 else { return nil }
        return withUnsafeBytes(of: addr) { Data($0) }
    }
}
