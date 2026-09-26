#!/usr/bin/env bash
# Runs the compiled multiplexor binary, recompiling it first whenever the Dart
# sources have moved on, and installing the outside tools the workspace needs
# before either. PowerShell users can run start.ps1; both launchers keep the
# compiled binary current before running a command.
#
# `./start.sh bootstrap` installs everything up front instead of on demand.
# MULTIPLEXOR_NO_BOOTSTRAP=1 skips the dependency step entirely.
#
# Everything this script prints goes to stderr: stdout belongs to the command
# being run, and machine-readable output (`build cache-info`, `instance
# isolated`, ...) is parsed by callers.
set -euo pipefail

case "$OSTYPE" in
  msys* | cygwin*) export PATH="/usr/bin:$PATH" ;;
esac

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_DIR="$ROOT_DIR/MultiplexorApp"
EXE="$ROOT_DIR/multiplexor"

HARNESS_DIR="$APP_DIR/tool/mineflayer"

cd "$ROOT_DIR"

log() {
  printf '[start.sh] %s\n' "$1" >&2
}

warn() {
  printf '[start.sh] warning: %s\n' "$1" >&2
}

# ─── Dependencies ──────────────────────────────────────────────────────────

is_windows() {
  case "$(uname -s)" in
    MINGW* | MSYS* | CYGWIN*) return 0 ;;
    *) return 1 ;;
  esac
}

if is_windows; then
  EXE="$ROOT_DIR/multiplexor.exe"
fi

resolve_dart() {
  local executable sdk_bin
  executable="$(command -v dart)" || return 1
  sdk_bin="$(dirname "$executable")/cache/dart-sdk/bin"
  if [[ -x "$sdk_bin/dart.exe" ]]; then
    printf '%s\n' "$sdk_bin/dart.exe"
  elif [[ -x "$sdk_bin/dart" ]]; then
    printf '%s\n' "$sdk_bin/dart"
  else
    printf '%s\n' "$executable"
  fi
}

install_tmux_darwin() {
  if ! command -v brew >/dev/null 2>&1; then
    warn 'tmux is missing and Homebrew is not installed; run: brew install tmux'
    return 1
  fi
  brew install tmux >&2
}

# Only ever non-interactive: a package manager that stops for a password
# would hang the launch, which is worse than saying what to run by hand.
install_tmux_linux() {
  local manager=''
  local -a install=()
  if command -v apt-get >/dev/null 2>&1; then
    manager='apt-get'
    install=(apt-get install -y tmux)
  elif command -v dnf >/dev/null 2>&1; then
    manager='dnf'
    install=(dnf install -y tmux)
  elif command -v pacman >/dev/null 2>&1; then
    manager='pacman'
    install=(pacman -S --noconfirm tmux)
  else
    warn 'tmux is missing; install it with your package manager'
    return 1
  fi

  if [[ "$(id -u)" == '0' ]]; then
    "${install[@]}" >&2
    return
  fi

  if command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
    sudo -n "${install[@]}" >&2
    return
  fi

  warn "tmux is missing; run: sudo ${install[*]} ($manager needs a password)"
  return 1
}

# tmux backs the console panes and the drop-in watchers. Everything else in
# the workspace runs without it, so a failed install warns and steps aside
# rather than stopping the launch.
ensure_tmux() {
  is_windows && return 0
  if command -v tmux >/dev/null 2>&1; then
    return 0
  fi

  log 'tmux is missing; installing it'
  local ok=0
  if [[ "$(uname -s)" == 'Darwin' ]]; then
    install_tmux_darwin || ok=1
  else
    install_tmux_linux || ok=1
  fi

  if [[ "$ok" != '0' ]] || ! command -v tmux >/dev/null 2>&1; then
    warn 'tmux is unavailable; consoles and drop-in watchers will not work'
    return 1
  fi

  log "tmux installed: $(tmux -V)"
}

# The harness is hundreds of megabytes of node_modules that only the gameplay
# commands touch, so it is installed when one of them is actually run.
ensure_harness() {
  [[ -f "$HARNESS_DIR/package.json" ]] || return 0

  local installed_lock="$HARNESS_DIR/node_modules/.package-lock.json"
  if [[ -f "$installed_lock" && -f "$HARNESS_DIR/package-lock.json" ]] &&
    [[ ! "$HARNESS_DIR/package.json" -nt "$installed_lock" ]] &&
    [[ ! "$HARNESS_DIR/package-lock.json" -nt "$installed_lock" ]]; then
    return 0
  fi

  if ! command -v npm >/dev/null 2>&1; then
    warn 'npm is not on PATH; install Node.js to use the gameplay commands'
    return 1
  fi

  log 'Installing the pinned Mineflayer harness dependencies'
  # The tracked lockfile keeps launcher installs and `gameplay setup` on the
  # same dependency versions. npm writes its installed lock after success.
  local -a installer=(npm ci --no-audit --no-fund)

  if ! (cd "$HARNESS_DIR" && "${installer[@]}" >&2); then
    warn 'the Mineflayer harness failed to install; run ./start.sh doctor'
    return 1
  fi
}

# Runtimes big enough that installing them behind the user's back would be a
# surprise, so these are reported instead of fetched.
report_runtimes() {
  command -v java >/dev/null 2>&1 ||
    warn 'java is not on PATH; servers cannot be started (needs JDK 21+)'
  command -v git >/dev/null 2>&1 ||
    warn 'git is not on PATH; `repos sync` will not work'
}

# True when the command being run is a gameplay one. The value after --root
# or --consumer is skipped so a path or profile that happens to be spelled
# `gameplay` cannot trigger a large install on its own.
wants_gameplay() {
  local skip=0 arg
  for arg in "$@"; do
    if [[ "$skip" == '1' ]]; then
      skip=0
      continue
    fi
    case "$arg" in
      --root | --consumer)
        skip=1
        ;;
      gameplay)
        return 0
        ;;
    esac
  done
  return 1
}

ensure_dependencies() {
  [[ -n "${MULTIPLEXOR_NO_BOOTSTRAP:-}" ]] && return 0

  # Every one of these is a check first and an install only on a miss, so the
  # common case costs a handful of PATH lookups.
  ensure_tmux || true
  if wants_gameplay "$@"; then
    ensure_harness || return 1
  fi
  report_runtimes
}

bootstrap() {
  log 'Bootstrapping workspace dependencies'
  ensure_tmux || true
  ensure_harness || return 1
  report_runtimes
  log 'Bootstrap complete'
}

# ─── Build ─────────────────────────────────────────────────────────────────

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
  local dart_executable
  if ! dart_executable="$(resolve_dart)"; then
    log 'dart is not on PATH; cannot compile multiplexor.'
    log 'Install the Dart SDK, or run an existing binary directly.'
    exit 127
  fi

  log 'Resolving dependencies'
  (cd "$APP_DIR" && "$dart_executable" pub get >&2)

  # Compile beside the target and move it into place only on success, so a
  # failed build can never leave a truncated binary that then looks newer than
  # its own sources and gets run forever.
  local staging="$EXE.building.$$"
  if is_windows; then
    staging="$(cygpath -m "$staging")"
  fi
  trap "$(printf 'rm -f -- %q' "$staging")" EXIT INT TERM
  log 'Sources changed; compiling multiplexor'
  if ! (cd "$APP_DIR" && "$dart_executable" run tool/build_exe.dart --output "$staging" >&2); then
    log 'Build failed; not replacing the existing binary.'
    exit 1
  fi
  mv -f "$staging" "$EXE"
  chmod +x "$EXE"
  trap - EXIT INT TERM
  log 'Build complete'
}

# ─── Run ───────────────────────────────────────────────────────────────────

if [[ "${1:-}" == 'bootstrap' ]]; then
  bootstrap
  exit 0
fi

ensure_dependencies "$@"

if needs_build; then
  build
fi

exec "$EXE" "$@"
