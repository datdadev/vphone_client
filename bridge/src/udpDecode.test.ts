import dgram from "node:dgram";
import WebSocket from "ws";
import { readFileSync, createWriteStream } from "node:fs";
import { readHeader, HEADER_BYTES } from "./videoPackets.js";

// Reassemble over UDP AND decode, so corrupt-but-well-framed data can't pass.
const token = JSON.parse(readFileSync(process.env.HOME + "/.vphone-bridge/config.json", "utf8")).token;
const sessionId = "decode-" + Date.now();
const udp = dgram.createSocket("udp4");
const out = createWriteStream("/tmp/udp-stream.h265");
const START = Buffer.from([0, 0, 0, 1]);

const frames = new Map<number, { frags: Map<number, Buffer>; count: number; len: number; type: number }>();
let params: Buffer | null = null;
let written = 0;

function emit(type: number, frame: Buffer) {
  if (type === 1) {
    const count = frame[0];
    let off = 1; const bufs: Buffer[] = [];
    for (let i = 0; i < count; i++) {
      const len = frame.readUInt32BE(off); off += 4;
      bufs.push(START, frame.subarray(off, off + len)); off += len;
    }
    params = Buffer.concat(bufs);
    return;
  }
  if (!params) return;
  if (written === 0 && type !== 2) return;
  let off = 0; const bufs: Buffer[] = [];
  if (written === 0) bufs.push(params);
  while (off + 4 <= frame.length) {
    const len = frame.readUInt32BE(off); off += 4;
    bufs.push(START, frame.subarray(off, off + len)); off += len;
  }
  out.write(Buffer.concat(bufs)); written++;
}

udp.on("message", (msg) => {
  const h = readHeader(msg);
  if (!h || h.isParity) return;
  let e = frames.get(h.frameSeq);
  if (!e) { e = { frags: new Map(), count: h.fragCount, len: h.frameLen, type: h.frameType }; frames.set(h.frameSeq, e); }
  e.frags.set(h.fragIndex, msg.subarray(HEADER_BYTES));
  if (e.frags.size === e.count) {
    const full = Buffer.concat(Array.from({ length: e.count }, (_, i) => e!.frags.get(i)!)).subarray(0, e.len);
    emit(e.type, full);
    frames.delete(h.frameSeq);
  }
});
udp.bind(0, () => {
  const hello = Buffer.from("VPHONE1 " + sessionId);
  udp.send(hello, 8788, "127.0.0.1");
  setInterval(() => udp.send(hello, 8788, "127.0.0.1"), 500);
});

const ws = new WebSocket("ws://localhost:8787?token=" + token);
ws.on("open", () => ws.send(JSON.stringify({
  t: "videoStream", fps: 60, scale: 1, bitrate: 12000000, udpSession: sessionId })));

const ctl = new WebSocket("ws://localhost:8787?token=" + token);
ctl.on("open", () => { let x = 60, dir = 1;
  ctl.send(JSON.stringify({ t: "touch", phase: "down", x, y: 1400, screen: false }));
  setInterval(() => { x += dir * 70; if (x < 60 || x > 900) dir = -dir;
    ctl.send(JSON.stringify({ t: "touch", phase: "move", x, y: 1400, screen: false })); }, 16); });

setTimeout(() => { out.end(() => { console.log("frames written to elementary stream:", written); process.exit(0); }); }, 9000);
