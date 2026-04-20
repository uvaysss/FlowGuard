# FlowGuard Architecture

## Goals

- Keep the host app thin and focused on orchestration.
- Keep tunnel runtime logic independent from Apple framework glue where possible.
- Isolate infrastructure concerns behind small protocols so runtime behavior can be tested and swapped without rewriting the coordinator.
- Prefer a single production data-plane path over multiple partially-owned paths.

## Target Boundaries

### Host App

- Files: `FlowGuard/Host/*`, `FlowGuard/ContentView.swift`
- Responsibility: install configuration, start/stop tunnel, request stats/logs, present state.
- Rule: host code should not know how the tunnel runtime allocates ports, builds network settings, or manages engines.

### Shared Contract

- Files: `FlowGuard/FlowGuardShared/*`
- Responsibility: provider commands/messages, profiles, presets, storage interfaces, runtime stats.
- Rule: shared types stay portable and free from tunnel implementation details.

### Tunnel Entry

- Files: `FlowGuardTunnel/PacketTunnelProvider.swift`
- Responsibility: bridge `NEPacketTunnelProvider` lifecycle to runtime use cases.
- Rule: provider should wire dependencies and delegate; it should not own startup policy.

### Runtime Core

- Files: `FlowGuardTunnel/Runtime/*`
- Responsibility: coordinate startup/shutdown, state transitions, snapshots, and composition of engines/data planes.
- Rule: `TunnelRuntimeCoordinator` should be an orchestrator, not a grab-bag of socket probing, settings construction, persistence, and logging details.

### Runtime Infrastructure

- Files: `FlowGuardTunnel/Runtime/LocalhostPortAllocator.swift`, `FlowGuardTunnel/Runtime/LocalSocksEndpointMonitor.swift`, `FlowGuardTunnel/Runtime/TunnelNetworkSettingsBuilder.swift`
- Responsibility: network settings construction, local port probing, SOCKS readiness checks.
- Rule: infrastructure details live behind tiny protocols and are injected into the runtime core.

### Engines And Data Plane

- Files: `FlowGuardTunnel/Engines/*`, `FlowGuardTunnel/Runtime/TunnelDataPlane.swift`, `FlowGuardTunnel/Runtime/PacketFlow/*`
- Responsibility: run ByeDPI and move packets through the packet-flow data plane.
- Rule: engines expose lifecycle-oriented interfaces; data planes own packet movement and protocol details.

### Tunnel Path Policy

- Speed-first path: `legacyTunFD` (`hev-socks5-tunnel`) is the default production mode.
- Compatibility path: `packetFlowPreferred` remains available and selectable via start option `flowguard.tunnelImplementationMode`.

## Current SOLID/KISS/DRY Problems

### `TunnelRuntimeCoordinator`

- File: `FlowGuardTunnel/Runtime/TunnelRuntimeCoordinator.swift`
- Problem: owns too many responsibilities at once.
- Migration direction:
  - keep orchestration and state transitions here;
  - keep startup use case orchestration thin by delegating details to focused services;
  - keep stats and lifecycle behavior in dedicated runtime services;
  - keep persistence/state access behind repository/service abstractions.

### `PacketTunnelProvider`

- File: `FlowGuardTunnel/PacketTunnelProvider.swift`
- Problem: still performs some startup policy decisions and low-level wiring inline.
- Migration direction:
  - keep only Apple lifecycle glue;
  - later inject a dedicated provider bootstrap/composition root.

### `TunnelController`

- File: `FlowGuard/Host/TunnelController.swift`
- Problem: mixes manager discovery, manager caching, configuration policy, provider IPC, and connection state waiting.
- Migration direction:
  - split into manager repository, provider messenger, and connection lifecycle service.

### `PacketFlow` subsystem

- Files: `FlowGuardTunnel/Runtime/PacketFlow/*`
- Problem: protocol code is already decomposed into many files, but still lacks a stronger boundary between parsing/state transitions and I/O side effects.
- Migration direction:
  - keep codecs/state machines pure;
  - isolate socket/stream adapters and metrics sinks.

## Migration Plan

1. Extract infrastructure services from `TunnelRuntimeCoordinator` without changing external behavior.
2. Introduce a runtime state repository for snapshot/log persistence so the coordinator no longer writes directly to stores.
3. Extract runtime stats and lifecycle flows from `TunnelRuntimeCoordinator` into dedicated services.
4. Extract startup flow and command handling from `TunnelRuntimeCoordinator` into dedicated services.
5. Split `TunnelController` into manager/configuration and provider messaging services.
6. Move `PacketTunnelProvider` to a composition-root style object graph.
7. Keep a single production data-plane path and simplify runtime composition around it.

## This Iteration

- Completed:
  - extracted `TunnelNetworkSettingsBuilding`;
  - extracted `LocalhostPortAllocating`;
  - extracted `LocalSocksEndpointMonitoring`.
  - extracted runtime persistence into `TunnelRuntimePersistenceService`;
  - extracted runtime state access into `TunnelRuntimeStateRepository`;
  - extracted stats collection into `TunnelRuntimeStatsService`;
  - extracted stop/rollback/engine-exit lifecycle into `TunnelRuntimeLifecycleService`;
  - extracted startup flow into `TunnelRuntimeStartupService`;
  - extracted provider command handling for profile/log commands into `TunnelRuntimeCommandHandlerService`;
  - moved `collectStats` command path into `TunnelRuntimeCommandHandlerService` so coordinator command branch is pure routing;
  - split host controller responsibilities into dedicated `FlowGuard/Host/*Service.swift` files;
  - moved tunnel provider wiring into `PacketTunnelProviderBootstrap`;
  - re-enabled dual data-plane composition with speed-first `legacyTunFD` (hev) and compatibility `packetFlowPreferred`.
- Next best step:
  - split startup flow internally into smaller use-case parts (`select-port`, `apply-network-settings`, `start-engines`) to simplify targeted testing.

## Core Stability Check

- Script: `scripts/core-stability-check.sh`
- Purpose: run repeated stress checks for known sensitive core tests, then run full `FlowGuardCoreTests`.
- Default command:
  - `./scripts/core-stability-check.sh`
- Optional tuning:
  - `REPEAT=30 ./scripts/core-stability-check.sh`
  - `SENSITIVE_TESTS='FlowGuardCoreTests/PacketFlowUDPRelayTests/testUpstreamDatagramCallbackIncrementsRxAndEmitsEvent,FlowGuardCoreTests/PacketFlowIntegrationTests/testTCPSynIngressProducesSynthesizedSynAckEgress' ./scripts/core-stability-check.sh`
  - `INFRA_RETRY_MAX=2 INFRA_RETRY_DELAY_SEC=2 ./scripts/core-stability-check.sh`
- Notes:
  - Uses project/scheme/destination defaults that match current core test runs.
  - Exits `0` on full success, `1` on any failure, and prints per-test and global pass/fail summaries.
  - Per `xcodebuild` invocation, retries are limited (`INFRA_RETRY_MAX`, default `2`) and only used for known simulator/Xcode infrastructure failures.
  - Regular test failures/assertions are never retried.
  - Infra retry signatures include:
    - destination/device not available or not found;
    - `CoreSimulatorService` invalid/lost connection states;
    - simulator device-set bootstrap failures (`Unable to locate device set`, `Failed to initialize simulator device set`, `SimDeviceSet observer` registration failures);
    - `simdiskimaged` / `SimDiskImageManager` instability;
    - common `simctl` device-preparation failures.
  - Summary includes per-sensitive-test counters and infra retry counters for stress runs, full-suite run, total retries, and retried invocation count.
  - CI gate runs this script on `push` and `pull_request` via `.github/workflows/core-stability.yml` with `REPEAT=3` and explicit UDP+TCP sensitive test list.
  - To tune CI sensitivity or duration, change `REPEAT` in workflow env or override it for local runs.

## Runtime A/B Smoke

- Script: `scripts/runtime-ab-smoke.sh`
- Purpose: run `core-stability-check` sequentially for both runtime modes and print side-by-side elapsed time/status summary.
- Default command:
  - `./scripts/runtime-ab-smoke.sh`
- Optional tuning:
  - `REPEAT=5 ./scripts/runtime-ab-smoke.sh`
  - `MODES='legacyTunFD,packetFlowPreferred' ./scripts/runtime-ab-smoke.sh`
- Notes:
  - Uses env `FLOWGUARD_TUNNEL_IMPLEMENTATION_MODE` for each run.
  - This is a smoke A/B comparator (health + rough elapsed time), not a formal throughput benchmark.
