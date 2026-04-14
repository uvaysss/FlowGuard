import Darwin
import Foundation

protocol ByeDPIEngine {
    func start(arguments: [String], socksPort: Int, onExit: @escaping (Int32) -> Void) throws
    func requestStop() throws
    func waitForExit(timeout: TimeInterval) -> Bool
    func forceStop()
}

enum ByeDPIEngineError: LocalizedError {
    case invalidPort
    case alreadyRunning
    case missingEntryPoint

    var errorDescription: String? {
        switch self {
        case .invalidPort:
            return "Invalid SOCKS5 port for ByeDPI startup."
        case .alreadyRunning:
            return "ByeDPI is already running."
        case .missingEntryPoint:
            return "Missing ciadpi_main symbol. Ensure ByeDPI static library is linked with -Dmain=ciadpi_main."
        }
    }
}

final class NativeByeDPIEngine: ByeDPIEngine {
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

    func start(arguments: [String], socksPort: Int, onExit: @escaping (Int32) -> Void) throws {
        guard (1...65535).contains(socksPort) else {
            throw ByeDPIEngineError.invalidPort
        }

        guard let mainFunction = Self.resolveMainFunction() else {
            throw ByeDPIEngineError.missingEntryPoint
        }

        stateLock.lock()
        switch lifecycle {
        case .idle, .exited, .failed:
            lifecycle = .starting
            exitSignal = DispatchSemaphore(value: 0)
        case .starting, .running, .stopping:
            stateLock.unlock()
            throw ByeDPIEngineError.alreadyRunning
        }
        stateLock.unlock()

        let launchArguments = ["ciadpi", "-i", "127.0.0.1", "-p", "\(socksPort)", "-x", "2"] + arguments

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.updateLifecycle(.running)
            let exitCode = Self.callMain(mainFunction, with: launchArguments)
            self?.finish(exitCode: exitCode)
            onExit(exitCode)
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
        Self.callStopHookIfAvailable()
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
        Self.callStopHookIfAvailable()
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

    private static func callMain(_ mainFunction: @escaping ByeDPIMainFunction, with arguments: [String]) -> Int32 {
        var cArguments: [UnsafeMutablePointer<CChar>?] = arguments.map { strdup($0) }
        cArguments.append(nil)

        defer {
            for pointer in cArguments where pointer != nil {
                free(pointer)
            }
        }

        return cArguments.withUnsafeMutableBufferPointer { buffer in
            mainFunction(Int32(arguments.count), buffer.baseAddress)
        }
    }

    private static func callStopHookIfAvailable() {
        let stopSymbolNames = ["flowguard_byedpi_stop", "ciadpi_stop", "byedpi_quit"]
        for symbolName in stopSymbolNames {
            if let symbol = dlsym(Self.currentExecutableHandle(), symbolName) {
                typealias StopFunction = @convention(c) () -> Void
                let stop = unsafeBitCast(symbol, to: StopFunction.self)
                stop()
                return
            }
        }
    }

    private static func resolveMainFunction() -> ByeDPIMainFunction? {
        guard let symbol = dlsym(currentExecutableHandle(), "ciadpi_main") else {
            return nil
        }

        return unsafeBitCast(symbol, to: ByeDPIMainFunction.self)
    }

    private static func currentExecutableHandle() -> UnsafeMutableRawPointer? {
        dlopen(nil, RTLD_NOW)
    }
}

private typealias ByeDPIMainFunction = @convention(c) (Int32, UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Int32

final class StubByeDPIEngine: ByeDPIEngine {
    private var exitSignal = DispatchSemaphore(value: 0)
    private var lifecycle: Lifecycle = .idle

    private enum Lifecycle {
        case idle
        case running
        case stopping
        case exited
    }

    func start(arguments: [String], socksPort: Int, onExit: @escaping (Int32) -> Void) throws {
        guard (1...65535).contains(socksPort) else {
            throw ByeDPIEngineError.invalidPort
        }
        _ = arguments
        guard lifecycle == .idle || lifecycle == .exited else {
            throw ByeDPIEngineError.alreadyRunning
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
