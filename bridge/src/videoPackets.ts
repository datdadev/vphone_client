/**
 * Fragmentation and forward error correction for UDP video.
 *
 * TCP turns a single lost packet into a head-of-line stall while it
 * retransmits, which for live video means a freeze delivering data that's
 * already stale. Over UDP a loss is just a hole, and FEC fills most holes
 * without anyone having to ask for anything.
 *
 * Datagram layout (header 23 bytes, all integers big-endian):
 *
 *   frameSeq   4   frame this fragment belongs to
 *   fragIndex  2   position within the frame (data fragments first)
 *   fragCount  2   number of DATA fragments in the frame
 *   groupIndex 2   FEC group, for parity fragments
 *   flags      1   bit0 parity, bits1-2 frame type
 *   frameLen   4   total encoded frame size, so the tail fragment's real
 *                  length is known despite padding
 *   captureMs  8   host capture time, for latency measurement
 *
 * Payload is a fixed FRAGMENT_PAYLOAD bytes, zero-padded, because XOR parity
 * requires equal-length blocks.
 */

export const HEADER_BYTES = 23;
/** Conservative enough to avoid IP fragmentation on typical internet paths. */
export const FRAGMENT_PAYLOAD = 1100;
/** One parity fragment per this many data fragments (~10% overhead). */
export const FEC_GROUP_SIZE = 10;
/** Smaller groups, so ~25% overhead, for frames worth protecting harder. */
export const FEC_GROUP_SIZE_CRITICAL = 4;

export const FrameType = { parameterSets: 1, keyFrame: 2, deltaFrame: 3 } as const;
export type FrameTypeValue = (typeof FrameType)[keyof typeof FrameType];

/**
 * Losing a delta frame costs one glitched frame; losing a keyframe or the
 * parameter sets freezes the picture until a replacement round-trips from the
 * host. Keyframes are also the biggest frames, so they span the most groups
 * and are the likeliest to take two hits in one -- exactly what single-parity
 * XOR can't fix. Protecting them harder costs little: they're roughly one
 * frame in sixty, so the extra parity is a couple of percent of the stream.
 *
 * Derived from the frame type rather than signalled, so the receiver computes
 * the same value from the header it already reads. No protocol change.
 */
export function fecGroupSize(frameType: FrameTypeValue): number {
  return frameType === FrameType.deltaFrame ? FEC_GROUP_SIZE : FEC_GROUP_SIZE_CRITICAL;
}

export interface PacketHeader {
  frameSeq: number;
  fragIndex: number;
  fragCount: number;
  groupIndex: number;
  isParity: boolean;
  frameType: FrameTypeValue;
  frameLen: number;
  captureMs: number;
}

export function writeHeader(header: PacketHeader, into: Buffer): void {
  into.writeUInt32BE(header.frameSeq, 0);
  into.writeUInt16BE(header.fragIndex, 4);
  into.writeUInt16BE(header.fragCount, 6);
  into.writeUInt16BE(header.groupIndex, 8);
  into.writeUInt8((header.isParity ? 1 : 0) | (header.frameType << 1), 10);
  into.writeUInt32BE(header.frameLen, 11);
  into.writeBigUInt64BE(BigInt(header.captureMs), 15);
}

export function readHeader(packet: Buffer): PacketHeader | null {
  if (packet.length < HEADER_BYTES) return null;
  const flags = packet.readUInt8(10);
  return {
    frameSeq: packet.readUInt32BE(0),
    fragIndex: packet.readUInt16BE(4),
    fragCount: packet.readUInt16BE(6),
    groupIndex: packet.readUInt16BE(8),
    isParity: (flags & 1) === 1,
    frameType: ((flags >> 1) & 0x3) as FrameTypeValue,
    frameLen: packet.readUInt32BE(11),
    captureMs: Number(packet.readBigUInt64BE(15)),
  };
}

/**
 * Splits an encoded frame into datagrams, appending an XOR parity fragment per
 * group. A single loss within a group is then recoverable by the receiver
 * without a retransmit or a keyframe request.
 */
export function fragmentFrame(
  frame: Buffer,
  frameSeq: number,
  frameType: FrameTypeValue,
  captureMs: number
): Buffer[] {
  const fragCount = Math.max(1, Math.ceil(frame.length / FRAGMENT_PAYLOAD));
  const groupSize = fecGroupSize(frameType);
  const datagrams: Buffer[] = [];

  for (let index = 0; index < fragCount; index++) {
    const packet = Buffer.alloc(HEADER_BYTES + FRAGMENT_PAYLOAD);
    writeHeader(
      {
        frameSeq,
        fragIndex: index,
        fragCount,
        groupIndex: Math.floor(index / groupSize),
        isParity: false,
        frameType,
        frameLen: frame.length,
        captureMs,
      },
      packet
    );
    frame.copy(packet, HEADER_BYTES, index * FRAGMENT_PAYLOAD,
      Math.min((index + 1) * FRAGMENT_PAYLOAD, frame.length));
    datagrams.push(packet);
  }

  const groupCount = Math.ceil(fragCount / groupSize);
  for (let group = 0; group < groupCount; group++) {
    const first = group * groupSize;
    const last = Math.min(first + groupSize, fragCount);
    // A one-fragment group has nothing to protect it with: parity would just
    // duplicate the fragment, which costs as much as sending it twice.
    if (last - first < 2) continue;

    const parity = Buffer.alloc(HEADER_BYTES + FRAGMENT_PAYLOAD);
    writeHeader(
      {
        frameSeq,
        fragIndex: group,
        fragCount,
        groupIndex: group,
        isParity: true,
        frameType,
        frameLen: frame.length,
        captureMs,
      },
      parity
    );
    for (let index = first; index < last; index++) {
      const source = datagrams[index];
      for (let byte = 0; byte < FRAGMENT_PAYLOAD; byte++) {
        parity[HEADER_BYTES + byte] ^= source[HEADER_BYTES + byte];
      }
    }
    datagrams.push(parity);
  }

  return datagrams;
}
