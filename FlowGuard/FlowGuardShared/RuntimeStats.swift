import Foundation

struct RuntimeStats: Codable, Sendable {
    var uptimeSeconds: TimeInterval
    var bytesIn: Int64
    var bytesOut: Int64
    var selectedPreset: ByeDPIPreset
    var lastError: String?

    static let empty = RuntimeStats(
        uptimeSeconds: 0,
        bytesIn: 0,
        bytesOut: 0,
        selectedPreset: .balanced,
        lastError: nil
    )
}
