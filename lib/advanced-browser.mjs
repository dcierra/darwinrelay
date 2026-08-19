import fs from "node:fs";
import net from "node:net";
import os from "node:os";
import path from "node:path";

const DEFAULT_TIMEOUT_MS = 8_000;
const DEFAULT_MAX_BYTES = 16_000_000;

function envTrue(value) {
  return ["1", "true", "yes", "on"].includes(String(value ?? "").trim().toLowerCase());
}

export function advancedBrowserConfig() {
  const name = String(process.env.DARWINRELAY_ADVANCED_BROWSER_NAME || "default");
  if (!/^[A-Za-z0-9_-]{1,64}$/.test(name)) {
    throw new Error("DARWINRELAY_ADVANCED_BROWSER_NAME must match [A-Za-z0-9_-]{1,64}");
  }
  const runtimeDir = process.env.DARWINRELAY_ADVANCED_BROWSER_RUNTIME_DIR
    ? path.resolve(process.env.DARWINRELAY_ADVANCED_BROWSER_RUNTIME_DIR.replace(/^~(?=$|\/)/, os.homedir()))
    : path.join(os.homedir(), ".config", "browser-harness", "runtime");
  const socketPath = process.env.DARWINRELAY_ADVANCED_BROWSER_SOCKET
    ? path.resolve(process.env.DARWINRELAY_ADVANCED_BROWSER_SOCKET.replace(/^~(?=$|\/)/, os.homedir()))
    : path.join(runtimeDir, `bu-${name}.sock`);
  return {
    enabled: envTrue(process.env.DARWINRELAY_ADVANCED_BROWSER),
    name,
    runtimeDir,
    socketPath,
  };
}

export function advancedBrowserSocketStatus(config = advancedBrowserConfig()) {
  try {
    const stat = fs.statSync(config.socketPath);
    const uid = typeof process.getuid === "function" ? process.getuid() : null;
    return {
      exists: true,
      isSocket: stat.isSocket(),
      ownerUid: stat.uid,
      ownedByCurrentUser: uid === null ? null : stat.uid === uid,
      mode: `0${(stat.mode & 0o777).toString(8)}`,
    };
  } catch (error) {
    return { exists: false, error: error?.code || String(error) };
  }
}

function validateSocket(config) {
  const status = advancedBrowserSocketStatus(config);
  if (!status.exists || !status.isSocket) {
    const error = new Error(`Browser Harness daemon socket is unavailable: ${config.socketPath}`);
    error.code = "ADVANCED_BROWSER_OFFLINE";
    throw error;
  }
  if (status.ownedByCurrentUser === false) {
    const error = new Error(`Refusing Browser Harness socket not owned by the current macOS user: ${config.socketPath}`);
    error.code = "ADVANCED_BROWSER_SOCKET_OWNER_MISMATCH";
    throw error;
  }
}

export async function advancedBrowserRequest(request, {
  config = advancedBrowserConfig(),
  timeoutMs = DEFAULT_TIMEOUT_MS,
  maxBytes = DEFAULT_MAX_BYTES,
} = {}) {
  if (!config.enabled) {
    const error = new Error("Advanced Browser/CDP backend is disabled. Set DARWINRELAY_ADVANCED_BROWSER=1 before starting DarwinRelay to opt in.");
    error.code = "ADVANCED_BROWSER_DISABLED";
    throw error;
  }
  validateSocket(config);
  return await new Promise((resolve, reject) => {
    const socket = net.createConnection({ path: config.socketPath });
    let settled = false;
    let buffer = Buffer.alloc(0);
    const finish = (error, value) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      socket.destroy();
      if (error) reject(error);
      else resolve(value);
    };
    const timer = setTimeout(() => {
      const error = new Error(`Browser Harness IPC timed out after ${timeoutMs}ms`);
      error.code = "ADVANCED_BROWSER_TIMEOUT";
      finish(error);
    }, timeoutMs);
    timer.unref();
    socket.once("error", (error) => {
      error.code = error.code || "ADVANCED_BROWSER_IPC_ERROR";
      finish(error);
    });
    socket.once("connect", () => socket.write(`${JSON.stringify(request)}\n`));
    socket.on("data", (chunk) => {
      buffer = Buffer.concat([buffer, chunk]);
      if (buffer.length > maxBytes) {
        const error = new Error(`Browser Harness IPC response exceeded ${maxBytes} bytes`);
        error.code = "ADVANCED_BROWSER_OUTPUT_TOO_LARGE";
        finish(error);
        return;
      }
      const newline = buffer.indexOf(0x0a);
      if (newline < 0) return;
      let parsed;
      try {
        parsed = JSON.parse(buffer.subarray(0, newline).toString("utf8"));
      } catch (error) {
        error.code = "ADVANCED_BROWSER_PROTOCOL_ERROR";
        finish(error);
        return;
      }
      if (parsed?.error) {
        const error = new Error(String(parsed.error));
        error.code = "ADVANCED_BROWSER_CDP_ERROR";
        finish(error);
        return;
      }
      finish(null, parsed ?? {});
    });
    socket.once("end", () => {
      if (!settled && buffer.length === 0) {
        const error = new Error("Browser Harness daemon closed IPC without a response");
        error.code = "ADVANCED_BROWSER_PROTOCOL_ERROR";
        finish(error);
      }
    });
  });
}
