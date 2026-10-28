#!/bin/zsh
# Builds a native macOS Installer package (dist/BlueSwitch-<version>.pkg)
# whose preinstall/postinstall scripts automatically stop any running BlueSwitch
# process, replace /Applications/BlueSwitch.app, clear quarantine, and relaunch.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/dist/BlueSwitch.app"
[[ -d "$APP" ]] || { echo "✗ $APP not found — run scripts/build_app.sh first"; exit 1; }

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
PKG="$ROOT/dist/BlueSwitch-$VERSION.pkg"
WORK="$ROOT/.build/pkg-stage"
ROOT_DIR="$WORK/root/Applications"
SCRIPTS_DIR="$WORK/scripts"

rm -rf "$WORK" "$PKG"
mkdir -p "$ROOT_DIR" "$SCRIPTS_DIR"
cp -R "$APP" "$ROOT_DIR/BlueSwitch.app"

cat > "$SCRIPTS_DIR/preinstall" <<'EOF'
#!/bin/zsh
killall BlueSwitch 2>/dev/null || true
sleep 0.5
rm -rf /Applications/BlueSwitch.app 2>/dev/null || true
exit 0
EOF

cat > "$SCRIPTS_DIR/postinstall" <<'EOF'
#!/bin/zsh
xattr -dr com.apple.quarantine /Applications/BlueSwitch.app 2>/dev/null || true
codesign --force --deep --sign - /Applications/BlueSwitch.app 2>/dev/null || true
CONSOLE_USER="$(stat -f '%Su' /dev/console 2>/dev/null || true)"
if [[ -n "$CONSOLE_USER" && "$CONSOLE_USER" != "root" ]]; then
  su -l "$CONSOLE_USER" -c "open /Applications/BlueSwitch.app" 2>/dev/null || true
fi
exit 0
EOF

chmod +x "$SCRIPTS_DIR/preinstall" "$SCRIPTS_DIR/postinstall"

pkgbuild \
  --root "$WORK/root" \
  --scripts "$SCRIPTS_DIR" \
  --identifier "com.blueswitch.app" \
  --version "$VERSION" \
  --install-location "/" \
  "$PKG" >/dev/null

rm -rf "$WORK"
echo "✓ $PKG ($(du -h "$PKG" | cut -f1))"
