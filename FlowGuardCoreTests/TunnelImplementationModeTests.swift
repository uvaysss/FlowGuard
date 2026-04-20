import XCTest
@testable import FlowGuardTunnel

final class TunnelImplementationModeTests: XCTestCase {
    func testResolveDefaultsToLegacyTunFDWhenNoOptionsProvided() {
        let mode = TunnelImplementationMode.resolve(fromStartOptions: nil)
        XCTAssertEqual(mode, .legacyTunFD)
    }

    func testResolveUsesStartOptionsOverride() {
        let options: [String: NSObject] = [
            TunnelImplementationMode.startOptionKey: TunnelImplementationMode.packetFlowPreferred.rawValue as NSString
        ]

        let mode = TunnelImplementationMode.resolve(fromStartOptions: options)
        XCTAssertEqual(mode, .packetFlowPreferred)
    }

    func testResolveFallsBackToLegacyForUnknownValue() {
        let options: [String: NSObject] = [
            TunnelImplementationMode.startOptionKey: "unknown-mode" as NSString
        ]

        let mode = TunnelImplementationMode.resolve(fromStartOptions: options)
        XCTAssertEqual(mode, .legacyTunFD)
    }
}
