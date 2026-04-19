import Foundation

enum ByeDPIPreset: String, Codable, CaseIterable, Sendable {
    case conservative
    case balanced
    case aggressive
    case forYoutube
    case strategyBasicTorst
    case strategyYoutubeStable
    case strategyLinuxFakeMD5
    case strategyWindowsSplitFake

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
        case .strategyBasicTorst:
            return [
                "--disorder", "1",
                "--tlsrec", "1+s",
                "--auto", "torst",
                "--timeout", "3"
            ]
        case .strategyYoutubeStable:
            return [
                "--split", "1",
                "--disoob", "3",
                "--disorder", "7",
                "--fake", "-1",
                "--tlsrec", "3+h",
                "--mod-http", "h,d,r",
                "--auto", "none",
                "--timeout", "3",
                "--no-udp"
            ]
        case .strategyLinuxFakeMD5:
            return [
                "--fake", "-1",
                "--md5sig",
                "--ttl", "8",
                "--auto", "torst",
                "--timeout", "3"
            ]
        case .strategyWindowsSplitFake:
            return [
                "--split", "1+s",
                "--disorder", "3+s",
                "--fake", "-1",
                "--ttl", "6",
                "--auto", "torst",
                "--timeout", "3"
            ]
        }
    }
}
