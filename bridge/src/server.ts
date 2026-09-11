import { WebSocketServer } from "ws";
import { loadConfig, socketPathFor } from "./config.js";
import { listVMs, vmInfo } from "./vphoneCli.js";
import { sendVPhoneCommand } from "./vphoneSocket.js";
import { startVideoStream } from "./videoStream.js";
import { UdpVideoServer } from "./udpVideo.js";

const config = loadConfig();

const RAW_SOCKET_COMMANDS = new Set([
  "screenshot", "tap", "swipe", "key", "type", "typeText", "requestKeyFrame", "setBitrate",
  // Live single-finger drag and simultaneous multi-finger (pinch) primitives.
  "touch", "multiTouch",
]);

// perMessageDeflate off: frames are already-compressed JPEG bytes, and the
// touch/status messages are tiny -- compression here only adds CPU latency
// for no size win.
const wss = new WebSocketServer({ port: config.port, perMessageDeflate: false });

// Video moves over UDP when the client can reach it; the port is the control
// port + 1 so only one number has to be configured.
const udpServer = new UdpVideoServer(config.port + 1);
udpServer.start();

console.log(`[bridge] listening on ws://0.0.0.0:${config.port}`);
console.log(`[bridge] udp video on ${config.port + 1}`);
console.log(`[bridge] default VM: ${config.vmName}`);
console.log(`[bridge] token: ${config.token}`);

wss.on("connection", (ws, req) => {
  const url = new URL(req.url ?? "/", "http://localhost");
  const token = url.searchParams.get("token") ?? req.headers["x-vphone-token"];

  if (token !== config.token) {
    ws.close(4001, "unauthorized");
    return;
  }

  // Disable Nagle's algorithm: without this, small frequent packets (touch-move
  // events during a scroll) can sit buffered for tens of ms before the OS
  // flushes them, which shows up as input lag despite the app sending instantly.
  req.socket.setNoDelay(true);

  console.log(`[bridge] client connected from ${req.socket.remoteAddress}`);

  // Held open for the life of this WS connection; closing it tells the host to
  // drop this subscriber (and stop encoding when the last one leaves).
  let videoSocket: import("node:net").Socket | undefined;
  let udpSessionId: string | undefined;
  let lastInputAt = 0;

  ws.on("message", async (raw) => {
    let msg: Record<string, unknown>;
    try {
      msg = JSON.parse(raw.toString());
    } catch {
      ws.send(JSON.stringify({ ok: false, error: "invalid JSON" }));
      return;
    }

    const type = msg.t as string | undefined;
    const vmName = (msg.vm as string | undefined) ?? config.vmName;

    // Input timing instrumentation: arrival cadence of touch events reveals
    // whether the phone->host path is smooth or arriving in stalled bursts.
    if (config.logInput && (type === "touch" || type === "multiTouch")) {
      const now = Date.now();
      const delta = lastInputAt ? now - lastInputAt : 0;
      lastInputAt = now;
      const phase = (msg.phase as string) ??
        ((msg.touches as Array<{ phase?: string }> | undefined)?.[0]?.phase ?? "?");
      const clientTs = typeof msg.ts === "number" ? msg.ts : undefined;
      const skew = clientTs !== undefined ? ` clientDelta=${(now - clientTs).toFixed(0)}ms` : "";
      console.log(`[input] ${type}/${phase} +${String(delta).padStart(4)}ms${skew}`);
    }

    try {
      if (type === "list_vms") {
        ws.send(JSON.stringify({ ok: true, t: "list_vms", vms: await listVMs(config.vphoneCliBin) }));
        return;
      }

      // Answered immediately, before any VM work: isolates pure client<->bridge
      // network round-trip from host-side processing time.
      if (type === "ping") {
        ws.send(JSON.stringify({ ok: true, t: "pong", ts: msg.ts }));
        return;
      }

      if (type === "videoStream") {
        videoSocket?.destroy();
        const sessionId = typeof msg.udpSession === "string" ? msg.udpSession : undefined;
        videoSocket = startVideoStream(
          ws, socketPathFor(config, vmName), msg, vmName,
          sessionId ? { server: udpServer, sessionId } : undefined
        );
        if (sessionId) udpSessionId = sessionId;
        return;
      }

      if (type === "vm_info") {
        ws.send(JSON.stringify({ ok: true, t: "vm_info", info: await vmInfo(config.vphoneCliBin, vmName) }));
        return;
      }

      if (type && RAW_SOCKET_COMMANDS.has(type)) {
        const socketPath = socketPathFor(config, vmName);
        const hostStart = Date.now();
        const response = await sendVPhoneCommand(socketPath, msg);
        const hostMs = Date.now() - hostStart;
        // Isolates host-side injection time from network transit.
        if (config.logInput && (type === "touch" || type === "multiTouch") && hostMs > 5) {
          console.log(`[host] ${type} injection took ${hostMs}ms`);
        }

        // Frames are the hot path for the live-view stream: send the JPEG as a
        // raw binary WS frame (no base64 in either direction) preceded by a
        // small JSON status frame, instead of embedding base64 in the JSON.
        const { image, ...status } = response as { image?: string; [k: string]: unknown };
        ws.send(JSON.stringify({ ...status, t: type, hasImage: Boolean(image) }));
        if (image) {
          ws.send(Buffer.from(image, "base64"), { binary: true });
        }
        return;
      }

      ws.send(JSON.stringify({ ok: false, error: `unknown command: ${type}` }));
    } catch (err) {
      ws.send(JSON.stringify({ ok: false, t: type, error: String((err as Error).message ?? err) }));
    }
  });

  ws.on("close", () => {
    videoSocket?.destroy();
    videoSocket = undefined;
    if (udpSessionId) udpServer.forget(udpSessionId);
    console.log("[bridge] client disconnected");
  });
});
