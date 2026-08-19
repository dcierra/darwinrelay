import { spawn } from "node:child_process";
import assert from "node:assert/strict";
import fs from "node:fs/promises";
import net from "node:net";
import os from "node:os";
import path from "node:path";
import readline from "node:readline";
import { fileURLToPath } from "node:url";

if (process.platform !== "darwin") {
  console.log("advanced-browser: skipped (not macOS)");
  process.exit(0);
}

const here = path.dirname(fileURLToPath(import.meta.url));
const bridgePath = path.resolve(here, "..", "bridge.mjs");
const tempRoot = await fs.mkdtemp(path.join(os.tmpdir(), "dr-adv-"));
const dataDir = path.join(tempRoot, "data");
const logDir = path.join(tempRoot, "logs");
const socketPath = path.join(tempRoot, "browser-harness.sock");
assert.ok(Buffer.byteLength(socketPath) < 100, `Unix-domain socket path must stay short on macOS: ${socketPath}`);
const settingsFile = path.join(dataDir, "settings.json");
const auditFile = path.join(logDir, "audit.jsonl");
await fs.mkdir(dataDir, { recursive: true });
await fs.mkdir(logDir, { recursive: true });

const requests = [];
let selected = { target_id: "target-1", session_id: "session-1" };
const server = net.createServer((socket) => {
  let raw = "";
  socket.setEncoding("utf8");
  socket.on("data", (chunk) => {
    raw += chunk;
    const newline = raw.indexOf("\n");
    if (newline < 0) return;
    const request = JSON.parse(raw.slice(0, newline));
    requests.push(request);
    let response;
    if (request.meta === "ping") response = { pong: true, pid: 999, browser_kind: "local" };
    else if (request.meta === "connection_status") response = { target_id: selected.target_id, session_id: selected.session_id, page: { targetId: selected.target_id, title: "Fixture", url: "https://example.test/" } };
    else if (request.meta === "current_tab") response = { targetId: selected.target_id, title: "Fixture", url: "https://example.test/" };
    else if (request.meta === "session") response = { session_id: selected.session_id };
    else if (request.meta === "set_session") { selected = { target_id: request.target_id, session_id: request.session_id }; response = { session_id: selected.session_id }; }
    else if (request.meta === "drain_events") response = { events: [{ method: "Network.loadingFinished", params: { requestId: "1" }, session_id: selected.session_id }] };
    else if (request.method) response = { result: { method: request.method, params: request.params ?? {}, session_id: request.session_id ?? selected.session_id } };
    else response = { error: "unknown request" };
    socket.end(`${JSON.stringify(response)}\n`);
  });
});
await new Promise((resolve, reject) => {
  server.once("error", reject);
  server.listen(socketPath, resolve);
});

const child = spawn(process.execPath, [bridgePath], {
  stdio: ["pipe", "pipe", "pipe"],
  env: {
    ...process.env,
    DARWINRELAY_DATA_DIR: dataDir,
    DARWINRELAY_LOG_DIR: logDir,
    DARWINRELAY_AUDIT_MODE: "full",
    DARWINRELAY_AUDIT_LOG: auditFile,
    DARWINRELAY_FULL_ACCESS_ACK: "I_UNDERSTAND_THIS_GRANTS_FULL_ACCESS",
    DARWINRELAY_ADVANCED_BROWSER: "1",
    DARWINRELAY_ADVANCED_BROWSER_SOCKET: socketPath,
    DARWINRELAY_ADVANCED_BROWSER_NAME: "test",
  },
});
const rl = readline.createInterface({ input: child.stdout });
const pending = new Map();
let stderr = "";
child.stderr.on("data", (chunk) => { stderr += chunk.toString("utf8"); });
rl.on("line", (line) => {
  const message = JSON.parse(line);
  const resolve = pending.get(message.id);
  if (resolve) { pending.delete(message.id); resolve(message); }
});

function request(id, method, params = {}) {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => { pending.delete(id); reject(new Error(`timeout ${id}; stderr=${stderr}`)); }, 10_000);
    pending.set(id, (message) => { clearTimeout(timer); resolve(message); });
    child.stdin.write(`${JSON.stringify({ jsonrpc: "2.0", id, method, params })}\n`);
  });
}
const meta = {
  "io.modelcontextprotocol/protocolVersion": "2026-07-28",
  "io.modelcontextprotocol/clientInfo": { name: "advanced-browser-test", version: "1" },
  "io.modelcontextprotocol/clientCapabilities": {},
};
async function tool(id, name, args = {}) { return await request(id, "tools/call", { _meta: meta, name, arguments: args }); }
function structured(response) {
  assert.equal(response.result?.resultType, "complete", JSON.stringify(response));
  assert.equal(response.result?.isError, false, JSON.stringify(response));
  return response.result.structuredContent;
}

try {
  const listed = await request("tools", "tools/list", { _meta: meta });
  const names = new Set(listed.result.tools.map((tool) => tool.name));
  for (const name of ["browser_cdp_status", "browser_cdp_call", "browser_cdp_session", "browser_cdp_events"]) assert.ok(names.has(name), `missing ${name}`);

  const status = structured(await tool("status", "browser_cdp_status"));
  assert.equal(status.enabled, true);
  assert.equal(status.strictBlocked, false);
  assert.equal(status.socket.isSocket, true);
  assert.equal(status.connection.page.url, "https://example.test/");

  const called = structured(await tool("call", "browser_cdp_call", { method: "Runtime.evaluate", params: { expression: "ADVANCED_BROWSER_SECRET" }, session_id: "session-1" }));
  assert.equal(called.result.method, "Runtime.evaluate");
  assert.equal(called.result.params.expression, "ADVANCED_BROWSER_SECRET");
  assert.equal(called._advancedBrowser.managedChromeUnchanged, true);

  const current = structured(await tool("current", "browser_cdp_session", { action: "current" }));
  assert.equal(current.url, "https://example.test/");
  const changed = structured(await tool("set", "browser_cdp_session", { action: "set", target_id: "target-2", session_id: "session-2" }));
  assert.equal(changed.session_id, "session-2");
  const events = structured(await tool("events", "browser_cdp_events"));
  assert.equal(events.events.length, 1);

  const beforeStrict = requests.length;
  await fs.writeFile(settingsFile, JSON.stringify({ strictApprovals: true }), { mode: 0o600 });
  const blocked = await tool("blocked", "browser_cdp_call", { method: "Runtime.evaluate", params: { expression: "document.cookie" } });
  assert.equal(blocked.result.isError, true);
  assert.match(blocked.result.content[0].text, /Strict approvals/i);
  assert.equal(requests.length, beforeStrict, "Strict-mode raw CDP must be blocked before touching Browser Harness IPC");

  const audit = await fs.readFile(auditFile, "utf8");
  assert.doesNotMatch(audit, /ADVANCED_BROWSER_SECRET/);
  assert.match(audit, /REDACTED JSON/);

  console.log("advanced-browser: ok");
} finally {
  child.kill("SIGTERM");
  await new Promise((resolve) => { if (child.exitCode !== null) resolve(); else child.once("close", resolve); });
  rl.close();
  await new Promise((resolve) => server.close(resolve));
  await fs.rm(tempRoot, { recursive: true, force: true });
}
