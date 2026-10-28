#!/bin/zsh
# Downloads and installs the latest BlueSwitch release from GitHub (n060dy-007/blue-switch),
# automatically stopping any running BlueSwitch instance and relaunching after install.
set -euo pipefail

REPO="${BLUESWITCH_REPO:-n060dy-007/blue-switch}"
TMP_DIR="$(mktemp -d /tmp/blueswitch-gh-update.XXXXXX)"
trap 'rm -rf "$TMP_DIR"' EXIT

echo "▸ Fetching latest release from https://github.com/$REPO/releases/latest …"
ZIP_URL="$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" \
  | grep -Eo '"browser_download_url":[[:space:]]*"[^"]+\.zip"' \
  | head -n1 \
  | sed -E 's/.*"([^"]+)".*/\1/')"

if [[ -z "$ZIP_URL" ]]; then
  echo "✗ Could not find .zip asset on latest GitHub release for $REPO"
  exit 1
fi

echo "▸ Downloading $ZIP_URL …"
curl -fL "$ZIP_URL" -o "$TMP_DIR/BlueSwitch.zip"

echo "▸ Extracting BlueSwitch.app …"
ditto -x -k "$TMP_DIR/BlueSwitch.zip" "$TMP_DIR/extracted"

echo "▸ Stopping running BlueSwitch (if any) …"
killall BlueSwitch 2>/dev/null || true
sleep 0.5

echo "▸ Installing to /Applications/BlueSwitch.app …"
rm -rf /Applications/BlueSwitch.app
cp -R "$TMP_DIR/extracted/BlueSwitch.app" /Applications/BlueSwitch.app
xattr -dr com.apple.quarantine /Applications/BlueSwitch.app 2>/dev/null || true
codesign --force --deep --sign - /Applications/BlueSwitch.app 2>/dev/null || true

echo "▸ Launching BlueSwitch …"
open /Applications/BlueSwitch.app
echo "✓ BlueSwitch updated from GitHub release!"
