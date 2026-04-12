import Foundation

enum AppGroupPaths {
    static let groupIdentifier = "group.io.jawziyya.flowguard"
    static let useAppGroupContainer = false
    static let profileFileName = "tunnel-profile.json"
    static let logsFileName = "runtime.log"
    static let stateFileName = "runtime-state.json"

    static func containerURL(fileManager: FileManager = .default) throws -> URL {
        if useAppGroupContainer,
           let appGroupURL = fileManager.containerURL(
               forSecurityApplicationGroupIdentifier: groupIdentifier
           ) {
            return appGroupURL
        }
        return try fileManager.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
    }

    static func profileURL() throws -> URL {
        try containerURL().appendingPathComponent(profileFileName)
    }

    static func logsURL() throws -> URL {
        try containerURL().appendingPathComponent(logsFileName)
    }

    static func stateURL() throws -> URL {
        try containerURL().appendingPathComponent(stateFileName)
    }

    static func write<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(value)
        try data.write(to: url, options: .atomic)
    }

    static func read<T: Decodable>(_ type: T.Type, from url: URL) throws -> T {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(type, from: data)
    }

    static func readIfExists<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        return try? read(type, from: url)
    }

    static func appendLog(_ line: String) throws {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let payload = "[\(timestamp)] \(line)\n"
        let url = try logsURL()

        if FileManager.default.fileExists(atPath: url.path) {
            let handle = try FileHandle(forWritingTo: url)
            try handle.seekToEnd()
            if let data = payload.data(using: .utf8) {
                try handle.write(contentsOf: data)
            }
            try handle.close()
        } else if let data = payload.data(using: .utf8) {
            try data.write(to: url, options: .atomic)
        }
    }

    static func readLogPreview(maxBytes: Int = 8_192) -> String {
        guard
            let url = try? logsURL(),
            let data = try? Data(contentsOf: url)
        else {
            return "No logs yet."
        }

        if data.count <= maxBytes {
            return String(decoding: data, as: UTF8.self)
        }

        let tail = data.suffix(maxBytes)
        return String(decoding: tail, as: UTF8.self)
    }

    static func persistState(_ state: ProviderState, stats: RuntimeStats) {
        let snapshot = RuntimeSnapshot(
            state: state,
            stats: stats,
            updatedAt: Date()
        )
        guard let url = try? stateURL() else {
            return
        }
        try? write(snapshot, to: url)
    }

    static func readRuntimeSnapshot() -> RuntimeSnapshot? {
        guard let url = try? stateURL() else {
            return nil
        }
        return readIfExists(RuntimeSnapshot.self, from: url)
    }
}

struct RuntimeSnapshot: Codable, Sendable {
    var state: ProviderState
    var stats: RuntimeStats
    var updatedAt: Date
}
