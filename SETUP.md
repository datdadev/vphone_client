# vphone remote — setup

Three pieces: the patched `vphone-cli` on the Mac, a bridge next to it, and the
iOS app. See [`README.md`](README.md) for how they fit together.

## 0. Prerequisites

**On the Mac:**

- Apple Silicon, macOS 15+ (Sequoia or later)
- Xcode + iOS SDK, and [xcodegen](https://github.com/yonaskolb/XcodeGen)
  (`brew install xcodegen`) for the iOS app
- Node 18+ for the bridge
- SIP/AMFI relaxation and the `brew` dependencies `vphone-cli` itself needs —
  see [upstream vphone-cli's prerequisites](https://github.com/Lakr233/vphone-cli#prerequisites)

**On the iPhone:** iOS 17+, and it must be reachable on the same Wi-Fi/LAN as
the Mac (or a shared Tailscale tailnet — see step 3).

You'll also need an Apple Developer account (free personal team is fine) to
sign the iOS app.

## 1. Build and install the patched vphone-cli

The video streaming, native-resolution capture and live touch injection all live
in the fork under [`host/vphone-cli/`](host/) — stock `vphone-cli` won't work.
It's a git submodule, not plain files in this repo; if you didn't clone with
`--recurse-submodules`, fetch it now:

```bash
git submodule update --init --recursive
```

See [`host/README.md`](host/README.md) for details.

If you don't already have a VM, create one first (one-time, downloads and patches
an iOS firmware — see upstream's
[Quick Start](https://github.com/Lakr233/vphone-cli#quick-start) for variant
choices):

```bash
/Applications/vphone-cli.app/Contents/MacOS/vphone-cli vm create vphone -V jb
```

Then build and install the patched fork:

```bash
cd host/vphone-cli
./scripts/setup_tools.sh          # first time only
./scripts/build.sh --no-vphoned

/Applications/vphone-cli.app/Contents/MacOS/vphone-cli vm stop vphone
mv /Applications/vphone-cli.app /Applications/vphone-cli.app.prev
mv .build/vphone-cli.app /Applications/vphone-cli.app
```

It must live at `/Applications/vphone-cli.app` — `amfidont` allowlists that exact
path, and a build run from elsewhere is killed by AMFI (exit 137). If commands
start returning exit 137, `amfidont` has stopped; restart it with
`sudo /Applications/vphone-cli.app/Contents/Resources/vphone-amfidont`. Details
and troubleshooting in [`host/README.md`](host/README.md).

Then launch the VM:

```bash
/Applications/vphone-cli.app/Contents/MacOS/vphone-cli vm launch vphone
```

## 2. Run the bridge

```bash
cd bridge
npm install
npm run dev
```

First run writes `~/.vphone-bridge/config.json` with a generated token and prints
it — the iOS app needs that token. Defaults: port `8787`, VM name `vphone`.
Edit that file and restart to change them.

Leave it running whenever you want to control the phone remotely. (Auto-start via
`launchd` isn't set up.)

## 3. Network access

**Same Wi-Fi** — just use the Mac's LAN IP (`ipconfig getifaddr en0`). Simplest
for testing.

**From anywhere** — install Tailscale on both the Mac (`brew install --cask
tailscale && tailscale up`) and the iPhone, signed into the same account, then
use the Mac's Tailscale IP (`tailscale ip -4`).

## 4. Build and install the iOS app

```bash
cd ios/VPhoneRemote
xcodegen generate
```

Then either open `VPhoneRemote.xcodeproj` and run onto the device, or from the
command line once a provisioning profile exists:

```bash
xcodebuild -project VPhoneRemote.xcodeproj -scheme VPhoneRemote \
  -destination 'id=<device-udid>' build
xcrun devicectl device install app --device <device-udid> \
  ~/Library/Developer/Xcode/DerivedData/VPhoneRemote-*/Build/Products/Debug-iphoneos/VPhoneRemote.app
```

`xcrun xctrace list devices` gives the UDID. The first build for a new device has
to go through Xcode's GUI once, to register the device and issue the profile —
the command line can't do that part.

Before building, set your own Apple Developer Team ID in two places (both ship
as `YOUR_TEAM_ID` placeholders):

- `ios/VPhoneRemote/project.yml` — `DEVELOPMENT_TEAM`
- `ios/VPhoneRemote/ExportOptions.plist` — `teamID` (only needed if you export
  an `.ipa`; find your ID in Xcode under Settings → Accounts, or on
  [developer.apple.com](https://developer.apple.com/account))

Signing is otherwise driven by `project.yml`, so it survives `xcodegen
generate`. Note that free personal-team profiles **expire after 7 days**, after
which the app stops launching until it's rebuilt.

## 5. Connect

In the app: **Host** (Mac's LAN or Tailscale IP), **Port** `8787`, **Bridge
token** from step 2. Tap Connect.

Touch and drag to control it, the button row does Home/Power/Volume, the keyboard
button pushes text to the guest clipboard, and the number button cycles capture
rate (60 → 15 → 30).

## Known limits

- **Text entry sets the guest clipboard**; you still paste manually inside the
  guest, since the protocol has no keystroke injection.
- **No TLS on the bridge.** It relies on Tailscale's encryption plus the bearer
  token — don't expose the port outside your tailnet or LAN.
- **Single VM** (`vphone`) in the app. The bridge protocol accepts a `"vm"` field
  per command, but there's no picker in the UI.
- **Lock-screen gestures don't work** through synthetic touch injection (swipe-to-
  unlock in particular). This predates these changes — the original `swipe`
  command has the same limitation.
