import Foundation

enum TunnelImplementationMode: String, Codable, Sendable {
    case legacyTunFD
    case packetFlowExperimental
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

        return .legacyTunFD
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
