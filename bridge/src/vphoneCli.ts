import { execFile } from "node:child_process";
import { promisify } from "node:util";

const execFileAsync = promisify(execFile);

export async function listVMs(vphoneCliBin: string): Promise<unknown> {
  const { stdout } = await execFileAsync(vphoneCliBin, ["vm", "list", "--json"]);
  return JSON.parse(stdout);
}

export async function vmInfo(vphoneCliBin: string, name: string): Promise<unknown> {
  const { stdout } = await execFileAsync(vphoneCliBin, ["vm", "info", name, "--json"]);
  return JSON.parse(stdout);
}
