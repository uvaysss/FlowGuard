# FlowGuard Target Wiring TODO

Source files and scaffolding are in place, but Xcode target wiring still needs to be completed in Xcode UI:

1. Add target `FlowGuardTunnel` (iOS Packet Tunnel Extension).
2. Set extension bundle id to `com.uvays.FlowGuard.FlowGuardTunnel`.
3. Assign extension entitlements file: `FlowGuardTunnel/FlowGuardTunnel.entitlements`.
4. Assign app entitlements file: `FlowGuard/FlowGuard.entitlements`.
5. Add these files to both app and extension compile scopes where needed:
   - `FlowGuard/FlowGuardShared/*.swift`
6. Add these files to extension target only:
   - `FlowGuardTunnel/PacketTunnelProvider.swift`
   - `FlowGuardTunnel/Runtime/TunnelRuntimeCoordinator.swift`
   - `FlowGuardTunnel/Engines/*.swift`
7. Enable App Group capability for both targets with `group.com.uvays.FlowGuard`.
8. Enable Network Extensions capability for extension target (`Packet Tunnel`).
9. Verify `TunnelController.providerBundleIdentifier` matches extension bundle id.
10. Vendor native dependencies:
   - `Vendor/byedpi`
   - `Vendor/hev-socks5-tunnel`
11. Build native artifacts:
   - `scripts/sync-byedpi.sh`
   - `scripts/build-byedpi-apple.sh`
   - `scripts/sync-hev.sh`
   - `scripts/build-hev-apple.sh`
12. Link native artifacts into extension target:
   - ByeDPI static libraries (device + simulator)
   - `HevSocks5Tunnel.xcframework`
13. Ensure extension build can resolve symbols:
   - `ciadpi_main` (ByeDPI built with `-Dmain=ciadpi_main`)
   - `hev_socks5_tunnel_main_from_str`
   - `hev_socks5_tunnel_quit`

## Notes from second pass

- The project uses Xcode's file-system-synchronized format (`PBXFileSystemSynchronizedRootGroup`) and currently has one target only.
- App target deployment + entitlements are now explicitly set in `project.pbxproj` (`IPHONEOS_DEPLOYMENT_TARGET = 16.0`, `CODE_SIGN_ENTITLEMENTS = FlowGuard/FlowGuard.entitlements`).
- Full extension target creation by raw `project.pbxproj` editing was intentionally deferred to Xcode UI to avoid corrupting synchronized-group metadata without schema validation.
- `xcodebuild` cannot be used in this environment until full Xcode is selected (`xcode-select` currently points to Command Line Tools).
- Runtime now expects Rumble-like startup option keys from app to extension:
  - `Args`, `IPv6`, `DNSServer`, `SOCKSPort`
- Runtime uses speed-first `legacyTunFD` (`hev-socks5-tunnel`) by default, with `packetFlowPreferred` retained as compatibility fallback.
