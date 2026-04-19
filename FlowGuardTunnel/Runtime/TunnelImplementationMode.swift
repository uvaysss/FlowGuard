import Foundation

enum TunnelImplementationMode: String, Codable, Sendable {
    case packetFlowPreferred

    init(from decoder: Decoder) throws {
        _ = try? decoder.singleValueContainer().decode(String.self)
        self = .packetFlowPreferred
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(TunnelImplementationMode.packetFlowPreferred.rawValue)
    }
}
