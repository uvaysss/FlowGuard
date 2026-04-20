import Foundation

enum TunnelImplementationMode: String, Codable, Sendable {
    case legacyTunFD
    case packetFlowPreferred

    static let startOptionKey = "flowguard.tunnelImplementationMode"
    static let debugEnvironmentKey = "FLOWGUARD_TUNNEL_IMPLEMENTATION_MODE"

    static func resolve(
        fromStartOptions options: [String: NSObject]?,
        processInfo: ProcessInfo = .processInfo
    ) -> TunnelImplementationMode {
        if let value = stringValue(from: options?[startOptionKey]),
           let mode = TunnelImplementationMode(rawValue: value) {
            return mode
        }

        #if DEBUG
        if let value = processInfo.environment[debugEnvironmentKey],
           let mode = TunnelImplementationMode(rawValue: value) {
            return mode
        }
        #endif

        // Speed-first default: hev/tun-fd path.
        return .legacyTunFD
    }

    init(from decoder: Decoder) throws {
        let value = try? decoder.singleValueContainer().decode(String.self)
        self = TunnelImplementationMode(rawValue: value ?? "") ?? .legacyTunFD
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    private static func stringValue(from object: NSObject?) -> String? {
        switch object {
        case let string as NSString:
            return String(string)
        case let number as NSNumber:
            return number.stringValue
        default:
            return nil
        }
    }
}
