import Foundation

enum ByeDPIPreset: String, Codable, CaseIterable, Sendable {
    case conservative
    case balanced
    case aggressive
    case forYoutube

    var arguments: [String] {
        switch self {
        case .conservative:
            return []
        case .balanced:
            return ["--auto", "torst"]
        case .aggressive:
            return [
                "--pf", "443", "--proto", "tls",
                "--disorder", "1", "--split", "-5+se", "--auto", "none",
                "--pf", "80", "--proto", "http", "--auto", "none"
            ]
        case .forYoutube:
            return ["--split", "1"]
        }
    }
}
