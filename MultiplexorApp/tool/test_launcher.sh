#!/usr/bin/env bash
set -euo pipefail
export PATH="/usr/bin:/bin:$PATH"

REPO_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
TEMP_PARENT="$(cd "${TMPDIR:-/tmp}" && pwd -P)"
TEMP_ROOT="$(mktemp -d "$TEMP_PARENT/multiplexor-launcher.XXXXXX")"
WORKSPACE="$TEMP_ROOT/workspace with spaces"
BIN_DIR="$TEMP_ROOT/bin"
APP_DIR="$WORKSPACE/MultiplexorApp"
HARNESS_DIR="$APP_DIR/tool/mineflayer"
passed=0

cleanup() {
  local resolved
  [[ -d "$TEMP_ROOT" ]] || return 0
  resolved="$(cd "$TEMP_ROOT" && pwd -P)"
  case "$resolved" in
    "$TEMP_PARENT"/multiplexor-launcher.*) rm -rf -- "$resolved" ;;
    *) printf 'Refusing cleanup outside test directory: %s\n' "$resolved" >&2 ;;
  esac
}

trap cleanup EXIT

assert_equal() {
  if [[ "$1" != "$2" ]]; then
    printf 'FAIL: %s (expected <%s>, got <%s>)\n' "$3" "$1" "$2" >&2
    exit 1
  fi
  passed=$((passed + 1))
  printf 'PASS: %s\n' "$3"
}

run_launcher() {
  "$BASH" -c 'OSTYPE=darwin; source "$0" "$@"' "$WORKSPACE/start.sh" "$@" \
    >"$TEMP_ROOT/stdout" 2>"$TEMP_ROOT/stderr"
}

mkdir -p "$BIN_DIR" "$APP_DIR/lib" "$APP_DIR/bin" "$HARNESS_DIR/node_modules"
cp "$REPO_DIR/start.sh" "$WORKSPACE/start.sh"
printf 'name: launcher_fixture\n' >"$APP_DIR/pubspec.yaml"
printf '{}\n' >"$HARNESS_DIR/package.json"
printf '{}\n' >"$HARNESS_DIR/package-lock.json"
printf '{}\n' >"$HARNESS_DIR/node_modules/.package-lock.json"
touch -t 200001010000 "$APP_DIR/pubspec.yaml" "$HARNESS_DIR/package.json" "$HARNESS_DIR/package-lock.json"
touch -t 200101010000 "$HARNESS_DIR/node_modules/.package-lock.json"

export PATH="$BIN_DIR:/usr/bin:/bin"
export FIXTURE_ROOT="$TEMP_ROOT"
export FIXTURE_BIN="$BIN_DIR"
export FIXTURE_APP_TEMPLATE="$TEMP_ROOT/application"
export MULTIPLEXOR_NO_BOOTSTRAP=''
export MULTIPLEXOR_REBUILD=''
export FIXTURE_NPM_EXIT=0
export FIXTURE_DART_EXIT=0
export FIXTURE_APP_EXIT=0

cat >"$BIN_DIR/uname" <<'SH'
#!/usr/bin/env bash
printf 'Darwin\n'
SH

cat >"$BIN_DIR/brew" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$FIXTURE_ROOT/brew.log"
printf '#!/usr/bin/env bash\nprintf "tmux fixture\\n"\n' >"$FIXTURE_BIN/tmux"
chmod +x "$FIXTURE_BIN/tmux"
SH

cat >"$BIN_DIR/npm" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$FIXTURE_ROOT/npm.log"
[[ "$FIXTURE_NPM_EXIT" == 0 ]] || exit "$FIXTURE_NPM_EXIT"
mkdir -p node_modules
printf '{}\n' >node_modules/.package-lock.json
SH

cat >"$TEMP_ROOT/dart" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$0 $*" >>"$FIXTURE_ROOT/dart.log"
[[ "$1" == pub ]] && exit 0
[[ "$1" == run && "$3" == --output ]] || exit 28
if [[ "$FIXTURE_DART_EXIT" != 0 ]]; then
  printf 'partial binary\n' >"$4"
  exit "$FIXTURE_DART_EXIT"
fi
cp "$FIXTURE_APP_TEMPLATE" "$4"
SH

cat >"$FIXTURE_APP_TEMPLATE" <<'SH'
#!/usr/bin/env bash
printf '%s\0' "$@" >"$FIXTURE_ROOT/arguments"
printf 'fixture application\n'
exit "$FIXTURE_APP_EXIT"
SH

cat >"$TEMP_ROOT/forbidden" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$0" >>"$FIXTURE_ROOT/forbidden.log"
exit 90
SH

for tool in cygpath curl unzip tar sha256sum zstd; do
  cp "$TEMP_ROOT/forbidden" "$BIN_DIR/$tool"
done
for tool in java git tmux; do
  printf '#!/usr/bin/env bash\nexit 0\n' >"$BIN_DIR/$tool"
done
cp "$TEMP_ROOT/dart" "$BIN_DIR/dart"
cp "$FIXTURE_APP_TEMPLATE" "$WORKSPACE/multiplexor"
chmod +x "$BIN_DIR"/* "$WORKSPACE/multiplexor" "$FIXTURE_APP_TEMPLATE"

printf 'Darwin launcher simulation using Bash %s\n' "$BASH_VERSION"
expected_args=(--command '/tellraw @s {"text":"ready"}' '' 'directory with spaces/' 'trailing\')
run_launcher "${expected_args[@]}"
printf '%s\0' "${expected_args[@]}" >"$TEMP_ROOT/expected-arguments"
cmp "$TEMP_ROOT/expected-arguments" "$TEMP_ROOT/arguments"
assert_equal 'fixture application' "$(cat "$TEMP_ROOT/stdout")" 'existing extensionless binary preserves arguments'
assert_equal 'absent' "$([[ -f "$TEMP_ROOT/dart.log" ]] && printf present || printf absent)" 'existing binary does not rebuild without pubspec.lock'

rm "$BIN_DIR/tmux"
run_launcher --version
assert_equal 'install tmux' "$(cat "$TEMP_ROOT/brew.log")" 'missing Darwin tmux installs through Homebrew'

run_launcher gameplay doctor
assert_equal 'absent' "$([[ -f "$TEMP_ROOT/npm.log" ]] && printf present || printf absent)" 'fresh installed lock skips npm'
rm "$HARNESS_DIR/node_modules/.package-lock.json"
run_launcher gameplay doctor
assert_equal 'ci --no-audit --no-fund' "$(cat "$TEMP_ROOT/npm.log")" 'missing installed lock uses npm ci'
rm "$TEMP_ROOT/npm.log"
touch -t 200001010000 "$HARNESS_DIR/node_modules/.package-lock.json"
touch -t 200201010000 "$HARNESS_DIR/package-lock.json"
run_launcher gameplay doctor
assert_equal 'ci --no-audit --no-fund' "$(cat "$TEMP_ROOT/npm.log")" 'changed package lock refreshes npm dependencies'

MULTIPLEXOR_REBUILD=1 run_launcher --version
assert_equal "$BIN_DIR/dart pub get
$BIN_DIR/dart run tool/build_exe.dart --output $WORKSPACE/multiplexor.building.$(sed -n 's/.*multiplexor\.building\.//p' "$TEMP_ROOT/dart.log")" "$(cat "$TEMP_ROOT/dart.log")" 'standalone Dart resolves packages and compiles beside the binary'
rm "$TEMP_ROOT/dart.log"
mkdir -p "$BIN_DIR/cache/dart-sdk/bin"
cp "$TEMP_ROOT/dart" "$BIN_DIR/cache/dart-sdk/bin/dart"
chmod +x "$BIN_DIR/cache/dart-sdk/bin/dart"
cp "$TEMP_ROOT/forbidden" "$BIN_DIR/dart"
MULTIPLEXOR_REBUILD=1 run_launcher --version
assert_equal "$BIN_DIR/cache/dart-sdk/bin/dart pub get
$BIN_DIR/cache/dart-sdk/bin/dart run tool/build_exe.dart --output $WORKSPACE/multiplexor.building.$(sed -n 's/.*multiplexor\.building\.//p' "$TEMP_ROOT/dart.log")" "$(cat "$TEMP_ROOT/dart.log")" 'Flutter uses its cached Dart SDK'

cp "$WORKSPACE/multiplexor" "$TEMP_ROOT/binary-before"
failure=0
FIXTURE_DART_EXIT=29 MULTIPLEXOR_REBUILD=1 run_launcher --version || failure=$?
cmp "$TEMP_ROOT/binary-before" "$WORKSPACE/multiplexor"
assert_equal 1 "$failure" 'failed compile returns failure and preserves the previous binary'
assert_equal '' "$(find "$WORKSPACE" -name 'multiplexor.building.*' -print)" 'failed compile removes its staging binary'

rm "$HARNESS_DIR/node_modules/.package-lock.json" "$TEMP_ROOT/arguments"
failure=0
FIXTURE_NPM_EXIT=31 run_launcher gameplay doctor || failure=$?
assert_equal 1 "$failure" 'failed npm install stops gameplay launch'
assert_equal absent "$([[ -f "$TEMP_ROOT/arguments" ]] && printf present || printf absent)" 'failed install never executes the binary'
failure=0
FIXTURE_NPM_EXIT=31 run_launcher bootstrap || failure=$?
assert_equal 1 "$failure" 'failed bootstrap returns failure'
assert_equal absent "$([[ -f "$TEMP_ROOT/forbidden.log" ]] && printf present || printf absent)" 'Darwin never invokes Windows bootstrap tools or the Flutter wrapper'
assert_equal absent "$([[ -f "$WORKSPACE/multiplexor.exe" ]] && printf present || printf absent)" 'Darwin retains the extensionless executable'
printf 'Passed %s launcher checks.\n' "$passed"
