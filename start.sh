#!/usr/bin/env bash
# Runs the compiled multiplexor binary, recompiling it first whenever the Dart
# sources have moved on, and installing the outside tools the workspace needs
# before either. This is the only entrypoint the workspace is driven through,
# so it has to keep the binary honest by itself.
#
# `./start.sh bootstrap` installs everything up front instead of on demand.
# MULTIPLEXOR_NO_BOOTSTRAP=1 skips the dependency step entirely.
#
# Everything this script prints goes to stderr: stdout belongs to the command
# being run, and machine-readable output (`build cache-info`, `instance
# isolated`, ...) is parsed by callers.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_DIR="$ROOT_DIR/MultiplexorApp"
EXE="$ROOT_DIR/multiplexor"

# Auto-installed tools live inside the workspace, not on the system: no
# elevation, no package manager, no UAC prompt to hang on, and nothing left
# behind on the machine once the workspace is deleted. .multiplexor/ is
# already ignored by git.
TOOLS_DIR="$ROOT_DIR/.multiplexor/tools"
TOOLS_BIN="$TOOLS_DIR/bin"
TOOLS_CACHE="$TOOLS_DIR/cache"
HARNESS_DIR="$APP_DIR/tool/mineflayer"

# Exported before anything else runs, so this script, the compiler, and the
# binary being exec'd all see the tools installed below.
export PATH="$TOOLS_BIN:$PATH"

cd "$ROOT_DIR"

log() {
  printf '[start.sh] %s\n' "$1" >&2
}

warn() {
  printf '[start.sh] warning: %s\n' "$1" >&2
}

# ─── Dependencies ──────────────────────────────────────────────────────────
#
# Pinned to exact upstream artifacts and checked against their hashes: these
# are executables, so an upstream substitution has to fail the install rather
# than run. MSYS2 and GitHub release files are immutable, so a mismatch means
# something is wrong, not that a version moved on.

MSYS2_REPO='https://repo.msys2.org/msys/x86_64'
TMUX_PKG='tmux-3.5.a-2-x86_64.pkg.tar.zst'
TMUX_SHA256='9ccfb69e157727f0aa475a57f127a6d62ab2235a04d6b1d93f6ce6a6dbd12bbe'
LIBEVENT_PKG='libevent-2.1.12-4-x86_64.pkg.tar.zst'
LIBEVENT_SHA256='c2f087afa1718f5015086bd24afebe21423dbfce2525fd0b3a6b179825ee7904'
ZSTD_URL='https://github.com/facebook/zstd/releases/download/v1.5.6/zstd-v1.5.6-win64.zip'
ZSTD_SHA256='7b4eff6719990e38aca93a4844c2e86a1935090625c4611f7e89675e999c56cc'

is_windows() {
  case "$(uname -s)" in
    MINGW* | MSYS* | CYGWIN*) return 0 ;;
    *) return 1 ;;
  esac
}

verify_sha256() {
  local file="$1" want="$2" got
  got="$(sha256sum "$file" | cut -d' ' -f1)"
  [[ "$got" == "$want" ]]
}

# Downloads to a .part file and only names it on success, so an interrupted
# transfer cannot be mistaken for a cached artifact on the next run.
fetch() {
  local url="$1" dest="$2" want="$3"

  if [[ -f "$dest" ]] && verify_sha256 "$dest" "$want"; then
    return 0
  fi

  command -v curl >/dev/null 2>&1 || {
    warn 'curl is not on PATH; cannot download dependencies'
    return 1
  }

  mkdir -p "$(dirname "$dest")"
  if ! curl -fsSL --retry 2 --connect-timeout 20 -o "$dest.part" "$url"; then
    rm -f "$dest.part"
    warn "download failed: $url"
    return 1
  fi

  if ! verify_sha256 "$dest.part" "$want"; then
    rm -f "$dest.part"
    warn "checksum mismatch, refusing to install: $url"
    return 1
  fi

  mv -f "$dest.part" "$dest"
}

# GNU tar hands .zst archives off to a zstd binary, and Git for Windows does
# not ship one, so unpacking an MSYS2 package needs this first.
ensure_zstd() {
  if command -v zstd >/dev/null 2>&1; then
    return 0
  fi

  command -v unzip >/dev/null 2>&1 || {
    warn 'unzip is not on PATH; cannot unpack zstd'
    return 1
  }

  log 'Installing zstd (needed to unpack the tmux package)'
  fetch "$ZSTD_URL" "$TOOLS_CACHE/zstd.zip" "$ZSTD_SHA256" || return 1

  local work="$TOOLS_CACHE/zstd-unpack"
  rm -rf "$work"
  mkdir -p "$work" "$TOOLS_BIN"
  unzip -q -o "$TOOLS_CACHE/zstd.zip" -d "$work" || return 1

  local found
  found="$(find "$work" -name 'zstd.exe' -print -quit)"
  [[ -n "$found" ]] || {
    warn 'zstd.exe was not in the archive'
    return 1
  }
  cp -f "$found" "$TOOLS_BIN/zstd.exe"
  rm -rf "$work"
  hash -r
}

# tmux has no native Windows build. The MSYS2 one runs against the
# msys-2.0.dll that Git for Windows already ships, which is on PATH inside
# this shell and stays on it for the binary we exec, so only tmux and the
# libevent it links against have to be brought in.
install_tmux_windows() {
  ensure_zstd || return 1

  local work="$TOOLS_CACHE/tmux-unpack"
  rm -rf "$work"
  mkdir -p "$work" "$TOOLS_BIN"

  local entry name sum
  for entry in "$TMUX_PKG:$TMUX_SHA256" "$LIBEVENT_PKG:$LIBEVENT_SHA256"; do
    name="${entry%%:*}"
    sum="${entry##*:}"
    fetch "$MSYS2_REPO/$name" "$TOOLS_CACHE/$name" "$sum" || return 1
    # Only usr/bin: the packages also carry man pages, licences, and headers
    # that nothing here reads.
    tar --zstd -xf "$TOOLS_CACHE/$name" -C "$work" usr/bin || return 1
  done

  cp -f "$work/usr/bin/tmux.exe" "$TOOLS_BIN/" || return 1
  cp -f "$work"/usr/bin/msys-event*.dll "$TOOLS_BIN/" || return 1
  rm -rf "$work"
  hash -r
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
    sudo "${install[@]}" >&2
    return
  fi

  warn "tmux is missing; run: sudo ${install[*]} ($manager needs a password)"
  return 1
}

# tmux backs the console panes and the drop-in watchers. Everything else in
# the workspace runs without it, so a failed install warns and steps aside
# rather than stopping the launch.
ensure_tmux() {
  if command -v tmux >/dev/null 2>&1; then
    return 0
  fi

  log 'tmux is missing; installing it'
  local ok=0
  if is_windows; then
    install_tmux_windows || ok=1
  elif [[ "$(uname -s)" == 'Darwin' ]]; then
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
  [[ -d "$HARNESS_DIR/node_modules" ]] && return 0
  [[ -f "$HARNESS_DIR/package.json" ]] || return 0

  if ! command -v npm >/dev/null 2>&1; then
    warn 'npm is not on PATH; install Node.js to use the gameplay commands'
    return 1
  fi

  log 'Installing the Mineflayer harness (one time, this takes a while)'
  # `npm ci` needs a lockfile and the lockfile is not in the repo, so the
  # first install is a plain one. It writes the lock that later installs —
  # and the app's own `gameplay setup` — can then run reproducibly against.
  local -a installer=(npm install --no-audit --no-fund)
  if [[ -f "$HARNESS_DIR/package-lock.json" ]]; then
    installer=(npm ci --no-audit --no-fund)
  fi

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
    ensure_harness || true
  fi
  report_runtimes
}

bootstrap() {
  log 'Bootstrapping workspace dependencies'
  ensure_tmux || true
  ensure_harness || true
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
