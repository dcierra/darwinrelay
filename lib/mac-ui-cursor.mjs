import { spawn } from "node:child_process";
import fs from "node:fs";
import path from "node:path";

function safeChildEnv() {
  const names = ["PATH", "HOME", "TMPDIR", "USER", "LOGNAME", "LANG", "LC_ALL", "LC_CTYPE", "TERM"];
  const env = {};
  for (const name of names) if (process.env[name] !== undefined) env[name] = process.env[name];
  return env;
}

export function resolveMacUiCursor({ bridgeDir, explicitPath = process.env.MAC_DEV_BRIDGE_UI_CURSOR_HELPER } = {}) {
  const candidates = [explicitPath, bridgeDir ? path.join(bridgeDir, "bin", "MacUICursorOverlay") : null].filter(Boolean);
  for (const candidate of candidates) {
    try {
      fs.accessSync(candidate, fs.constants.X_OK);
      return path.resolve(candidate);
    } catch {}
  }
  return candidates.length ? path.resolve(candidates[0]) : null;
}

export function macUiCursorAvailable(cursorPath) {
  if (!cursorPath || process.platform !== "darwin") return false;
  try {
    fs.accessSync(cursorPath, fs.constants.X_OK);
    return true;
  } catch {
    return false;
  }
}

export class MacUiCursor {
  constructor(cursorPath) {
    this.cursorPath = cursorPath;
    this.child = null;
    this.stderr = "";
  }

  get running() {
    return Boolean(this.child && this.child.exitCode === null && this.child.signalCode === null);
  }

  ensureStarted() {
    if (this.running) return this.child;
    if (!macUiCursorAvailable(this.cursorPath)) {
      const error = new Error(`MacUICursorOverlay is not built or executable: ${this.cursorPath || "<unset>"}`);
      error.code = "UI_CURSOR_HELPER_UNAVAILABLE";
      throw error;
    }
    const child = spawn(this.cursorPath, [], {
      detached: true,
      stdio: ["pipe", "ignore", "pipe"],
      env: safeChildEnv(),
    });
    this.child = child;
    this.stderr = "";
    child.stderr.on("data", (chunk) => {
      this.stderr = `${this.stderr}${chunk}`.slice(-8_192);
    });
    child.once("close", () => {
      if (this.child === child) this.child = null;
    });
    child.once("error", () => {
      if (this.child === child) this.child = null;
    });
    return child;
  }

  send(command, { start = true } = {}) {
    const child = start ? this.ensureStarted() : this.child;
    if (!child || !this.running || !child.stdin?.writable) return false;
    child.stdin.write(`${JSON.stringify(command)}\n`);
    return true;
  }

  stop() {
    const child = this.child;
    this.child = null;
    if (!child) return;
    try {
      if (child.stdin?.writable) child.stdin.end(`${JSON.stringify({ action: "quit" })}\n`);
    } catch {}
    if (Number.isInteger(child.pid) && child.pid > 1) {
      try { process.kill(-child.pid, "SIGKILL"); } catch {}
    }
    try { child.kill("SIGKILL"); } catch {}
  }
}
