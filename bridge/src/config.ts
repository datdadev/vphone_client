import { randomBytes } from "node:crypto";
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

export interface BridgeConfig {
  port: number;
  token: string;
  vmName: string;
  vphoneCliBin: string;
  vmsRoot: string;
  /// Logs arrival cadence of touch events for latency diagnosis.
  logInput?: boolean;
}

const CONFIG_DIR = join(homedir(), ".vphone-bridge");
const CONFIG_PATH = join(CONFIG_DIR, "config.json");

const DEFAULTS: Omit<BridgeConfig, "token"> = {
  port: 8787,
  vmName: "vphone",
  vphoneCliBin: "/Applications/vphone-cli.app/Contents/MacOS/vphone-cli",
  vmsRoot: join(homedir(), ".vphone", "VMs"),
  logInput: true,
};

export function loadConfig(): BridgeConfig {
  if (existsSync(CONFIG_PATH)) {
    const raw = JSON.parse(readFileSync(CONFIG_PATH, "utf8"));
    return { ...DEFAULTS, ...raw };
  }

  mkdirSync(CONFIG_DIR, { recursive: true });
  const config: BridgeConfig = { ...DEFAULTS, token: randomBytes(24).toString("hex") };
  writeFileSync(CONFIG_PATH, JSON.stringify(config, null, 2) + "\n");
  console.log(`[config] wrote new config with generated token to ${CONFIG_PATH}`);
  return config;
}

export function socketPathFor(config: BridgeConfig, vmName: string): string {
  return join(config.vmsRoot, vmName, "vphone.sock");
}
