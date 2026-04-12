import Foundation

struct ProviderMessage: Codable, Sendable {
    enum Kind: String, Codable, Sendable {
        case ok
        case stats
        case logs
        case state
        case error
    }

    var kind: Kind
    var description: String?
    var state: ProviderState?
    var stats: RuntimeStats?
    var logs: String?

    static func ok(_ description: String) -> ProviderMessage {
        ProviderMessage(kind: .ok, description: description, state: nil, stats: nil, logs: nil)
    }

    static func error(_ description: String) -> ProviderMessage {
        ProviderMessage(kind: .error, description: description, state: nil, stats: nil, logs: nil)
    }
}
