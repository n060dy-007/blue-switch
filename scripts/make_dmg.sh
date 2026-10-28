#!/bin/zsh
# Packages dist/BlueSwitch.app into a drag-to-install DMG: dist/BlueSwitch-<version>.dmg
# Usage: ./scripts/make_dmg.sh   (run ./scripts/build_app.sh first)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/dist/BlueSwitch.app"
[[ -d "$APP" ]] || { echo "✗ $APP not found — run scripts/build_app.sh first"; exit 1; }

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
DMG="$ROOT/dist/BlueSwitch-$VERSION.dmg"
STAGE="$ROOT/.build/dmg-stage"

echo "▸ Staging…"
rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

cat > "$STAGE/Install or Update BlueSwitch.command" <<'EOF'
#!/bin/zsh
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
SRC="$DIR/BlueSwitch.app"
DST="/Applications/BlueSwitch.app"

echo "▸ Stopping running BlueSwitch instance (if any)…"
killall BlueSwitch 2>/dev/null || true
sleep 1

echo "▸ Installing BlueSwitch to /Applications…"
rm -rf "$DST"
cp -R "$SRC" "$DST"
xattr -dr com.apple.quarantine "$DST" 2>/dev/null || true
codesign --force --deep --sign - "$DST" 2>/dev/null || true

echo "▸ Launching BlueSwitch…"
open "$DST"
echo "✓ BlueSwitch updated and launched!"
sleep 1
EOF
chmod +x "$STAGE/Install or Update BlueSwitch.command"

cat > "$STAGE/READ ME FIRST.txt" <<'EOF'
BlueSwitch — software KVM for Magic Keyboard / Trackpad / Mouse

UPDATING AN EXISTING INSTALL:
- Either double-click "Install or Update BlueSwitch.command" (automatically
  quits BlueSwitch, replaces /Applications/BlueSwitch.app, and relaunches),
- OR quit BlueSwitch from the top menu bar icon ("Quit BlueSwitch") BEFORE
  dragging BlueSwitch.app onto Applications (otherwise Finder will say
  "BlueSwitch.app is in use").

FRESH INSTALL:
1. Drag BlueSwitch.app onto the Applications folder (or run
   "Install or Update BlueSwitch.command").
2. First launch: right-click BlueSwitch.app in Applications → Open → Open.
   (The app is ad-hoc signed, so Gatekeeper asks once.)
   If macOS still blocks it: System Settings → Privacy & Security → "Open Anyway",
   or run in Terminal:  xattr -dr com.apple.quarantine /Applications/BlueSwitch.app
3. Allow Bluetooth, Local Network, and Accessibility access when prompted
   (Accessibility lets BlueSwitch auto-click macOS "Connection Request" prompts).
4. Install BlueSwitch on every Mac you want to switch between, then follow the
   setup steps in Settings → Peripherals and Settings → Macs.
EOF

echo "▸ Creating DMG…"
hdiutil create -volname "BlueSwitch $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
codesign --force --sign - "$DMG"
rm -rf "$STAGE"

echo "✓ $DMG ($(du -h "$DMG" | cut -f1))"
