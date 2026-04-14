import Foundation

enum ProviderStartOptions {
    static let args = "Args"
    static let ipv6 = "IPv6"
    static let dnsServer = "DNSServer"
    static let socksPort = "SOCKSPort"
    static let preset = "Preset"
    static let tunnelImplementationMode = "flowguard.tunnelImplementationMode"
    static let tunnelImplementationModeEnv = "FLOWGUARD_TUNNEL_IMPLEMENTATION_MODE"

    static func makeDictionary(profile: TunnelProfile) -> [String: NSObject] {
        var options: [String: NSObject] = [
            args: profile.byedpiArguments as NSArray,
            ipv6: NSNumber(value: profile.ipv6Enabled),
            dnsServer: profile.primaryDNSServer as NSString,
            socksPort: NSNumber(value: profile.socksPort),
            preset: profile.preset.rawValue as NSString
        ]

        #if DEBUG
        let debugMode = ProcessInfo.processInfo.environment[tunnelImplementationModeEnv] ?? "packetFlowExperimental"
        options[tunnelImplementationMode] = debugMode as NSString
        #endif

        return options
    }

    static func mergedProfile(from options: [String: NSObject]?, base: TunnelProfile) -> TunnelProfile {
        guard let options else {
            return base
        }

        var profile = base

        if let args = options[Self.args] as? [String], !args.isEmpty {
            profile.customArguments = args
        }

        if let ipv6Value = options[Self.ipv6] as? NSNumber {
            profile.ipv6Enabled = ipv6Value.boolValue
        }

        if let socksPortValue = options[Self.socksPort] as? NSNumber {
            let port = socksPortValue.intValue
            if (1...65535).contains(port) {
                profile.socksPort = port
            }
        }

        if let presetValue = options[Self.preset] as? String,
           let parsedPreset = ByeDPIPreset(rawValue: presetValue) {
            profile.preset = parsedPreset
        }

        if let dns = options[Self.dnsServer] as? String {
            switch dns {
            case "1.1.1.1", "1.0.0.1":
                profile.dnsMode = .doh
            case "8.8.8.8", "8.8.4.4":
                profile.dnsMode = .plain
            default:
                profile.dnsMode = .system
            }
        }

        return profile
    }
}
