# bridge

Node/TypeScript service that sits between the iOS app's WebSocket and the
`vphone-cli` VM's unix control socket. See the [root README](../README.md) for
where this fits and [`../SETUP.md`](../SETUP.md) for install steps.

## Run

```bash
npm install
npm run dev      # tsx, runs src/server.ts directly
```

`npm run build && npm start` compiles to `dist/` and runs the compiled output
instead, if you'd rather not run through `tsx`.

First run writes `~/.vphone-bridge/config.json` with a generated bearer token
and prints it. Edit that file and restart to change the port or VM name.

## Layout

| | |
|---|---|
| `server.ts` | WebSocket server: auth, command dispatch, per-connection state. |
| `config.ts` | Reads/creates `~/.vphone-bridge/config.json`. |
| `vphoneSocket.ts` / `vphoneCli.ts` | Talk to the VM: unix control socket and the `vphone-cli` binary. |
| `videoStream.ts` | Wires a `videoStream` command to the host's HEVC stream. |
| `udpVideo.ts` | UDP path for video frames (falls back from WS when the client opts in). |
| `videoPackets.ts` | Wire format for UDP video: fragmentation, FEC, reassembly. |
| `congestionControl.ts` | Bitrate control law for the video encoder. |

## Tests

There's no test runner wired up (`npm test` doesn't exist) — these are plain
scripts run with `tsx`, split into two kinds:

**Standalone** — pure logic, no bridge or VM needed:

```bash
npx tsx src/congestionControl.test.ts
npx tsx src/videoPackets.test.ts
```

**Live** — connect to a running bridge over `localhost:8787`, read the token
from `~/.vphone-bridge/config.json`, and request a real video stream, so both
a `npm run dev` bridge and a launched VM (see [`../SETUP.md`](../SETUP.md))
must be up:

```bash
npx tsx src/udpDecode.test.ts
npx tsx src/udpLoss.test.ts
npx tsx src/udpVideo.test.ts
```

Each prints `expect X` lines next to what it measured rather than asserting —
read the output.
