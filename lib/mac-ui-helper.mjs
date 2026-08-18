import { spawn } from "node:child_process";
import fs from "node:fs";
import path from "node:path";

const DEFAULT_TIMEOUT_MS = 15_000;
const DEFAULT_MAX_BYTES = 20_000_000;

function safeChildEnv() {
  const names = ["PATH", "HOME", "TMPDIR", "USER", "LOGNAME", "LANG", "LC_ALL", "LC_CTYPE", "TERM"];
  const env = {};
  for (const name of names) {
    if (process.env[name] !== undefined) env[name] = process.env[name];
  }
  return env;
}

export function resolveMacUiHelper({ bridgeDir, explicitPath = process.env.MAC_DEV_BRIDGE_UI_HELPER } = {}) {
  const candidates = [
    explicitPath,
    bridgeDir ? path.join(bridgeDir, "bin", "MacUIHelper") : null,
    process.resourcesPath ? path.join(process.resourcesPath, "MacUIHelper") : null,
  ].filter(Boolean);
  for (const candidate of candidates) {
    try {
      fs.accessSync(candidate, fs.constants.X_OK);
      return path.resolve(candidate);
    } catch {}
  }
  return candidates.length ? path.resolve(candidates[0]) : null;
}

export function macUiHelperAvailable(helperPath) {
  if (!helperPath || process.platform !== "darwin") return false;
  try {
    fs.accessSync(helperPath, fs.constants.X_OK);
    return true;
  } catch {
    return false;
  }
}

export async function callMacUiHelper(command, payload = {}, {
  helperPath,
  timeoutMs = DEFAULT_TIMEOUT_MS,
  maxBytes = DEFAULT_MAX_BYTES,
  onSpawn = null,
  onExit = null,
} = {}) {
  if (process.platform !== "darwin") {
    const error = new Error("Mac desktop control is available only on macOS");
    error.code = "UI_UNSUPPORTED_PLATFORM";
    throw error;
  }
  if (!macUiHelperAvailable(helperPath)) {
    const error = new Error(`MacUIHelper is not built or executable: ${helperPath || "<unset>"}`);
    error.code = "UI_HELPER_UNAVAILABLE";
    throw error;
  }

  return await new Promise((resolve, reject) => {
    const child = spawn(helperPath, [command], {
      detached: true,
      stdio: ["pipe", "pipe", "pipe"],
      env: safeChildEnv(),
    });
    let stdout = Buffer.alloc(0);
    let stderr = Buffer.alloc(0);
    let settled = false;
    let timer = null;

    const appendBounded = (current, chunk, streamName) => {
      const next = Buffer.concat([current, Buffer.from(chunk)]);
      if (next.length > maxBytes) {
        const error = new Error(`MacUIHelper ${streamName} exceeded ${maxBytes} bytes`);
        error.code = "UI_HELPER_OUTPUT_TOO_LARGE";
        throw error;
      }
      return next;
    };

    const terminate = () => {
      if (!Number.isInteger(child.pid) || child.pid <= 1) return;
      try { process.kill(-child.pid, "SIGKILL"); } catch {}
      try { child.kill("SIGKILL"); } catch {}
    };

    const finish = (error, value) => {
      if (settled) return;
      settled = true;
      if (timer) clearTimeout(timer);
      try { onExit?.(child); } catch {}
      if (error) reject(error);
      else resolve(value);
    };

    child.once("spawn", () => {
      try { onSpawn?.(child); } catch {}
      try {
        child.stdin.end(`${JSON.stringify(payload ?? {})}\n`);
      } catch (error) {
        terminate();
        finish(error);
      }
    });
    child.once("error", (error) => finish(error));

    child.stdout.on("data", (chunk) => {
      try {
        stdout = appendBounded(stdout, chunk, "stdout");
      } catch (error) {
        terminate();
        finish(error);
      }
    });
    child.stderr.on("data", (chunk) => {
      try {
        stderr = appendBounded(stderr, chunk, "stderr");
      } catch (error) {
        terminate();
        finish(error);
      }
    });

    child.once("close", (code, signal) => {
      if (settled) return;
      let decoded;
      try {
        decoded = JSON.parse(stdout.toString("utf8").trim() || "{}");
      } catch (error) {
        const wrapped = new Error(`MacUIHelper returned invalid JSON (code=${code}, signal=${signal}): ${stderr.toString("utf8").slice(0, 2000)}`);
        wrapped.code = "UI_HELPER_PROTOCOL_ERROR";
        finish(wrapped);
        return;
      }
      if (decoded?.ok === true) {
        finish(null, decoded.result ?? {});
        return;
      }
      const wrapped = new Error(decoded?.error?.message || `MacUIHelper failed (code=${code}, signal=${signal})`);
      wrapped.code = decoded?.error?.code || "UI_HELPER_ERROR";
      if (stderr.length) wrapped.stderr = stderr.toString("utf8");
      finish(wrapped);
    });

    timer = setTimeout(() => {
      terminate();
      const error = new Error(`MacUIHelper '${command}' timed out after ${timeoutMs}ms`);
      error.code = "UI_HELPER_TIMEOUT";
      finish(error);
    }, timeoutMs);
    timer.unref();
  });
}
