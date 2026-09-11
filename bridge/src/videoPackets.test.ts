import {
  fragmentFrame, readHeader, FrameType, HEADER_BYTES, FRAGMENT_PAYLOAD, FEC_GROUP_SIZE,
} from "./videoPackets.js";

/** Mirrors the client reassembler, so FEC recovery is tested by actually losing packets. */
function reassemble(packets: Buffer[]): Buffer | null {
  const data = new Map<number, Buffer>();
  const parity = new Map<number, Buffer>();
  let meta: ReturnType<typeof readHeader> = null;

  for (const p of packets) {
    const h = readHeader(p);
    if (!h) continue;
    meta = h;
    const body = p.subarray(HEADER_BYTES);
    if (h.isParity) parity.set(h.groupIndex, body);
    else data.set(h.fragIndex, body);
  }
  if (!meta) return null;

  // Recover any group missing exactly one data fragment.
  const groups = Math.ceil(meta.fragCount / FEC_GROUP_SIZE);
  for (let g = 0; g < groups; g++) {
    const first = g * FEC_GROUP_SIZE;
    const last = Math.min(first + FEC_GROUP_SIZE, meta.fragCount);
    const missing: number[] = [];
    for (let i = first; i < last; i++) if (!data.has(i)) missing.push(i);
    if (missing.length !== 1) continue;
    const par = parity.get(g);
    if (!par) continue;
    const recovered = Buffer.from(par);
    for (let i = first; i < last; i++) {
      if (i === missing[0]) continue;
      const src = data.get(i)!;
      for (let b = 0; b < FRAGMENT_PAYLOAD; b++) recovered[b] ^= src[b];
    }
    data.set(missing[0], recovered);
  }

  for (let i = 0; i < meta.fragCount; i++) if (!data.has(i)) return null;
  const out = Buffer.alloc(meta.fragCount * FRAGMENT_PAYLOAD);
  for (let i = 0; i < meta.fragCount; i++) data.get(i)!.copy(out, i * FRAGMENT_PAYLOAD);
  return out.subarray(0, meta.frameLen);
}

const frame = Buffer.alloc(76_000);
for (let i = 0; i < frame.length; i++) frame[i] = (i * 31 + 7) & 0xff;
const packets = fragmentFrame(frame, 42, FrameType.keyFrame, 1234567890);
const dataCount = packets.filter((p) => !readHeader(p)!.isParity).length;
const parityCount = packets.length - dataCount;

console.log(`frame ${frame.length}B -> ${dataCount} data + ${parityCount} parity`);
console.log("overhead:", ((parityCount / dataCount) * 100).toFixed(1) + "%");

const intact = reassemble(packets);
console.log("lossless reassembly:", intact?.equals(frame));

// Drop one data fragment per group: FEC should recover all of them.
const oneEach = packets.filter((p) => {
  const h = readHeader(p)!;
  return h.isParity || h.fragIndex % FEC_GROUP_SIZE !== 3;
});
console.log(
  `dropped ${packets.length - oneEach.length} fragments (1 per group), recovered:`,
  reassemble(oneEach)?.equals(frame)
);

// Two losses in one group is beyond single-parity XOR: must fail, not corrupt.
const twoInGroup = packets.filter((p) => {
  const h = readHeader(p)!;
  return h.isParity || (h.fragIndex !== 2 && h.fragIndex !== 3);
});
const broken = reassemble(twoInGroup);
console.log("two losses in one group ->", broken === null ? "unrecoverable (correct)" : "WRONGLY CLAIMED OK");

// A tiny frame has no parity to add; it must still round-trip.
const small = Buffer.from("a single small delta frame");
const smallPackets = fragmentFrame(small, 7, FrameType.deltaFrame, 1);
console.log("single-fragment frame round-trips:", reassemble(smallPackets)?.equals(small));
