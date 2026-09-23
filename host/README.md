# host/vphone-cli — patched fork

A fork of [Lakr233/vphone-cli](https://github.com/Lakr233/vphone-cli) with the
changes needed to stream the VM to a phone with low latency. It's its own git
checkout with `origin` still pointing at upstream, so `git diff origin/main`
shows exactly what this fork added — that's why it's `.gitignore`d from this
repo rather than nested inside it, and **not included when you clone this repo**.

```bash
git clone --recurse-submodules https://github.com/Lakr233/vphone-cli.git host/vphone-cli
```

The changes themselves are on a local branch (`vphone-remote`) in the original
author's working copy, not yet pushed anywhere public. Until that's published,
reproduce the patch yourself: fork upstream on GitHub, apply the changes
described below (file by file — none of them are large), commit to a branch,
and push it.

## Build & install

```bash
cd host/vphone-cli
./scripts/setup_tools.sh      # first time only (brew deps, submodules, python venv)
./scripts/build.sh --no-vphoned
```

`--no-vphoned` skips cross-compiling the guest daemon, which none of these
changes touch. Then swap the bundle in (the running VM must be stopped first):

```bash
/Applications/vphone-cli.app/Contents/MacOS/vphone-cli vm stop vphone
mv /Applications/vphone-cli.app /Applications/vphone-cli.app.prev
mv .build/vphone-cli.app /Applications/vphone-cli.app
/Applications/vphone-cli.app/Contents/MacOS/vphone-cli vm launch vphone
```

The path matters: `amfidont` allowlists `/Applications/vphone-cli.app` by path, so
a build run from anywhere else is killed by AMFI (exit 137). If the binary dies
that way, `amfidont` has probably stopped — restart it with
`/Applications/vphone-cli.app/Contents/Resources/vphone-amfidont` (needs sudo).

`.build/` and `.venv/` are regenerable and were deleted to keep the tree small.
The app build doesn't need `.venv` at all — only the firmware/patching pipeline does.

## What was changed and why

### `VPhoneVideoStream.swift` (new) — hardware HEVC streaming

Encodes the VM display as HEVC via `VTCompressionSession` and pushes it over the
control socket, replacing per-frame JPEG stills. A phone UI barely changes
between frames, so interframe compression carries native resolution at a
fraction of the bandwidth: **1290x2796 at 60fps for ~5.5 Mbps**, versus ~105 Mbps
for equivalent JPEG stills.

Configured real-time with B-frames disabled — they'd buy compression by buffering
future frames, which is the one thing interactive control can't afford.

Wire format, after a JSON handshake line:

```
[4-byte length][1-byte type][8-byte capture timestamp ms][payload]
type 1 = HEVC parameter sets (VPS/SPS/PPS), 2 = keyframe, 3 = delta frame
```

Payloads stay in AVCC form exactly as VideoToolbox emits them, so clients need no
Annex-B conversion. Parameter sets are re-sent before every keyframe so a
reconnecting client recovers within one GOP.

### `VPhoneSurfaceCapture.swift` (new) — the capture source

Reads the guest framebuffer straight out of the CALayer that displays it, whose
`contents` is an IOSurface at native resolution. This is the whole reason the
stream is both sharp and responsive; the two obvious alternatives each fail:

| | resolution | stalls guest | needs permission | needs window visible |
|---|---|---|---|---|
| `_takeScreenshotWithCompletionHandler:` | native | **yes, badly** | no | no |
| ScreenCaptureKit | **on-screen only (blurry)** | no | screen recording | yes |
| **IOSurface (this)** | **native** | **no** | **no** | **no** |

The screenshot API is a *screenshot* API: each call forces a synchronous GPU
readback that contends with the guest's compositor. Measured guest response was
289ms at 15fps capture and 705ms at 60fps, versus instant with nobody capturing.
That was the single largest source of perceived input lag.

Two subtleties that cost real debugging time:

- **Dedup must key on surface ID *and* seed.** The layer swaps between buffers,
  and seeds from different surfaces aren't comparable. Testing the seed alone
  silently discarded valid frames whenever the buffer alternated, roughly halving
  the delivered frame rate.
- **Poll at 2x the target rate.** Sampling at exactly the source rate beats
  against it and misses frames. Oversampling is nearly free because unchanged
  frames never reach the encoder.

A still screen emits nothing, so there's a 0.5s heartbeat — otherwise a client
connecting to a static screen would sit on black forever.

### `VPhoneWindowCapture.swift` (new) — ScreenCaptureKit fallback

Used only if the IOSurface isn't available. Kept because it doesn't stall the
guest, but it can only capture what the window server draws, so it's limited to
the shrunken on-screen size and needs the window visible.

### `VPhoneHostControl.swift` (modified)

- **Concurrent accept loop.** Previously it accepted one connection and handled
  it to completion before accepting the next, so with video streaming there was
  almost always a capture in flight and every tap queued behind it. Each client
  now gets dispatched to a concurrent queue; cheap commands no longer wait on
  expensive ones.
- **`videoStream` command** — the one long-lived connection in the protocol.
- **`touch` / `multiTouch` commands** — live touch primitives (`down`/`move`/`up`,
  and simultaneous multi-finger for pinch). The pre-existing `swipe` replays a
  canned gesture *after* the finger lifts, which feels disconnected from real
  scrolling.
- **Reports `screenWidth`/`screenHeight`** with screenshots, so clients map touch
  coordinates from the host's own numbers instead of hardcoding a scale factor.
- **Compact screenshots in colour, with `scale`/`quality` as request parameters**
  (they were hardcoded, and grayscale for AI use).

### `VPhoneVirtualMachineView.swift` (modified)

Adds `injectLiveTouch` and `injectMultiTouch`, which build `_VZMultiTouchEvent`
directly with per-finger indices. The existing injection path synthesizes
`NSEvent` mouse events, which are inherently single-pointer — real pinch needs
two touches moving in the same event.
