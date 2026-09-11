import { createConnection, type Socket } from "node:net";
import type { WebSocket } from "ws";
import { CongestionControl } from "./congestionControl.js";
import type { UdpVideoServer } from "./udpVideo.js";
import { FrameType, type FrameTypeValue } from "./videoPackets.js";

/**
 * Bridges the host's HEVC video stream to a WebSocket client.
 *
 * Unlike every other command, this holds a dedicated Unix socket open for the
 * life of the WS connection. The host frames packets as
 * [4-byte BE length][1-byte type][payload]; we strip the length prefix and
 * forward `[type][payload]` as a single binary WS message, since WebSocket
 * already preserves message boundaries.
 */
/// ~3 frames at typical size; beyond this the client is not keeping up.
const MAX_BUFFERED_BYTES = 48 * 1024;

export function startVideoStream(
  ws: WebSocket,
  socketPath: string,
  request: Record<string, unknown>,
  vmName: string,
  udp?: { server: UdpVideoServer; sessionId: string }
): Socket {
  const socket = createConnection(socketPath);
  let buffer = Buffer.alloc(0);
  let handshakeDone = false;
  let dropped = 0;
  let frameSeq = 0;
  let lastTransport: "udp" | "ws" | null = null;

  const requestedBitrate = typeof request.bitrate === "number" ? request.bitrate : 12_000_000;
  const congestion = new CongestionControl(socketPath, vmName, {
    min: 1_000_000,
    max: requestedBitrate,
    start: requestedBitrate,
    backlogBytes: MAX_BUFFERED_BYTES,
  });

  const reportTimer = setInterval(() => {
    void congestion.tick(ws, dropped).then((changed) => {
      if (changed !== null) {
        console.log(
          `[video] bitrate -> ${(changed / 1e6).toFixed(1)}Mbps` +
            (dropped > 0 ? ` (dropped ${dropped})` : "")
        );
      }
      dropped = 0;
    });
  }, 1000);

  socket.on("connect", () => {
    socket.setNoDelay(true);
    socket.write(JSON.stringify(request) + "\n");
  });

  socket.on("data", (chunk: Buffer) => {
    buffer = Buffer.concat([buffer, chunk]);

    if (!handshakeDone) {
      const newline = buffer.indexOf(0x0a);
      if (newline < 0) return;
      const line = buffer.subarray(0, newline).toString("utf8");
      buffer = buffer.subarray(newline + 1);
      handshakeDone = true;
      // Carries video dimensions + the touch coordinate space.
      ws.send(line);
    }

    while (buffer.length >= 4) {
      const length = buffer.readUInt32BE(0);
      if (buffer.length < 4 + length) break;
      const payload = buffer.subarray(4, 4 + length);
      buffer = buffer.subarray(4 + length);

      const frameType = (payload.length > 0 ? payload[0] : 3) as FrameTypeValue;
      frameSeq++;

      // Prefer UDP: a lost packet there is a hole FEC usually fills, where on
      // TCP it stalls everything behind it while it retransmits data that's
      // already stale by the time it lands.
      if (udp?.server.isActive(udp.sessionId)) {
        if (lastTransport !== "udp") {
          console.log("[video] transport: UDP");
          lastTransport = "udp";
        }
        const captureMs = payload.length >= 9 ? Number(payload.readBigUInt64BE(1)) : Date.now();
        // The host's own framing is stripped; UDP carries its own header.
        udp.server.send(udp.sessionId, payload.subarray(9), frameSeq, frameType, captureMs);
        continue;
      }

      if (lastTransport !== "ws") {
        console.log("[video] transport: WebSocket" + (udp ? " (UDP unavailable)" : ""));
        lastTransport = "ws";
      }

      // Backpressure toward the phone. Without this, frames the client can't
      // drain pile up in the socket's send buffer: the picture stays smooth but
      // drifts steadily into the past. Delta frames are droppable; parameter
      // sets and keyframes are not, since losing them breaks decoding.
      const isDroppable = frameType === FrameType.deltaFrame;
      if (isDroppable && ws.bufferedAmount > MAX_BUFFERED_BYTES) {
        dropped++;
        continue;
      }
      ws.send(payload, { binary: true });
    }
  });

  socket.on("error", (err) => {
    ws.send(JSON.stringify({ ok: false, t: "videoStream", error: String(err.message) }));
  });

  socket.on("close", () => {
    clearInterval(reportTimer);
    if (ws.readyState === ws.OPEN) {
      ws.send(JSON.stringify({ ok: false, t: "videoStream", error: "stream ended" }));
    }
  });

  return socket;
}
