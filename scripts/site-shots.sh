#!/bin/bash
# Regenerates the product page screenshots from build/MenuSearch.app: the production panel and settings window,
# rendered offscreen in a throwaway support directory. The menu shown is fixed demo data, so nothing personal
# can appear. Run after a UI change so the page never shows an older look than the app.
set -euo pipefail
DIR="$(cd "$(dirname "$0")/.." && pwd)"
# MENUSEARCH_APP: another build of the current source (for example build/accept/<hash>/MenuSearch.app).
APP="${MENUSEARCH_APP:-$DIR/build/MenuSearch.app}/Contents/MacOS/MenuSearch"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
MENUSEARCH_SUPPORT_DIR="$WORK/support" APP_LIFECYCLE_SUPPORT_DIR="$WORK/lifecycle" "$APP" --site-shots --output "$DIR/site/assets"
ls -l "$DIR"/site/assets/panel.png "$DIR"/site/assets/panel-search-dark.png "$DIR"/site/assets/settings.png
