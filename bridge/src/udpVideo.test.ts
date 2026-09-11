import dgram from "node:dgram";
import WebSocket from "ws";
import { readFileSync } from "node:fs";
import { readHeader, HEADER_BYTES } from "./videoPackets.js";

const token = JSON.parse(readFileSync(process.env.HOME + "/.vphone-bridge/config.json", "utf8")).token;
const sessionId = "test-" + Date.now();
const udp = dgram.createSocket("udp4");

const frames = new Map<number, { frags: Map<number, Buffer>; count: number; len: number }>();
let datagrams = 0, completed = 0, bytes = 0, wsFrames = 0, parity = 0;

udp.on("message", (msg) => {
  datagrams++;
  bytes += msg.length;
  const h = readHeader(msg);
  if (!h) return;
  if (h.isParity) { parity++; return; }
  let entry = frames.get(h.frameSeq);
  if (!entry) { entry = { frags: new Map(), count: h.fragCount, len: h.frameLen }; frames.set(h.frameSeq, entry); }
  entry.frags.set(h.fragIndex, msg.subarray(HEADER_BYTES));
  if (entry.frags.size === entry.count) { completed++; frames.delete(h.frameSeq); }
});

udp.bind(0, () => {
  const hello = Buffer.from("VPHONE1 " + sessionId);
  udp.send(hello, 8788, "127.0.0.1");
  setInterval(() => udp.send(hello, 8788, "127.0.0.1"), 500);
});

const ws = new WebSocket("ws://localhost:8787?token=" + token);
ws.on("open", () => ws.send(JSON.stringify({
  t: "videoStream", fps: 60, scale: 1, bitrate: 12000000, udpSession: sessionId,
})));
ws.on("message", (_d, bin) => { if (bin) wsFrames++; });

const ctl = new WebSocket("ws://localhost:8787?token=" + token);
ctl.on("open", () => {
  let x = 60, dir = 1;
  ctl.send(JSON.stringify({ t: "touch", phase: "down", x, y: 1400, screen: false }));
  setInterval(() => {
    x += dir * 70; if (x < 60 || x > 900) dir = -dir;
    ctl.send(JSON.stringify({ t: "touch", phase: "move", x, y: 1400, screen: false }));
  }, 16);
});

setTimeout(() => {
  console.log("UDP datagrams:", datagrams, "(" + parity + " parity)");
  console.log("frames reassembled over UDP:", completed);
  console.log("throughput:", ((bytes * 8) / 1e6 / 8).toFixed(2) + "Mbps");
  console.log("frames still on WebSocket:", wsFrames, "(should be ~0 once UDP takes over)");
  process.exit(0);
}, 9000);
