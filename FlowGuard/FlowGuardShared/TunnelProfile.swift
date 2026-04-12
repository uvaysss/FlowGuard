import Foundation

enum DNSMode: String, Codable, CaseIterable, Sendable {
    case system
    case doh
    case plain
}

struct TunnelProfile: Codable, Equatable, Sendable {
    var socksPort: Int
    var dnsMode: DNSMode
    var ipv6Enabled: Bool
    var preset: ByeDPIPreset
    var customArguments: [String]

    static let `default` = TunnelProfile(
        socksPort: 1080,
        dnsMode: .system,
        ipv6Enabled: true,
        preset: .balanced,
        customArguments: []
    )

    var byedpiArguments: [String] {
        if !customArguments.isEmpty {
            return customArguments
        }
        return preset.arguments
    }

    var dnsServers: [String] {
        switch dnsMode {
        case .doh:
            return ["1.1.1.1", "1.0.0.1"]
        case .plain:
            return ["8.8.8.8", "8.8.4.4"]
        case .system:
            return ["9.9.9.9", "149.112.112.112"]
        }
    }

    var primaryDNSServer: String {
        dnsServers.first ?? "9.9.9.9"
    }
}
