# vphone remote

Control the virtual iPhone running on the Mac (via `vphone-cli`) from a real
iPhone, over the network.

```
[iPhone app]  <--wss: HEVC video + touch-->  [bridge]  <--unix socket-->  [vphone-cli VM]
   SwiftUI                                    Node/TS                      patched fork
```

| | |
|---|---|
| [`ios/VPhoneRemote/`](ios/VPhoneRemote/) | The iPhone client. Hardware HEVC decode into `AVSampleBufferDisplayLayer`, UIKit touch forwarding. |
| [`bridge/`](bridge/) | Node service on the Mac. Relays between the app's WebSocket and the VM's unix control socket. |
| [`host/vphone-cli/`](host/) | Patched `vphone-cli` fork: HEVC encoding, native-resolution capture, live touch injection. See [`host/README.md`](host/README.md). |

Setup instructions: [`SETUP.md`](SETUP.md).

## How it performs

Measured end-to-end on a local network:

| | |
|---|---|
| Video | 1290x2796 (native) at 60fps, ~5.5 Mbps |
| Touch → host injection | ~1-2ms |
| Phone ↔ bridge transit | ~6ms |
| Glass → touch handler | ~10ms |

## Design decisions worth knowing

These each came out of a specific failure, and are easy to undo by accident:

- **Capture reads the guest's IOSurface directly**, not the screenshot API. The
  screenshot API forces a GPU readback that starves the guest's compositor —
  it was the dominant source of input lag (705ms guest response at 60fps
  capture, versus instant with no capture). See [`host/README.md`](host/README.md).
- **Video and control use separate WebSocket connections.** Sharing one meant a
  single lost video packet head-of-line-blocked touch input for a full TCP
  retransmit timeout — measured 260ms stalls, delivering a whole gesture in one
  late burst.
- **Every queue in the path is bounded.** Decode queue, display layer, bridge
  socket, and host writer all drop frames under pressure rather than buffer them.
  An unbounded queue doesn't look like lag: the video stays smooth at 60fps while
  drifting seconds into the past, and only *your own touches* reveal it.
- **Video decode never touches the main thread on either end.** SwiftUI gesture
  callbacks and touch injection both need the main thread; running per-frame work
  there put input behind video on both the phone and the Mac.
- **Touch stays on TCP.** UDP suits video (a late frame is worthless, so drop it),
  but a dropped `touchUp` strands a finger down on the guest permanently.

## Diagnostics

The app shows live latency in the top-right corner:

- `net` — phone ↔ bridge round trip only, answered before any VM work
- `touch` — full path including injection into the guest
- `input` — glass → handler, from `UITouch.timestamp`
- `video` — host capture → decode on the phone

They split the pipeline into segments so a latency complaint can be traced to a
specific stage. Worth keeping: most of this project's debugging went wrong by
measuring the wrong segment (or measuring over localhost, which exercises none of
the phone's path).

The fps button cycles capture rate 60 → 15 → 30, reconnecting the video stream.
