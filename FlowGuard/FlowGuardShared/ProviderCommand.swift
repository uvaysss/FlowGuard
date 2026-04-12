import Foundation

enum ProviderCommandAction: String, Codable, Sendable {
    case reloadProfile
    case collectStats
    case exportLogs
}

struct ProviderCommand: Codable, Sendable {
    var action: ProviderCommandAction
}
