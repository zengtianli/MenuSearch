#!/bin/bash
# Builds build/MenuSearch.app: logic tests first, then the application, then its offscreen self-test.
#   bash build.sh              build, sign, self-test
#   bash build.sh --test-only  logic tests only
# MENUSEARCH_OUT=DIR puts every product of the build under DIR instead of build/ (the acceptance checks use this
# for their own ad-hoc signed copy).
# Nothing is installed, launched on screen or published. Signing identity: $CODESIGN_IDENTITY, else the first line
# of local/signing-identity, else ad-hoc ("-"). An ad-hoc build works, but macOS asks for the Accessibility
# permission again after every rebuild; a stable identity keeps it.
set -euo pipefail
cd "$(dirname "$0")"
# Compilation uses the shared parallel slots; only the timed self-test needs a quiet window.
# Outside the managed workstation the scheduler is optional, so public builds still use system tools alone.
run_phase() {
  python3 - "$@" <<'PY'
import importlib.util
import os
from pathlib import Path
import subprocess
import sys

phase, *command = sys.argv[1:]
module = Path(os.environ.get("SIM_LANE_SCRIPT") or Path.home() / "Dev/tools/dev/lib/tools/macapp/ios/sim_lane.py")
if not module.is_file():
    if os.environ.get("SOP_APP_ID"):
        sys.exit("Shared build/measurement scheduler is unavailable")
    sys.exit(subprocess.call(command))
spec = importlib.util.spec_from_file_location("sim_lane", module)
lane = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = lane
spec.loader.exec_module(lane)
label = f"menusearch:{phase}:{os.getpid()}"
try:
    if phase == "compile":
        with lane.BuildSlot(label, wait=0):
            code = subprocess.call(command)
    else:
        locks = lane.lock_chain(label)
        try:
            lane.acquire(locks, None, lock_wait=0, load_wait=0, max_load=lane.max_load_default())
            code = subprocess.call(command)
        finally:
            for lock in reversed(locks):
                lock.release()
    sys.exit(code)
except lane.Busy as error:
    print(f"Deferred {phase}: {error}", file=sys.stderr)
    sys.exit(75)
PY
}
if [ "$#" -gt 1 ] || { [ "$#" -eq 1 ] && [ "$1" != '--test-only' ]; }; then
  echo 'Usage: bash build.sh [--test-only]' >&2
  exit 2
fi
if [ "$(uname -s)" != Darwin ] || [ "$(uname -m)" != arm64 ]; then
  echo 'Building requires an Apple Silicon Mac.' >&2
  exit 1
fi
# Optional local Xcode selection; any selected Xcode or Command Line Tools works.
XCODE_ENV="${XCODE_ENV_SH:-$HOME/Dev/tools/dev/lib/tools/macapp/xcode_env.sh}"
if [ -f "$XCODE_ENV" ]; then source "$XCODE_ENV"; xcode_env_use macosx; fi
if ! xcrun --find swiftc >/dev/null 2>&1; then
  echo 'Install Xcode Command Line Tools (xcode-select --install) or Xcode first.' >&2
  exit 1
fi
SDK="$(xcrun --sdk macosx --show-sdk-path)"
COMPILER=(xcrun swiftc -swift-version 5 -O -whole-module-optimization -target arm64-apple-macos14.0 -sdk "$SDK")
OUT="${MENUSEARCH_OUT:-$PWD/build}"
mkdir -p build "$OUT"
run_phase compile "${COMPILER[@]}" Sources/Env.swift Sources/MenuCore.swift Sources/Settings.swift Sources/Control.swift Tests/main.swift -o "$OUT/tests"
"$OUT/tests"
if [ "${1:-}" = '--test-only' ]; then exit 0; fi

# The shared settings/update sources are vendored byte-for-byte; edit them only at their origin.
LIFECYCLE_VENDOR="${APP_LIFECYCLE_VENDOR:-$HOME/Dev/tools/dev/lib/tools/macapp/swift-shared/vendor-lifecycle.py}"
if [ -f "$LIFECYCLE_VENDOR" ]; then python3 "$LIFECYCLE_VENDOR" --platform mac --cli --target-source-dir "$PWD/Sources"; fi
# Same for the quiet-launch contract the measurement tools use (-lane_quiet, the lane-ready log line).
LANE_SIGNAL="${LANE_SIGNAL_SOURCE:-$HOME/Dev/tools/dev/lib/tools/macapp/swift-shared/LaneSignal.swift}"
if [ -f "$LANE_SIGNAL" ] && ! cmp -s "$LANE_SIGNAL" Sources/LaneSignal.swift; then cp "$LANE_SIGNAL" Sources/LaneSignal.swift; fi

STAGE="$(mktemp -d "$PWD/build/compile.XXXXXX")"
SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/menusearch-build.XXXXXX")"
trap 'rm -rf "$STAGE" "$SCRATCH"' EXIT
APP="$STAGE/MenuSearch.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Info.plist "$APP/Contents/Info.plist"
cp icon/AppIcon.icns Resources/tuning.json LICENSE "$APP/Contents/Resources/"

SOURCES=()
while IFS= read -r line; do SOURCES+=("$line"); done < <(find Sources -type f -name '*.swift' | LC_ALL=C sort)
# The only network client is the shared update check (Sources/AppLifecycle*.swift): an HTTPS request to GitHub
# Releases when the user asks for updates. scripts/accept/run.py privacy holds the product's own sources to that.
run_phase compile "${COMPILER[@]}" -Xlinker -dead_strip "${SOURCES[@]}" -o "$APP/Contents/MacOS/MenuSearch"
strip -x "$APP/Contents/MacOS/MenuSearch"

IDENTITY="${CODESIGN_IDENTITY:-}"
if [ -z "$IDENTITY" ] && [ -f local/signing-identity ]; then IDENTITY="$(head -1 local/signing-identity | tr -d '[:space:]')"; fi
IDENTITY="${IDENTITY:--}"
if [ "$IDENTITY" = '-' ]; then
  codesign --force --sign - --identifier cyou.tianli.menusearch "$APP"
else
  codesign --force --sign "$IDENTITY" --options runtime --timestamp "$APP"
fi
codesign --verify --deep --strict "$APP"
test "$(lipo -archs "$APP/Contents/MacOS/MenuSearch")" = arm64

# The production views and logic, offscreen, in a throwaway support directory.
rm -rf "$OUT/self-test"
MENUSEARCH_SUPPORT_DIR="$SCRATCH/support" APP_LIFECYCLE_SUPPORT_DIR="$SCRATCH/lifecycle" \
  run_phase measure "$APP/Contents/MacOS/MenuSearch" --self-test --output "$OUT/self-test" > "$OUT/self-test.log" || {
  code=$?
  cat "$OUT/self-test.log" >&2
  if [ "$code" = 75 ]; then
    echo 'Offscreen self-test deferred; the previous MenuSearch.app was not replaced.' >&2
    exit 75
  fi
  echo 'Offscreen self-test failed; the previous MenuSearch.app was not replaced.' >&2
  exit 1
}

if [ -e "$OUT/MenuSearch.app" ]; then
  rm -rf "$OUT/MenuSearch.previous.app"
  mv "$OUT/MenuSearch.app" "$OUT/MenuSearch.previous.app"
fi
mv "$APP" "$OUT/MenuSearch.app"
echo "Built: $OUT/MenuSearch.app ($("$OUT/MenuSearch.app/Contents/MacOS/MenuSearch" version))"
