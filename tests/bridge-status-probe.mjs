import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { promisify } from "node:util";
import { fileURLToPath } from "node:url";

const execFileAsync = promisify(execFile);
const ROOT = path.dirname(path.dirname(fileURLToPath(import.meta.url)));
const tempRoot = await fs.mkdtemp(path.join(os.tmpdir(), "darwinrelay-bridge-probe-"));

try {
  const { stdout, stderr } = await execFileAsync(process.execPath, [
    path.join(ROOT, "scripts", "probe-bridge-status.mjs"),
    "--stdio",
    path.join(ROOT, "bridge.mjs"),
  ], {
    timeout: 15_000,
    maxBuffer: 4_000_000,
    env: {
      ...process.env,
      DARWINRELAY_DATA_DIR: path.join(tempRoot, "data"),
      DARWINRELAY_LOG_DIR: path.join(tempRoot, "logs"),
      DARWINRELAY_FULL_ACCESS_ACK: "I_UNDERSTAND_THIS_GRANTS_FULL_ACCESS",
      // Must be scrubbed by the probe helper: doctor must not start configured
      // federation children merely to read bridge_status.
      DARWINRELAY_MCP_SERVERS_JSON: JSON.stringify({
        providers: [{ key: "should-not-start", command: "/definitely/missing/provider", args: [] }],
      }),
    },
  });
  assert.equal(stderr, "", `probe wrote stderr: ${stderr}`);
  const status = JSON.parse(stdout);
  const pkg = JSON.parse(await fs.readFile(path.join(ROOT, "package.json"), "utf8"));
  assert.equal(status.bridgeVersion, pkg.version);
  assert.equal(status.fullAccessUnlocked, true);
  assert.equal(status.federation.configured, 0, "stdio doctor probe inherited federation config");
  assert.equal(status.auditMode, "off", "stdio doctor probe should not add audit noise");

  await assert.rejects(
    execFileAsync(process.execPath, [path.join(ROOT, "scripts", "probe-bridge-status.mjs"), "--stdio", path.join(ROOT, "bridge.mjs"), "--tool", "shell_exec"], { timeout: 15_000 }),
    (error) => error?.code === 64 && String(error.stderr || "").includes("--tool must be bridge_status or ui_status"),
    "runtime probe must reject mutation-capable tools",
  );
  console.log("bridge status stdio probe test passed");
} finally {
  await fs.rm(tempRoot, { recursive: true, force: true });
}
