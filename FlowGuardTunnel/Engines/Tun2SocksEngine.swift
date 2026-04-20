import Darwin
import Foundation

protocol Tun2SocksEngine {
    func start(config: TunnelProfile, tunFD: Int32, onExit: @escaping (Int32) -> Void) throws
    func requestStop() throws
    func waitForExit(timeout: TimeInterval) -> Bool
    func forceStop()
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
    private var lifecycle: Lifecycle = .idle
    private var exitSignal = DispatchSemaphore(value: 0)

    private enum Lifecycle: Equatable {
        case idle
        case starting
        case running
        case stopping
        case exited(Int32)
        case failed(Int32)
    }

    func start(config: TunnelProfile, tunFD: Int32, onExit: @escaping (Int32) -> Void) throws {
        guard tunFD >= 0 else {
            throw Tun2SocksEngineError.invalidFileDescriptor
        }

        guard let mainFunction = Self.resolveMainFunction() else {
            throw Tun2SocksEngineError.missingEntryPoint
        }

        stateLock.lock()
        switch lifecycle {
        case .idle, .exited, .failed:
            lifecycle = .starting
            exitSignal = DispatchSemaphore(value: 0)
        case .starting, .running, .stopping:
            stateLock.unlock()
            throw Tun2SocksEngineError.alreadyRunning
        }
        stateLock.unlock()

        let yamlConfig = Self.makeInlineConfig(config: config)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.updateLifecycle(.running)
            yamlConfig.withCString { rawConfig in
                let exitCode = mainFunction(rawConfig, Int32(strlen(rawConfig)), tunFD)
                self?.finish(exitCode: exitCode)
                onExit(exitCode)
            }
        }
    }

    func requestStop() throws {
        stateLock.lock()
        switch lifecycle {
        case .idle, .exited, .failed:
            stateLock.unlock()
            return
        case .starting, .running, .stopping:
            lifecycle = .stopping
            stateLock.unlock()
        }
        Self.callQuitIfAvailable()
    }

    func waitForExit(timeout: TimeInterval) -> Bool {
        let signal: DispatchSemaphore?
        stateLock.lock()
        switch lifecycle {
        case .idle, .exited, .failed:
            signal = nil
        case .starting, .running, .stopping:
            signal = exitSignal
        }
        stateLock.unlock()

        guard let signal else {
            return true
        }
        return signal.wait(timeout: .now() + timeout) == .success
    }

    func forceStop() {
        stateLock.lock()
        switch lifecycle {
        case .starting, .running, .stopping:
            lifecycle = .stopping
        case .idle, .exited, .failed:
            break
        }
        stateLock.unlock()
        Self.callQuitIfAvailable()
    }

    private func updateLifecycle(_ next: Lifecycle) {
        stateLock.lock()
        lifecycle = next
        stateLock.unlock()
    }

    private func finish(exitCode: Int32) {
        let resolved: Lifecycle = exitCode == 0 ? .exited(exitCode) : .failed(exitCode)
        let signal: DispatchSemaphore
        stateLock.lock()
        lifecycle = resolved
        signal = exitSignal
        stateLock.unlock()
        signal.signal()
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
    private var exitSignal = DispatchSemaphore(value: 0)
    private var lifecycle: Lifecycle = .idle

    private enum Lifecycle {
        case idle
        case running
        case stopping
        case exited
    }

    func start(config: TunnelProfile, tunFD: Int32, onExit: @escaping (Int32) -> Void) throws {
        guard tunFD >= 0 else {
            throw Tun2SocksEngineError.invalidFileDescriptor
        }
        _ = config
        guard lifecycle == .idle || lifecycle == .exited else {
            throw Tun2SocksEngineError.alreadyRunning
        }
        lifecycle = .running
        exitSignal = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.lifecycle = .exited
            self?.exitSignal.signal()
            onExit(0)
        }
    }

    func requestStop() throws {
        switch lifecycle {
        case .idle, .exited:
            return
        case .running, .stopping:
            lifecycle = .stopping
            lifecycle = .exited
            exitSignal.signal()
        }
    }

    func waitForExit(timeout: TimeInterval) -> Bool {
        switch lifecycle {
        case .idle, .exited:
            return true
        case .running, .stopping:
            return exitSignal.wait(timeout: .now() + timeout) == .success
        }
    }

    func forceStop() {
        lifecycle = .exited
        exitSignal.signal()
    }
}
