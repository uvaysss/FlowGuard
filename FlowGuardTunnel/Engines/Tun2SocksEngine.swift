import Darwin
import Foundation

protocol Tun2SocksEngine {
    func start(config: TunnelProfile, tunFD: Int32, onExit: @escaping (Int32) -> Void) throws
    func stop() throws
}

enum Tun2SocksEngineError: LocalizedError {
    case invalidFileDescriptor
    case alreadyRunning
    case missingEntryPoint

    var errorDescription: String? {
        switch self {
        case .invalidFileDescriptor:
            return "Invalid TUN file descriptor."
        case .alreadyRunning:
            return "tun2socks is already running."
        case .missingEntryPoint:
            return "Missing hev_socks5_tunnel_main_from_str symbol. Ensure hev-socks5-tunnel is linked."
        }
    }
}

final class NativeTun2SocksEngine: Tun2SocksEngine {
    private let stateLock = NSLock()
    private var isRunning = false

    func start(config: TunnelProfile, tunFD: Int32, onExit: @escaping (Int32) -> Void) throws {
        guard tunFD >= 0 else {
            throw Tun2SocksEngineError.invalidFileDescriptor
        }

        guard let mainFunction = Self.resolveMainFunction() else {
            throw Tun2SocksEngineError.missingEntryPoint
        }

        stateLock.lock()
        guard !isRunning else {
            stateLock.unlock()
            throw Tun2SocksEngineError.alreadyRunning
        }
        isRunning = true
        stateLock.unlock()

        let yamlConfig = Self.makeInlineConfig(config: config)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            yamlConfig.withCString { rawConfig in
                let exitCode = mainFunction(rawConfig, Int32(strlen(rawConfig)), tunFD)
                onExit(exitCode)
            }
            self?.stateLock.lock()
            self?.isRunning = false
            self?.stateLock.unlock()
        }
    }

    func stop() throws {
        Self.callQuitIfAvailable()
        stateLock.lock()
        isRunning = false
        stateLock.unlock()
    }

    private static func makeInlineConfig(config: TunnelProfile) -> String {
        var yaml = """
        tunnel:
          mtu: 8500
          ipv4: 198.18.0.1
        """

        if config.ipv6Enabled {
            yaml += "\n  ipv6: 'fd6e:a81b:704f:1211::1'"
        }

        yaml += """

        socks5:
          port: \(config.socksPort)
          address: '127.0.0.1'
          udp: 'udp'
        misc:
          task-stack-size: 24576
          tcp-buffer-size: 4096
          log-level: debug
        """

        return yaml
    }

    private static func callQuitIfAvailable() {
        guard let symbol = dlsym(currentExecutableHandle(), "hev_socks5_tunnel_quit") else {
            return
        }

        typealias QuitFunction = @convention(c) () -> Void
        let quit = unsafeBitCast(symbol, to: QuitFunction.self)
        quit()
    }

    private static func resolveMainFunction() -> HevMainFunction? {
        guard let symbol = dlsym(currentExecutableHandle(), "hev_socks5_tunnel_main_from_str") else {
            return nil
        }

        return unsafeBitCast(symbol, to: HevMainFunction.self)
    }

    private static func currentExecutableHandle() -> UnsafeMutableRawPointer? {
        dlopen(nil, RTLD_NOW)
    }
}

private typealias HevMainFunction = @convention(c) (UnsafePointer<CChar>?, Int32, Int32) -> Int32

final class StubTun2SocksEngine: Tun2SocksEngine {
    private(set) var isRunning = false

    func start(config: TunnelProfile, tunFD: Int32, onExit: @escaping (Int32) -> Void) throws {
        guard tunFD >= 0 else {
            throw Tun2SocksEngineError.invalidFileDescriptor
        }
        _ = config
        isRunning = true
        onExit(0)
    }

    func stop() throws {
        isRunning = false
    }
}
