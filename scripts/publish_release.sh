#!/bin/zsh
# Builds BlueSwitch.app, creates .zip, .dmg, and .pkg release artifacts,
# and uploads them to the GitHub release for the current Info.plist version.
# Usage: ./scripts/publish_release.sh [--notes "Release notes..."]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REPO="${BLUESWITCH_REPO:-n060dy-007/blue-switch}"
GH_BIN="${GH_BIN:-$(command -v gh || echo /opt/homebrew/bin/gh)}"

"$ROOT/scripts/build_app.sh"
"$ROOT/scripts/make_pkg.sh"
"$ROOT/scripts/make_dmg.sh"

APP="$ROOT/dist/BlueSwitch.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
TAG="v$VERSION"
ZIP="$ROOT/dist/BlueSwitch-$VERSION.zip"
DMG="$ROOT/dist/BlueSwitch-$VERSION.dmg"
PKG="$ROOT/dist/BlueSwitch-$VERSION.pkg"

if "$GH_BIN" release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
  echo "▸ Uploading assets to existing GitHub release $TAG on $REPO…"
  "$GH_BIN" release upload "$TAG" "$ZIP" "$DMG" "$PKG" --repo "$REPO" --clobber
else
  NOTES="${1:-BlueSwitch $TAG release}"
  echo "▸ Creating GitHub release $TAG on $REPO…"
  "$GH_BIN" release create "$TAG" "$ZIP" "$DMG" "$PKG" \
    --repo "$REPO" \
    --title "BlueSwitch $TAG" \
    --notes "$NOTES"
fi

echo "✓ Published $TAG to https://github.com/$REPO/releases/tag/$TAG"

