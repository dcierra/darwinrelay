import { spawn } from "node:child_process";
import assert from "node:assert/strict";
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import readline from "node:readline";
import { fileURLToPath } from "node:url";

if (process.platform !== "darwin") {
  console.log("desktop-control: skipped (not macOS)");
  process.exit(0);
}

const here = path.dirname(fileURLToPath(import.meta.url));
const bridgePath = path.resolve(here, "..", "bridge.mjs");
const tempRoot = await fs.mkdtemp(path.join(os.tmpdir(), "mdb-desktop-control-test-"));
const dataDir = path.join(tempRoot, "data");
const logDir = path.join(tempRoot, "logs");
const helperPath = path.join(tempRoot, "fake-ui-helper.mjs");
const settingsFile = path.join(dataDir, "settings.json");
const approvalFile = path.join(dataDir, "FOREGROUND_GUI_APPROVED");
const auditFile = path.join(logDir, "audit.jsonl");
await fs.mkdir(dataDir, { recursive: true });
await fs.mkdir(logDir, { recursive: true });

const onePixelPng = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Wl2nCEAAAAASUVORK5CYII=";
await fs.writeFile(helperPath, `#!/usr/bin/env node
let raw = "";
for await (const chunk of process.stdin) raw += chunk;
const input = raw.trim() ? JSON.parse(raw) : {};
const command = process.argv[2];
const app = { pid: 123, name: "TextEdit", bundleId: "com.apple.TextEdit", active: true, hidden: false, terminated: false, activationPolicy: 0 };
let result;
switch (command) {
  case "status": result = { helperVersion: "test", accessibilityTrusted: true, screenRecordingGranted: true, frontmostApplication: app, displays: [{ displayId: 1, name: "Test Display", main: true }], inheritedTestSecret: process.env.MDB_TEST_UI_SECRET || null }; break;
  case "apps": result = { applications: [app] }; break;
  case "windows": result = { windows: [{ windowId: 9, ownerPid: 123, ownerName: "TextEdit", name: "doc", bounds: { x: 0, y: 0, width: 800, height: 600 } }] }; break;
  case "tree": result = { pid: input.pid || 123, elementCount: 1, truncated: false, root: { ref: "ax:123:root", role: "AXApplication", title: "TextEdit", actions: [] } }; break;
  case "screenshot": result = { mimeType: "image/png", data: ${JSON.stringify(onePixelPng)}, width: 1, height: 1, displayId: 1 }; break;
  case "app_launch": result = app; break;
  case "app_activate": result = app; break;
  case "action": result = { ref: input.ref, action: input.action, performed: true }; break;
  case "mouse": result = { action: input.action, performed: true }; break;
  case "keyboard": result = { performed: true, typedCharacters: typeof input.text === "string" ? input.text.length : undefined, key: input.key }; break;
  case "clipboard_read": result = { changeCount: 1, string: "clipboard", types: ["public.utf8-plain-text"] }; break;
  case "clipboard_write": result = { changeCount: 2, writtenCharacters: (input.text || "").length }; break;
  default:
    process.stdout.write(JSON.stringify({ ok: false, error: { code: "TEST_UNKNOWN", message: command } }) + "\\n");
    process.exit(2);
}
process.stdout.write(JSON.stringify({ ok: true, result }) + "\\n");
`, { mode: 0o755 });

const child = spawn(process.execPath, [bridgePath], {
  stdio: ["pipe", "pipe", "pipe"],
  env: {
    ...process.env,
    MAC_DEV_BRIDGE_DATA_DIR: dataDir,
    MAC_DEV_BRIDGE_LOG_DIR: logDir,
    MAC_DEV_BRIDGE_AUDIT_LOG: auditFile,
    MAC_DEV_BRIDGE_AUDIT_MODE: "full",
    MAC_DEV_BRIDGE_UI_HELPER: helperPath,
    MAC_DEV_BRIDGE_FOREGROUND_GUI_APPROVAL_FILE: approvalFile,
    MAC_DEV_BRIDGE_FULL_ACCESS_ACK: "I_UNDERSTAND_THIS_GRANTS_FULL_ACCESS",
    MDB_TEST_UI_SECRET: "MUST_NOT_REACH_NATIVE_HELPER",
  },
});

const rl = readline.createInterface({ input: child.stdout });
const pending = new Map();
let stderr = "";
child.stderr.on("data", (chunk) => { stderr += chunk.toString("utf8"); });
rl.on("line", (line) => {
  const message = JSON.parse(line);
  if (pending.has(message.id)) {
    pending.get(message.id)(message);
    pending.delete(message.id);
  }
});

function request(id, method, params = {}) {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => {
      pending.delete(id);
      reject(new Error(`timeout waiting for ${id}; stderr=${stderr}`));
    }, 10_000);
    pending.set(id, (message) => {
      clearTimeout(timer);
      resolve(message);
    });
    child.stdin.write(`${JSON.stringify({ jsonrpc: "2.0", id, method, params })}\n`);
  });
}

const meta = {
  "io.modelcontextprotocol/protocolVersion": "2026-07-28",
  "io.modelcontextprotocol/clientInfo": { name: "desktop-control-test", version: "1" },
  "io.modelcontextprotocol/clientCapabilities": {},
};

async function tool(id, name, args = {}) {
  return await request(id, "tools/call", { _meta: meta, name, arguments: args });
}

function structured(response) {
  assert.equal(response.result?.resultType, "complete", JSON.stringify(response));
  assert.equal(response.result?.isError, false, JSON.stringify(response));
  return response.result.structuredContent;
}

try {
  const tools = await request("tools", "tools/list", { _meta: meta });
  const names = new Set(tools.result.tools.map((item) => item.name));
  for (const name of [
    "ui_status", "ui_app_list", "ui_window_list", "ui_tree", "ui_screenshot", "ui_observe",
    "ui_app_launch", "ui_app_activate", "ui_action", "ui_mouse", "ui_keyboard",
    "ui_clipboard_read", "ui_clipboard_write",
  ]) assert.ok(names.has(name), `missing ${name}`);

  const status = structured(await tool("status", "ui_status"));
  assert.equal(status.accessibilityTrusted, true);
  assert.equal(status.frontmostApplication.name, "TextEdit");
  assert.equal(status.inheritedTestSecret, null, "native helper must not inherit arbitrary bridge environment variables");

  const apps = structured(await tool("apps", "ui_app_list"));
  assert.equal(apps.applications[0].bundleId, "com.apple.TextEdit");

  const windows = structured(await tool("windows", "ui_window_list", { max_windows: 10 }));
  assert.equal(windows.windows[0].windowId, 9);

  const tree = structured(await tool("tree", "ui_tree", { max_depth: 4, max_elements: 20 }));
  assert.equal(tree.root.ref, "ax:123:root");

  const shot = await tool("shot", "ui_screenshot", { format: "png" });
  assert.equal(shot.result.isError, false, JSON.stringify(shot));
  assert.equal(shot.result.content.length, 2);
  assert.equal(shot.result.content[1].type, "image");
  assert.equal(shot.result.content[1].mimeType, "image/png");
  assert.equal(shot.result.content[1].data, onePixelPng);
  assert.equal(shot.result.structuredContent.width, 1);

  const observe = await tool("observe", "ui_observe", { max_elements: 20 });
  assert.equal(observe.result.isError, false, JSON.stringify(observe));
  assert.equal(observe.result.content[1].type, "image");
  assert.equal(observe.result.structuredContent.tree.root.ref, "ax:123:root");

  // Strict mode must cover the new native input channel too.
  await fs.writeFile(settingsFile, JSON.stringify({ strictApprovals: true }), { mode: 0o600 });
  const blocked = await tool("keyboard-blocked", "ui_keyboard", { text: "STRICT_SECRET" });
  assert.equal(blocked.result.isError, true);
  assert.match(blocked.result.content[0].text, /Strict approvals is enabled/);

  await fs.writeFile(approvalFile, JSON.stringify({
    nonce: "abcdef0123456789abcdef0123456789",
    expiresAt: new Date(Date.now() + 60_000).toISOString(),
    allowedApps: ["TextEdit"],
  }), { mode: 0o600 });
  const approved = structured(await tool("keyboard-approved", "ui_keyboard", { text: "STRICT_SECRET" }));
  assert.equal(approved.performed, true);
  await assert.rejects(fs.stat(approvalFile), (error) => error?.code === "ENOENT");

  await fs.writeFile(settingsFile, JSON.stringify({ strictApprovals: false }), { mode: 0o600 });
  structured(await tool("clipboard-write", "ui_clipboard_write", { text: "CLIPBOARD_SECRET" }));
  structured(await tool("set-value", "ui_action", { ref: "ax:123:root", action: "set_value", value: "FIELD_SECRET" }));

  const audit = await fs.readFile(auditFile, "utf8");
  assert.doesNotMatch(audit, /STRICT_SECRET/);
  assert.doesNotMatch(audit, /CLIPBOARD_SECRET/);
  assert.doesNotMatch(audit, /FIELD_SECRET/);
  assert.match(audit, /REDACTED/);

  console.log("desktop-control: ok");
} finally {
  child.kill("SIGKILL");
  rl.close();
  await fs.rm(tempRoot, { recursive: true, force: true });
}
