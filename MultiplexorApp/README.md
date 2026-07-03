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
