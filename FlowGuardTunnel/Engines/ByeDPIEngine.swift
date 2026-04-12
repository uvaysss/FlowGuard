import Darwin
import Foundation

protocol ByeDPIEngine {
    func start(arguments: [String], socksPort: Int, onExit: @escaping (Int32) -> Void) throws
    func stop() throws
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
    private var isRunning = false

    func start(arguments: [String], socksPort: Int, onExit: @escaping (Int32) -> Void) throws {
        guard (1...65535).contains(socksPort) else {
            throw ByeDPIEngineError.invalidPort
        }

        guard let mainFunction = Self.resolveMainFunction() else {
            throw ByeDPIEngineError.missingEntryPoint
        }

        stateLock.lock()
        guard !isRunning else {
            stateLock.unlock()
            throw ByeDPIEngineError.alreadyRunning
        }
        isRunning = true
        stateLock.unlock()

        let launchArguments = ["ciadpi", "-i", "127.0.0.1", "-p", "\(socksPort)", "-x", "2"] + arguments

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let exitCode = Self.callMain(mainFunction, with: launchArguments)
            self?.stateLock.lock()
            self?.isRunning = false
            self?.stateLock.unlock()
            onExit(exitCode)
        }
    }

    func stop() throws {
        Self.callStopHookIfAvailable()
        stateLock.lock()
        isRunning = false
        stateLock.unlock()
    }

    func forceStop() {
        Self.callStopHookIfAvailable()
        stateLock.lock()
        isRunning = false
        stateLock.unlock()
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
    private(set) var isRunning = false

    func start(arguments: [String], socksPort: Int, onExit: @escaping (Int32) -> Void) throws {
        guard (1...65535).contains(socksPort) else {
            throw ByeDPIEngineError.invalidPort
        }
        _ = arguments
        isRunning = true
        onExit(0)
    }

    func stop() throws {
        isRunning = false
    }

    func forceStop() {
        isRunning = false
    }
}
