import Foundation

enum SharedStoreError: LocalizedError {
    case appGroupContainerUnavailable(String)
    case failedToResolveDocumentsDirectory

    var errorDescription: String? {
        switch self {
        case let .appGroupContainerUnavailable(groupIdentifier):
            return "Shared app group container is unavailable for \(groupIdentifier)."
        case .failedToResolveDocumentsDirectory:
            return "Failed to resolve Documents directory for fallback storage."
        }
    }
}

enum SharedStoreLocationPolicy: Sendable {
    case appGroupOnly
    case appGroupOrDocumentsFallback
}

protocol TunnelConfigurationStore: Sendable {
    func loadProfile() throws -> TunnelProfile?
    func saveProfile(_ profile: TunnelProfile) throws
}

protocol RuntimeSnapshotStore: Sendable {
    func loadRuntimeSnapshot() throws -> RuntimeSnapshot?
    func persistRuntimeSnapshot(state: ProviderState, stats: RuntimeStats) throws
}

protocol RuntimeLogStore: Sendable {
    func appendRuntimeLog(_ line: String) throws
    func readRuntimeLogPreview(maxBytes: Int) throws -> String
}

final class SharedContainerStore: TunnelConfigurationStore, RuntimeSnapshotStore, RuntimeLogStore, @unchecked Sendable {
    private enum LogRetention {
        static let maxFileBytes = 512 * 1024
    }

    private let fileManager: FileManager
    private let groupIdentifier: String
    private let locationPolicy: SharedStoreLocationPolicy
    private let profileFileName: String
    private let logsFileName: String
    private let stateFileName: String
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let logWriteLock = NSLock()

    init(
        fileManager: FileManager = .default,
        groupIdentifier: String = AppGroupPaths.groupIdentifier,
        locationPolicy: SharedStoreLocationPolicy = .appGroupOnly,
        profileFileName: String = AppGroupPaths.profileFileName,
        logsFileName: String = AppGroupPaths.logsFileName,
        stateFileName: String = AppGroupPaths.stateFileName
    ) {
        self.fileManager = fileManager
        self.groupIdentifier = groupIdentifier
        self.locationPolicy = locationPolicy
        self.profileFileName = profileFileName
        self.logsFileName = logsFileName
        self.stateFileName = stateFileName
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    }

    func loadProfile() throws -> TunnelProfile? {
        try readIfExists(TunnelProfile.self, from: profileURL())
    }

    func saveProfile(_ profile: TunnelProfile) throws {
        try write(profile, to: profileURL())
    }

    func loadRuntimeSnapshot() throws -> RuntimeSnapshot? {
        try readIfExists(RuntimeSnapshot.self, from: stateURL())
    }

    func persistRuntimeSnapshot(state: ProviderState, stats: RuntimeStats) throws {
        let snapshot = RuntimeSnapshot(
            state: state,
            stats: stats,
            updatedAt: Date()
        )
        try write(snapshot, to: stateURL())
    }

    func appendRuntimeLog(_ line: String) throws {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let payload = "[\(timestamp)] \(line)\n"
        guard let payloadData = payload.data(using: .utf8) else {
            return
        }
        let url = try logsURL()

        logWriteLock.lock()
        defer { logWriteLock.unlock() }

        let existingData = (try? Data(contentsOf: url)) ?? Data()
        let combinedData = retainedLogData(existingData: existingData, newEntry: payloadData)
        try combinedData.write(to: url, options: .atomic)
    }

    func readRuntimeLogPreview(maxBytes: Int = 8_192) throws -> String {
        let url = try logsURL()
        guard fileManager.fileExists(atPath: url.path) else {
            return "No logs yet."
        }

        let data = try Data(contentsOf: url)
        if data.count <= maxBytes {
            return String(decoding: data, as: UTF8.self)
        }

        return String(decoding: data.suffix(maxBytes), as: UTF8.self)
    }

    func profileURL() throws -> URL {
        try containerURL().appendingPathComponent(profileFileName)
    }

    func logsURL() throws -> URL {
        try containerURL().appendingPathComponent(logsFileName)
    }

    func stateURL() throws -> URL {
        try containerURL().appendingPathComponent(stateFileName)
    }

    func containerURL() throws -> URL {
        if let appGroupURL = fileManager.containerURL(
            forSecurityApplicationGroupIdentifier: groupIdentifier
        ) {
            return appGroupURL
        }

        switch locationPolicy {
        case .appGroupOnly:
            throw SharedStoreError.appGroupContainerUnavailable(groupIdentifier)
        case .appGroupOrDocumentsFallback:
            return try fileManager.url(
                for: .documentDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
        }
    }

    private func retainedLogData(existingData: Data, newEntry: Data) -> Data {
        let maxBytes = LogRetention.maxFileBytes
        guard maxBytes > 0 else {
            return newEntry
        }

        if newEntry.count >= maxBytes {
            return Data(newEntry.suffix(maxBytes))
        }

        let allowedExistingCount = maxBytes - newEntry.count
        let existingTail = existingData.suffix(max(0, allowedExistingCount))
        var output = Data(capacity: existingTail.count + newEntry.count)
        output.append(existingTail)
        output.append(newEntry)
        return output
    }

    func write<T: Encodable>(_ value: T, to url: URL) throws {
        let data = try encoder.encode(value)
        try data.write(to: url, options: .atomic)
    }

    func read<T: Decodable>(_ type: T.Type, from url: URL) throws -> T {
        let data = try Data(contentsOf: url)
        return try decoder.decode(type, from: data)
    }

    func readIfExists<T: Decodable>(_ type: T.Type, from url: URL) throws -> T? {
        guard fileManager.fileExists(atPath: url.path) else {
            return nil
        }
        return try read(type, from: url)
    }
}

enum AppGroupPaths {
    static let groupIdentifier = "group.io.jawziyya.flowguard"
    static let profileFileName = "tunnel-profile.json"
    static let logsFileName = "runtime.log"
    static let stateFileName = "runtime-state.json"

    static func makeSharedStore() -> SharedContainerStore {
        SharedContainerStore(
            locationPolicy: .appGroupOnly
        )
    }

    #if DEBUG
    static func makeDebugSharedStoreWithDocumentsFallback() -> SharedContainerStore {
        SharedContainerStore(locationPolicy: .appGroupOrDocumentsFallback)
    }
    #endif

    static func makeTunnelConfigurationStore() -> TunnelConfigurationStore {
        makeSharedStore()
    }

    static func makeRuntimeSnapshotStore() -> RuntimeSnapshotStore {
        makeSharedStore()
    }

    static func makeRuntimeLogStore() -> RuntimeLogStore {
        makeSharedStore()
    }

    static func containerURL(fileManager: FileManager = .default) throws -> URL {
        try SharedContainerStore(
            fileManager: fileManager,
            locationPolicy: .appGroupOnly
        ).containerURL()
    }

    static func profileURL() throws -> URL {
        try makeSharedStore().profileURL()
    }

    static func logsURL() throws -> URL {
        try makeSharedStore().logsURL()
    }

    static func stateURL() throws -> URL {
        try makeSharedStore().stateURL()
    }

    static func write<T: Encodable>(_ value: T, to url: URL) throws {
        try makeSharedStore().write(value, to: url)
    }

    static func read<T: Decodable>(_ type: T.Type, from url: URL) throws -> T {
        try makeSharedStore().read(type, from: url)
    }

    static func readIfExists<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        try? makeSharedStore().readIfExists(type, from: url)
    }

    static func appendLog(_ line: String) throws {
        try makeSharedStore().appendRuntimeLog(line)
    }

    static func readLogPreview(maxBytes: Int = 8_192) -> String {
        (try? makeSharedStore().readRuntimeLogPreview(maxBytes: maxBytes)) ?? "No logs yet."
    }

    static func persistState(_ state: ProviderState, stats: RuntimeStats) {
        try? makeSharedStore().persistRuntimeSnapshot(state: state, stats: stats)
    }

    static func readRuntimeSnapshot() -> RuntimeSnapshot? {
        try? makeSharedStore().loadRuntimeSnapshot()
    }
}

struct RuntimeSnapshot: Codable, Sendable {
    var state: ProviderState
    var stats: RuntimeStats
    var updatedAt: Date
}
