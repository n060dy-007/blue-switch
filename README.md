# BlueSwitch

A software KVM for macOS. Move your **Magic Keyboard**, **Magic Trackpad** and **Magic Mouse**
between Macs with one click, one keystroke, or automatically on sleep/wake — no cables or
hardware switch. Built on [Blue Switch](https://github.com/HoshimuraYuto/blue-switch) by
Hoshimura Yuto, with a full configuration GUI.

## Build & install (no Xcode required)

```bash
./scripts/build_app.sh            # → dist/BlueSwitch.app & dist/BlueSwitch-<version>.zip
./scripts/build_app.sh --install  # also copies to /Applications and launches
./scripts/make_dmg.sh             # → dist/BlueSwitch-<version>.dmg for other Macs
./scripts/update_peers.sh <host>  # → pushes BlueSwitch.app to another Mac over SSH & restarts
```

On another Mac, open the DMG (or run `./scripts/update_peers.sh <other-mac.local>`) and drag BlueSwitch onto Applications. The first time, right-click
the app → **Open** (it's ad-hoc signed, so Gatekeeper asks once). Once both Macs are on **v1.0.2+**, future updates automatically push over the local network from whichever Mac is updated first!

Install on **both** Macs. Put it in `/Applications` so *Launch at login* works.

## First-time setup (Magic Keyboard & Trackpad, USB-C)

1. **Pair each device with both Macs once.** Plug it into a Mac with the USB-C cable for a few
   seconds, unplug, and repeat on the other Mac.
2. On Mac A open **Settings → Peripherals** and click **Add** next to the keyboard and trackpad.
3. Open **Settings → Macs**. Mac B shows up under *Discovered*. Click **Register**.
4. Click **Sync** (⟳) to push the peripheral list to Mac B, or add the devices there by hand.
5. On Mac B, register Mac A under **Macs**.
6. Optional: set the same global shortcut on both Macs in **Settings → Shortcuts**.

When prompted, allow **Bluetooth**, **Local Network**, and **Accessibility** access (Accessibility allows BlueSwitch to automatically click macOS's "Connection Request" prompt when peripherals switch).

## Using it

| Action | Result |
| --- | --- |
| Left-click menu bar icon | Switch (configurable: switch / dashboard / menu) |
| Right-click menu bar icon | Menu: switch, send, take, pick target Mac, toggle single devices |
| Global shortcut | Switch / Send to peer / Take from peer |
| Dashboard | Visual This Mac ⇄ Peer status with Switch, Send, Take buttons |

**Switch** works like upstream: if your peripherals are on this Mac, they're sent to the other
Mac. If they aren't, they're pulled here.

## All settings

| Pane | Settings |
| --- | --- |
| **General** | Launch at login · Take peripherals on launch · Menu bar icon · Left-click action · Ask before switching · Theme · Dock icon · Auto-update other Macs over LAN · Allow incoming peer updates · Auto-check GitHub updates · Install from file / Push update to all Macs |
| **Switching** | Release method (unpair / close) · Partial-state behavior · Auto-click Bluetooth connection requests · Auto-click scope & scan interval · Disconnect poll interval · Max disconnect checks · Settle delay · Pairing timeout · Connection retries · Retry delay · RSSI range check · Auto-sync peripheral list · Send on sleep · Take on wake |
| **Peripherals** | Add / remove / remove all · Rename (alias) · Include in switching · Connect / Release per device · Reorder · Refresh |
| **Macs** | Register discovered Macs · Set target · Peer version badge · Push OTA update / SSH bootstrap · Health check · Notify · Sync peripherals · Remove · Add manually (host/port) |
| **Network** | Device name · Listening port · Bonjour discovery on/off · Service type · Health-check timeout · Command timeout · Pairing key · Live status |
| **Notifications** | Enable · Sound · On switch · On error · On remote request · On Mac discovered · Custom "Notify" title & message · Local send confirmation · Test / request permission |
| **Shortcuts** | Enable global shortcuts · Switch · Send to peer · Take from peer |
| **Advanced** | Log level · Log history size · Status refresh interval · Export / Import settings · Restart network · Refresh Bluetooth · Reset to defaults |
| **Activity Log** | Filter by level · Search · Copy · Save · Clear |

## Differences from upstream Blue Switch

- Upstream's *General* tab (auto-launch, notifications, auto-update) only had placeholder
  toggles and wasn't reachable. In BlueSwitch all three actually work.
- Timeouts, retries and polling that upstream hard-coded can now be changed in Settings.
- Peers talk over newline-delimited JSON instead of raw strings, so TCP packet merging can't
  corrupt commands. An optional pairing key controls which Macs can connect. **Because of
  this, BlueSwitch can't talk to the original Blue Switch app.** Run BlueSwitch on both Macs.
- You can register more than one Mac and choose which one is the target.
- Upstream used App Sandbox; BlueSwitch doesn't, so unpairing Magic devices works with ad-hoc
  signing.

## Project layout

```
Sources/BlueSwitch/
  App/   BlueSwitchApp.swift (entry, AppDelegate) · StatusBarController.swift
  Core/  Settings · BluetoothService · NetworkService · PeerProtocol · SwitchCoordinator
         HotKeyManager · NotificationService · LoginItem · UpdateChecker · SettingsTransfer · Log
  UI/    DashboardView · SettingsRootView · SettingsPanes · DevicePanes · SupportPanes · Components
Resources/  Info.plist · BlueSwitch.entitlements · AppIcon.icns
scripts/    build_app.sh · make_icon.swift
```
