import Foundation
import NetworkExtension

protocol TunnelNetworkSettingsBuilding {
    func makeNetworkSettings(profile: TunnelProfile) -> NEPacketTunnelNetworkSettings
}

struct DefaultTunnelNetworkSettingsBuilder: TunnelNetworkSettingsBuilding {
    func makeNetworkSettings(profile: TunnelProfile) -> NEPacketTunnelNetworkSettings {
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "254.1.1.1")
        settings.mtu = 9000

        let ipv4 = NEIPv4Settings(addresses: ["198.18.0.1"], subnetMasks: ["255.255.0.0"])
        ipv4.includedRoutes = [NEIPv4Route.default()]
        settings.ipv4Settings = ipv4

        if profile.ipv6Enabled {
            let ipv6 = NEIPv6Settings(
                addresses: ["fd6e:a81b:704f:1211::1"],
                networkPrefixLengths: [64]
            )
            ipv6.includedRoutes = [NEIPv6Route.default()]
            settings.ipv6Settings = ipv6
        }

        settings.dnsSettings = NEDNSSettings(servers: profile.dnsServers)
        return settings
    }
}
