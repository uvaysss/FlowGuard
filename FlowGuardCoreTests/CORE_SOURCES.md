# CoreSources in FlowGuardCoreTests

`FlowGuardCoreTests` currently compiles selected production sources via symlinks.

To keep this maintainable, symlinks are managed by:
- manifest: `FlowGuardCoreTests/core_sources_manifest.tsv`
- sync script: `scripts/sync-core-sources.sh`
- generated symlink directory: `FlowGuardCoreTests/CoreSources/`

## Update flow

1. Edit `core_sources_manifest.tsv`.
2. Run `./scripts/sync-core-sources.sh`.
3. Run `FlowGuardCoreTests`.

This keeps test ownership explicit and avoids manually creating/removing `Core_*.swift` files in the test root.
