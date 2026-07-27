#!/usr/bin/env bash
# Runs the compiled multiplexor binary, recompiling it first whenever the Dart
# sources have moved on. This is the only entrypoint the workspace is driven
# through, so it has to keep the binary honest by itself.
#
# Everything this script prints goes to stderr: stdout belongs to the command
# being run, and machine-readable output (`build cache-info`, `instance
# isolated`, ...) is parsed by callers.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_DIR="$ROOT_DIR/MultiplexorApp"
EXE="$ROOT_DIR/multiplexor"

cd "$ROOT_DIR"

log() {
  printf '[start.sh] %s\n' "$1" >&2
}

# True when the binary is missing or any build input is newer than it.
needs_build() {
  [[ -n "${MULTIPLEXOR_REBUILD:-}" ]] && return 0
  [[ -x "$EXE" ]] || return 0

  local manifest
  for manifest in "$APP_DIR/pubspec.yaml" "$APP_DIR/pubspec.lock"; do
    [[ -f "$manifest" && "$manifest" -nt "$EXE" ]] && return 0
  done

  # Restricted to *.dart so a stray .DS_Store cannot trigger a 20s recompile.
  local newer
  newer="$(find "$APP_DIR/lib" "$APP_DIR/bin" "$APP_DIR/tool" \
    -name '*.dart' -newer "$EXE" -print -quit 2>/dev/null)"
  [[ -n "$newer" ]] && return 0

  return 1
}

build() {
  if ! command -v dart >/dev/null 2>&1; then
    log 'dart is not on PATH; cannot compile multiplexor.'
    log 'Install the Dart SDK, or run an existing binary directly.'
    exit 127
  fi

  if [[ ! -f "$APP_DIR/.dart_tool/package_config.json" ]] ||
    [[ "$APP_DIR/pubspec.yaml" -nt "$APP_DIR/.dart_tool/package_config.json" ]]; then
    log 'Resolving dependencies'
    (cd "$APP_DIR" && dart pub get >&2)
  fi

  # Compile beside the target and move it into place only on success, so a
  # failed build can never leave a truncated binary that then looks newer than
  # its own sources and gets run forever.
  local staging="$EXE.building.$$"
  trap 'rm -f "$staging"' EXIT INT TERM
  log 'Sources changed; compiling multiplexor'
  if ! (cd "$APP_DIR" && dart run tool/build_exe.dart --output "$staging" >&2); then
    log 'Build failed; not replacing the existing binary.'
    exit 1
  fi
  mv -f "$staging" "$EXE"
  chmod +x "$EXE"
  trap - EXIT INT TERM
  log 'Build complete'
}

if needs_build; then
  build
fi

exec "$EXE" "$@"
