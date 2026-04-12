import Foundation

enum ProviderState: String, Codable, Sendable {
    case disconnected
    case starting
    case running
    case stopping
    case failed
}
