import dgram from "node:dgram";
import WebSocket from "ws";
import { readFileSync } from "node:fs";
import { readHeader, HEADER_BYTES, fecGroupSize, type FrameTypeValue } from "./videoPackets.js";

const token = JSON.parse(readFileSync(process.env.HOME + "/.vphone-bridge/config.json", "utf8")).token;
const sessionId = "loss-" + Date.now();
const udp = dgram.createSocket("udp4");

interface Pending { frags: Map<number, Buffer>; parity: Map<number, Buffer>; count: number; type: number; at: number; }
const frames = new Map<number, Pending>();
// Parity trails the data fragments, so a frame that completed on data alone
// would otherwise be re-created by its own parity and counted as abandoned.
const done = new Set<number>();
let datagrams = 0, completed = 0, abandoned = 0, repaired = 0, maxSeq = 0, lastCompletedAt = Date.now();
let longestStall = 0;

setInterval(() => {
  const now = Date.now();
  for (const [seq, p] of frames) {
    if (now - p.at < 250) continue;
    // try FEC before giving up
    const size = fecGroupSize(p.type as FrameTypeValue);
    const groups = Math.ceil(p.count / size);
    for (let g = 0; g < groups; g++) {
      const first = g * size, last = Math.min(first + size, p.count);
      const missing = []; for (let i = first; i < last; i++) if (!p.frags.has(i)) missing.push(i);
      if (missing.length === 1 && p.parity.has(g)) repaired++;
    }
    frames.delete(seq); abandoned++;
  }
  longestStall = Math.max(longestStall, now - lastCompletedAt);
}, 100);

const HELLO = Buffer.from("VPHONE1");
udp.on("message", (msg) => {
  if (msg.subarray(0, HELLO.length).equals(HELLO)) return; // echoed hello
  datagrams++;
  const h = readHeader(msg); if (!h) return;
  maxSeq = Math.max(maxSeq, h.frameSeq);
  if (done.has(h.frameSeq)) return;
  let e = frames.get(h.frameSeq);
  if (!e) { e = { frags: new Map(), parity: new Map(), count: h.fragCount, type: h.frameType, at: Date.now() }; frames.set(h.frameSeq, e); }
  if (h.isParity) e.parity.set(h.groupIndex, msg.subarray(HEADER_BYTES));
  else e.frags.set(h.fragIndex, msg.subarray(HEADER_BYTES));
  if (e.frags.size === e.count) { completed++; lastCompletedAt = Date.now(); frames.delete(h.frameSeq); done.add(h.frameSeq); }
});
udp.bind(0, () => {
  const hello = Buffer.from("VPHONE1 " + sessionId);
  udp.send(hello, 8788, "127.0.0.1");
  setInterval(() => udp.send(hello, 8788, "127.0.0.1"), 500);
});

const ws = new WebSocket("ws://localhost:8787?token=" + token);
ws.on("open", () => ws.send(JSON.stringify({ t: "videoStream", fps: 60, scale: 1, bitrate: 12000000, udpSession: sessionId })));

const ctl = new WebSocket("ws://localhost:8787?token=" + token);
ctl.on("open", () => { let x = 200, dir = 1;
  ctl.send(JSON.stringify({ t: "touch", phase: "down", x, y: 1400, screen: false }));
  setInterval(() => { x += dir * 80; if (x < 200 || x > 1000) dir = -dir;
    ctl.send(JSON.stringify({ t: "touch", phase: "move", x, y: 1400, screen: false })); }, 16); });

setTimeout(() => {
  console.log("datagrams:", datagrams);
  console.log("frames completed:", completed, " abandoned(incomplete):", abandoned);
  console.log("frames the sender numbered:", maxSeq);
  console.log("delivery rate:", ((completed / Math.max(maxSeq, 1)) * 100).toFixed(1) + "%");
  console.log("FEC-repairable groups seen in abandoned frames:", repaired);
  console.log("longest gap with no completed frame:", longestStall + "ms");
  process.exit(0);
}, 25000);
