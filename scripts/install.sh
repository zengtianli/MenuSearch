#!/bin/bash
# Installs a built MenuSearch.app to /Applications and links ~/.local/bin/menusearch.
#
#   bash scripts/install.sh [--restart] [path/to/MenuSearch.app]
#
# First install: copies the app and adds the command link (an existing, different entry is reported, not replaced).
# Upgrade: the installed app is moved to ~/.Trash/menusearch-<old version>-<time>/ and replaced; if copying or
# verifying fails it is put back. While the installed copy is running in the background the install refuses
# unless --restart is given; then it is asked to quit through its own control socket, replaced, and started again
# in the background (no window, no focus change). Settings and permissions are not touched.
set -euo pipefail
cd "$(dirname "$0")/.."
usage() { echo 'Usage: bash scripts/install.sh [--restart] [path/to/MenuSearch.app]' >&2; exit 2; }
RESTART=0
APP=''
for arg in "$@"; do
  case "$arg" in
    --restart) [ "$RESTART" = 0 ] || usage; RESTART=1 ;;
    -*) usage ;;
    *) [ -z "$APP" ] || usage; APP="$arg" ;;
  esac
done
APP="${APP:-$PWD/build/MenuSearch.app}"
DEST=/Applications/MenuSearch.app
CLI_TARGET="$DEST/Contents/MacOS/MenuSearch"
LINK="$HOME/.local/bin/menusearch"
NEW="$APP/Contents/MacOS/MenuSearch"
if [ ! -x "$NEW" ]; then
  echo 'App not found. Run bash build.sh first, or pass a built MenuSearch.app.' >&2
  exit 1
fi
# Check the new copy before anything running is touched.
codesign --verify --deep --strict "$APP"

# The listening instance, as reported by the new build's own read-only status: "<pid> <executable>" or nothing.
resident() {
  "$NEW" status --json | python3 -c '
import json, sys
r = json.load(sys.stdin).get("resident", {})
if r.get("running"): print(r["pid"], r["executable"])'
}

RUNNING="$(resident)"
RUNNING_PID="${RUNNING%% *}"
if [ -n "$RUNNING" ] && [ "$RESTART" != 1 ]; then
  echo "MenuSearch is running (pid $RUNNING_PID). Quit it first, or pass --restart to quit, replace and start it again in the background." >&2
  exit 1
fi
# A command entry that is not ours is reported, never replaced; checked before anything is stopped.
if { [ -e "$LINK" ] || [ -L "$LINK" ]; } && [ "$(readlink "$LINK" || true)" != "$CLI_TARGET" ]; then
  echo "Existing command entry; inspect it before replacing: $LINK" >&2
  exit 1
fi

if [ -n "$RUNNING" ]; then
  "$NEW" quit >/dev/null
  for _ in $(seq 100); do
    kill -0 "$RUNNING_PID" 2>/dev/null || break
    sleep 0.1
  done
  if kill -0 "$RUNNING_PID" 2>/dev/null; then
    echo "MenuSearch (pid $RUNNING_PID) did not quit within 10 s; install stopped without forcing it." >&2
    exit 1
  fi
fi

start_background() {
  open -g -a "$DEST" --args --app-background
}

BACKUP=''
restore() {
  echo 'Install failed; putting the previous app back.' >&2
  rm -rf "$DEST"
  if [ -n "$BACKUP" ] && [ -d "$BACKUP" ]; then mv "$BACKUP" "$DEST"; fi
  if [ -n "$RUNNING" ] && [ -d "$DEST" ]; then start_background || true; fi
}

if [ -e "$DEST" ]; then
  OLD_VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$DEST/Contents/Info.plist" 2>/dev/null || echo unknown)"
  SHELF="$HOME/.Trash/menusearch-$OLD_VERSION-$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$SHELF"
  BACKUP="$SHELF/MenuSearch.app"
  mv "$DEST" "$BACKUP"
fi
trap restore ERR
ditto "$APP" "$DEST"
codesign --verify --deep --strict "$DEST"
cmp -s "$NEW" "$CLI_TARGET"
trap - ERR
if [ ! -L "$LINK" ]; then
  mkdir -p "$(dirname "$LINK")"
  ln -s "$CLI_TARGET" "$LINK"
fi
echo "Installed: $DEST ($("$CLI_TARGET" version))"
[ -z "$BACKUP" ] || echo "Previous app moved to: $BACKUP"
echo "Command: $LINK -> $CLI_TARGET (add ~/.local/bin to PATH if needed)"
# Background start: a copy that was running comes back; otherwise the app starts, registers its shortcut if one is
# set, and leaves again by itself when it has nothing to listen for.
start_background
for _ in $(seq 50); do
  NOW="$(resident)"
  if [ -n "$NOW" ]; then echo "Running in the background: pid ${NOW%% *}"; break; fi
  sleep 0.1
done
