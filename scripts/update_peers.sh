#!/bin/zsh
# Pushes dist/BlueSwitch.app to one or more remote Macs over SSH, installs into
# /Applications/BlueSwitch.app, and restarts BlueSwitch on each remote Mac.
# Note: Once a peer Mac is running BlueSwitch v1.0.2+, future updates happen
# automatically over BlueSwitch's built-in LAN protocol without needing SSH.
#
# Usage: ./scripts/update_peers.sh <host_or_user@host> [more_hosts...]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/dist/BlueSwitch.app"

if [[ ! -d "$APP" ]]; then
  echo "▸ Building BlueSwitch.app first…"
  "$ROOT/scripts/build_app.sh"
fi

if [[ $# -eq 0 ]]; then
  echo "Usage: $0 <host_or_user@host> [more_hosts...]"
  echo "Example: $0 macbook-pro.local"
  exit 1
fi

ZIP="/tmp/BlueSwitch-deploy.zip"
rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

for TARGET in "$@"; do
  echo "▸ Deploying BlueSwitch to $TARGET…"
  scp "$ZIP" "$TARGET:/tmp/BlueSwitch-deploy.zip"
  ssh "$TARGET" '
    set -e
    pkill -x BlueSwitch 2>/dev/null || true
    rm -rf /Applications/BlueSwitch.app
    ditto -x -k /tmp/BlueSwitch-deploy.zip /Applications/
    rm -f /tmp/BlueSwitch-deploy.zip
    xattr -dr com.apple.quarantine /Applications/BlueSwitch.app 2>/dev/null || true
    touch /Applications/BlueSwitch.app
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f /Applications/BlueSwitch.app 2>/dev/null || true
    open -n /Applications/BlueSwitch.app
  '
  echo "✓ Updated and restarted BlueSwitch on $TARGET"
done

rm -f "$ZIP"

