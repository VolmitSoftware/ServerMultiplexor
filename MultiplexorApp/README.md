# Multiplexor CLI (Dart)

Dart-native manager for this workspace. `../start.sh` is the canonical entrypoint.
The repo-root `../README.md` is the user-facing command reference; update it
with any command-surface or help text changes.

## Run In Dev

```bash
cd MultiplexorApp
dart pub get
dart run bin/main.dart
```

## Build Executable

```bash
cd MultiplexorApp
dart run tool/build_exe.dart
```

Default output is `../multiplexor`.

## Notes

- Workspace root detection is location-agnostic.
- Running in an empty folder bootstraps the required workspace layout.
- Command execution is native Dart (no shell backend).
- The no-argument monitor has Local and Pterodactyl Remote tabs. Remote
  profile metadata is non-secret; API keys are origin-bound and resolved from
  macOS Keychain (or an origin-paired environment variable for CI).
- `remote`/`ptero` provides headless verification, inventory, all allocation
  endpoints, node capacity, resource statistics, power actions, a secure live
  console plus one-shot commands, and template-based server creation over the
  same service used by the TUI.
- `tool/mineflayer/` is the pinned Node 22 gameplay harness used by the
  `gameplay` CLI namespace. Install it through `../start.sh gameplay setup`;
  each run publishes its loopback Prismarine Viewer URL in terminal output,
  the JSON report, and an immediate viewer-state artifact. Dependencies and
  generated reports stay in ignored consumer state.
