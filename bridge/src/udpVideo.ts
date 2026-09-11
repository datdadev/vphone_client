import { createSocket, type Socket as UdpSocket, type RemoteInfo } from "node:dgram";
import { fragmentFrame, type FrameTypeValue } from "./videoPackets.js";

/**
 * UDP transport for video frames.
 *
 * The client dials *out* to this socket and identifies itself with a hello
 * datagram; we then stream to whatever source address that hello arrived from.
 * That direction matters: it means the phone never has to be reachable, so
 * this works behind NAT and on cellular without port forwarding.
 *
 * Sessions expire if the hello stops arriving, and callers fall back to the
 * WebSocket path — UDP is blocked outright on some networks.
 */
export class UdpVideoServer {
  private socket?: UdpSocket;
  private readonly sessions = new Map<string, { address: string; port: number; lastSeen: number }>();

  constructor(private readonly port: number) {}

  start(): void {
    const socket = createSocket("udp4");
    socket.on("message", (message, remote) => this.handleHello(message, remote));
    socket.on("error", (err) => console.log(`[udp] socket error: ${err.message}`));
    socket.bind(this.port, () => {
      console.log(`[udp] video transport listening on ${this.port}`);
    });
    this.socket = socket;
  }

  stop(): void {
    this.socket?.close();
    this.socket = undefined;
  }

  private handleHello(message: Buffer, remote: RemoteInfo): void {
    // "VPHONE1 <sessionId>"
    const text = message.toString("utf8", 0, Math.min(message.length, 128));
    if (!text.startsWith("VPHONE1 ")) return;
    const sessionId = text.slice(8).trim();
    if (!sessionId) return;

    const known = this.sessions.get(sessionId);
    if (!known) {
      console.log(`[udp] session ${sessionId.slice(0, 8)} from ${remote.address}:${remote.port}`);
    }
    this.sessions.set(sessionId, {
      address: remote.address,
      port: remote.port,
      lastSeen: Date.now(),
    });
    // Echo so the client knows the path works and can stop falling back. The
    // client filters these by their "VPHONE1" prefix -- video packets never
    // start with it.
    this.socket?.send(message, remote.port, remote.address);
  }

  /** True while the client's hellos are still arriving. */
  isActive(sessionId: string, timeoutMs = 4000): boolean {
    const session = this.sessions.get(sessionId);
    return session !== undefined && Date.now() - session.lastSeen < timeoutMs;
  }

  forget(sessionId: string): void {
    this.sessions.delete(sessionId);
  }

  /** @returns bytes sent, or 0 if the session isn't reachable. */
  send(
    sessionId: string,
    frame: Buffer,
    frameSeq: number,
    frameType: FrameTypeValue,
    captureMs: number
  ): number {
    const session = this.sessions.get(sessionId);
    const socket = this.socket;
    if (!session || !socket) return 0;

    let sent = 0;
    for (const datagram of fragmentFrame(frame, frameSeq, frameType, captureMs)) {
      socket.send(datagram, session.port, session.address);
      sent += datagram.length;
    }
    return sent;
  }
}
