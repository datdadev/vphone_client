import { createConnection } from "node:net";

/**
 * Opens a fresh connection to a VM's vphone.sock, writes one JSON line,
 * reads one JSON line back, then closes -- mirrors vphone-cli's
 * VPhoneHostControl protocol exactly (one command per connection).
 */
export function sendVPhoneCommand(
  socketPath: string,
  command: Record<string, unknown>,
  timeoutMs = 15000
): Promise<Record<string, unknown>> {
  return new Promise((resolve, reject) => {
    const socket = createConnection(socketPath);
    let buffer = "";
    let settled = false;

    const finish = (fn: () => void) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      socket.destroy();
      fn();
    };

    const timer = setTimeout(() => {
      finish(() => reject(new Error("vphone.sock timed out")));
    }, timeoutMs);

    socket.on("connect", () => {
      socket.write(JSON.stringify(command) + "\n");
    });

    socket.on("data", (chunk) => {
      buffer += chunk.toString("utf8");
      const nl = buffer.indexOf("\n");
      if (nl >= 0) {
        const line = buffer.slice(0, nl);
        finish(() => {
          try {
            resolve(JSON.parse(line));
          } catch {
            reject(new Error("invalid JSON from vphone.sock"));
          }
        });
      }
    });

    socket.on("error", (err) => {
      finish(() => reject(err));
    });

    socket.on("close", () => {
      finish(() => reject(new Error("vphone.sock closed before responding")));
    });
  });
}
