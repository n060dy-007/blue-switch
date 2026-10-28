#!/bin/zsh
# Builds BlueSwitch.app (release) using only the Command Line Tools — no Xcode needed.
# Usage: ./scripts/build_app.sh [--install]
#   --install   copy the app to /Applications (needed for "Launch at login")
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

APP="$ROOT/dist/BlueSwitch.app"
CACHE="$ROOT/.build/modcache"
mkdir -p "$CACHE"

echo "▸ Compiling (release)…"
CLANG_MODULE_CACHE_PATH="$CACHE" SWIFTPM_MODULECACHE_OVERRIDE="$CACHE" \
  swift build -c release --disable-sandbox

BIN="$(swift build -c release --show-bin-path)/BlueSwitch"

echo "▸ Assembling bundle…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/BlueSwitch"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
[[ -f "$ROOT/Resources/AppIcon.icns" ]] && cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
printf "APPL????" > "$APP/Contents/PkgInfo"

echo "▸ Signing (ad-hoc)…"
codesign --force --deep --sign - --entitlements "$ROOT/Resources/BlueSwitch.entitlements" "$APP"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
ZIP="$ROOT/dist/BlueSwitch-$VERSION.zip"
rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

echo "✓ Built $APP (v$VERSION) and $ZIP"

if [[ "${1:-}" == "--install" ]]; then
  echo "▸ Installing to /Applications…"
  pkill -x BlueSwitch 2>/dev/null || true
  rm -rf /Applications/BlueSwitch.app
  cp -R "$APP" /Applications/
  touch /Applications/BlueSwitch.app
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f /Applications/BlueSwitch.app
  echo "✓ Installed /Applications/BlueSwitch.app"
  open /Applications/BlueSwitch.app
fi
