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
const cursorPath = path.join(tempRoot, "fake-ui-cursor.mjs");
const fallbackMarker = path.join(tempRoot, "foreground-fallback.marker");
const settingsFile = path.join(dataDir, "settings.json");
const approvalFile = path.join(dataDir, "FOREGROUND_GUI_APPROVED");
const auditFile = path.join(logDir, "audit.jsonl");
await fs.mkdir(dataDir, { recursive: true });
await fs.mkdir(logDir, { recursive: true });

const rootRef = "ax:123:root:0123456789abcdef";
const dialogRef = "ax:123:0:1111111111111111";
const previewRef = "ax:456:0:2222222222222222";
const onePixelPng = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Wl2nCEAAAAASUVORK5CYII=";
await fs.writeFile(cursorPath, `#!/usr/bin/env node
for await (const _line of process.stdin) {}
`, { mode: 0o755 });
await fs.writeFile(helperPath, `#!/usr/bin/env node
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
const fallbackMarker = path.join(path.dirname(fileURLToPath(import.meta.url)), "foreground-fallback.marker");
let raw = "";
for await (const chunk of process.stdin) raw += chunk;
const input = raw.trim() ? JSON.parse(raw) : {};
const command = process.argv[2];
const app = { pid: 123, name: "TextEdit", bundleId: "com.apple.TextEdit", active: true, hidden: false, terminated: false, activationPolicy: 0 };
const preview = { pid: 456, name: "Preview", bundleId: "com.apple.Preview", active: false, hidden: false, terminated: false, activationPolicy: 0 };
const rootRef = ${JSON.stringify(rootRef)};
const dialogRef = ${JSON.stringify(dialogRef)};
const target = input.target === "window"
  ? { kind: "window", windowId: input.window_id, ownerPid: 123, ownerName: "TextEdit", frame: { x: 0, y: 0, width: 800, height: 600 } }
  : input.target === "region"
    ? { kind: "region", region: input.region, displayId: input.display_id || 1 }
    : { kind: "display", displayId: input.display_id || 1, bounds: { x: 0, y: 0, width: 1440, height: 900 } };
let result;
switch (command) {
  case "status": result = { helperVersion: "test", accessibilityTrusted: true, screenRecordingGranted: true, postEventsGranted: true, frontmostApplication: app, displays: [{ displayId: 1, name: "Test Display", main: true, bounds: { x: 0, y: 0, width: 1440, height: 900 } }], inheritedTestSecret: process.env.MDB_TEST_UI_SECRET || null }; break;
  case "apps": result = { applications: [app, preview] }; break;
  case "windows": result = { windows: [{ windowId: 9, ownerPid: 123, ownerName: "TextEdit", name: "doc", bounds: { x: 0, y: 0, width: 800, height: 600 }, displayId: 1 }] }; break;
  case "tree": result = { pid: input.pid || 123, elementCount: 1, truncated: false, root: { ref: rootRef, role: "AXApplication", title: "TextEdit", identifier: "fixture.root", actions: [] } }; break;
  case "ax_at": result = { pid: input.pid || 123, ref: rootRef, role: "AXButton", title: "Increment", identifier: "fixture.increment", actions: ["AXPress"], point: { x: input.x, y: input.y } }; break;
  case "ax_query": result = { pid: input.pid || 123, count: 1, optimizedSearchUsed: true, elements: [{ ref: rootRef, role: "AXButton", title: "Increment", identifier: "fixture.increment", actions: ["AXPress"] }] }; break;
  case "screenshot": result = { mimeType: "image/png", data: ${JSON.stringify(onePixelPng)}, width: 1, height: 1, target: { ...target, ...(input.virtual_cursor ? { virtualCursor: input.virtual_cursor } : {}) } }; break;
  case "ocr": result = { fullText: "Visible text", blocks: [{ text: "Visible text", confidence: 0.99, bounds: { x: 0, y: 0, width: 1, height: 1 } }], blockCount: 1, imageWidth: 1, imageHeight: 1, recognitionLevel: input.recognition_level || "accurate", target, ...(input.include_screenshot ? { mimeType: "image/png", data: ${JSON.stringify(onePixelPng)}, width: 1, height: 1 } : {}) }; break;
  case "wait_visual": result = { matched: true, timedOut: false, condition: input.condition || "changed", checks: 2, elapsedMs: 20, metrics: { meanDifference: 0.1, changedFraction: 0.2 }, target, ...(input.include_screenshot ? { mimeType: "image/png", data: ${JSON.stringify(onePixelPng)}, width: 1, height: 1 } : {}) }; break;
  case "wait_for": { const needsFallback = input.expected === "foreground-fallback"; const matched = !needsFallback || fs.existsSync(fallbackMarker); result = { matched, timedOut: !matched, pid: input.pid || 123, condition: input.condition || "exists", checks: 1, elapsedMs: 0, observerRegistrations: 3, observerNotifications: 0, ...(matched ? { element: { ref: input.ref || rootRef, role: "AXApplication", title: "TextEdit" } } : {}) }; break; }
  case "assert": result = { matched: true, pid: input.pid || 123, element: { ref: input.ref || rootRef, role: "AXApplication", title: "TextEdit" } }; break;
  case "app_launch": result = app; break;
  case "app_activate": result = app; break;
  case "action": result = { ref: input.ref, action: input.action, performed: true }; break;
  case "window_action": result = { performed: true, action: input.action, pid: input.pid || 123, window: { ref: rootRef, role: "AXWindow", frame: { x: input.x || 0, y: input.y || 0, width: input.width || 800, height: input.height || 600 } } }; break;
  case "drag_drop": result = { performed: true, from: { x: 1, y: 2 }, to: { x: 3, y: 4 }, durationMs: input.duration_ms || 450 }; break;
  case "dialogs": result = { pid: input.pid || 123, count: 1, dialogs: [{ ref: dialogRef, role: "AXSheet", buttons: [{ ref: rootRef, role: "AXButton", title: "Confirm" }] }] }; break;
  case "dialog_action": result = { performed: true, action: input.action || "default", pid: input.pid || 123 }; break;
  case "file_dialog": result = { performed: true, pid: input.pid || 123, mode: input.mode || "open", path: input.path, confirmed: input.confirm !== false }; break;
  case "mouse": { const mode = input.input_mode === "auto" ? (input.pid ? "background" : "foreground") : (input.input_mode || "foreground"); if (mode === "foreground" && input.activate_target) fs.writeFileSync(fallbackMarker, "1"); result = { action: input.action, inputMode: mode, targetPid: input.pid || null, performed: true, x: input.x, y: input.y, from: { x: input.x, y: input.y }, to: { x: input.to_x, y: input.to_y } }; break; }
  case "keyboard": { const mode = input.input_mode === "auto" ? (input.pid ? "background" : "foreground") : (input.input_mode || "foreground"); if (mode === "foreground" && input.activate_target) fs.writeFileSync(fallbackMarker, "1"); result = { performed: true, inputMode: mode, targetPid: input.pid || null, typedCharacters: typeof input.text === "string" ? input.text.length : undefined, key: input.key, keyCode: input.key_code ?? 0, phase: input.phase || "press", repeat: input.repeat || 1 }; break; }
  case "sequence": result = { performed: true, stepCount: input.steps.length, elapsedMs: 1, results: input.steps.map((step, index) => ({ index, op: step.op, result: step.op === "screenshot" ? { mimeType: "image/png", data: ${JSON.stringify(onePixelPng)}, width: 1, height: 1, target: { ...target, ...(step.args?.virtual_cursor ? { virtualCursor: step.args.virtual_cursor } : {}) } } : step.op === "ax_query" ? { pid: 123, count: 1, elements: [{ ref: rootRef, role: "AXButton", title: "Increment" }] } : { performed: true } })) }; break;
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
    MAC_DEV_BRIDGE_UI_CURSOR_HELPER: cursorPath,
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
    }, 15_000);
    pending.set(id, (message) => {
      clearTimeout(timer);
      resolve(message);
    });
    child.stdin.write(`${JSON.stringify({ jsonrpc: "2.0", id, method, params })}\n`);
  });
}

const meta = {
  "io.modelcontextprotocol/protocolVersion": "2026-07-28",
  "io.modelcontextprotocol/clientInfo": { name: "desktop-control-test", version: "2" },
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

async function approveApps(allowedApps) {
  await fs.writeFile(approvalFile, JSON.stringify({
    nonce: "abcdef0123456789abcdef0123456789",
    expiresAt: new Date(Date.now() + 60_000).toISOString(),
    allowedApps,
  }), { mode: 0o600 });
}

async function approveTextEdit() {
  await approveApps(["TextEdit"]);
}

try {
  const tools = await request("tools", "tools/list", { _meta: meta });
  const names = new Set(tools.result.tools.map((item) => item.name));
  for (const name of [
    "ui_status", "ui_app_list", "ui_window_list", "ui_tree", "ui_ax_at", "ui_ax_query", "ui_cursor", "ui_screenshot", "ui_observe",
    "ui_app_launch", "ui_app_activate", "ui_action", "ui_mouse", "ui_keyboard",
    "ui_wait_for", "ui_assert", "ui_ocr", "ui_wait_visual", "ui_window_action", "ui_drag_drop",
    "ui_dialogs", "ui_dialog_action", "ui_file_dialog", "ui_clipboard_read", "ui_clipboard_write", "ui_sequence",
  ]) assert.ok(names.has(name), `missing ${name}`);

  const status = structured(await tool("status", "ui_status"));
  assert.equal(status.accessibilityTrusted, true);
  assert.equal(status.postEventsGranted, true);
  assert.equal(status.frontmostApplication.name, "TextEdit");
  assert.equal(status.inheritedTestSecret, null, "native helper must not inherit arbitrary bridge environment variables");

  const apps = structured(await tool("apps", "ui_app_list"));
  assert.equal(apps.applications[0].bundleId, "com.apple.TextEdit");
  const windows = structured(await tool("windows", "ui_window_list", { max_windows: 10 }));
  assert.equal(windows.windows[0].windowId, 9);

  const tree = structured(await tool("tree", "ui_tree", { max_depth: 4, max_elements: 20 }));
  assert.equal(tree.root.ref, rootRef);
  assert.match(tree.observationId, /^uiobs_[0-9a-f]{24}$/);
  assert.ok(tree.observationRefCount >= 1);

  const hit = structured(await tool("ax-at", "ui_ax_at", { pid: 123, x: 10, y: 20 }));
  assert.equal(hit.ref, rootRef);
  assert.match(hit.observationId, /^uiobs_/);
  const query = structured(await tool("ax-query", "ui_ax_query", { pid: 123, selector: { role: "AXButton", title: "Increment" } }));
  assert.equal(query.count, 1);
  assert.equal(query.elements[0].ref, rootRef);
  assert.equal(query.optimizedSearchUsed, true);
  assert.match(query.observationId, /^uiobs_/);

  const cursor = structured(await tool("cursor", "ui_cursor", { action: "move", x: 11, y: 22, duration_ms: 0 }));
  assert.equal(cursor.visible, true);
  assert.equal(cursor.physicalCursorMoved, false);

  const shot = await tool("shot", "ui_screenshot", { target: "window", window_id: 9, format: "png" });
  assert.equal(shot.result.isError, false, JSON.stringify(shot));
  assert.equal(shot.result.content[1].type, "image");
  assert.equal(shot.result.content[1].data, onePixelPng);
  assert.equal(shot.result.structuredContent.target.kind, "window");
  assert.equal(shot.result.structuredContent.target.virtualCursor.x, 11);

  const observe = await tool("observe", "ui_observe", { target: "region", region: { x: 2, y: 3, width: 20, height: 30 }, max_elements: 20 });
  assert.equal(observe.result.isError, false, JSON.stringify(observe));
  assert.equal(observe.result.content[1].type, "image");
  assert.equal(observe.result.structuredContent.tree.root.ref, rootRef);
  assert.match(observe.result.structuredContent.observationId, /^uiobs_/);

  const waited = structured(await tool("wait", "ui_wait_for", { observation_id: tree.observationId, ref: rootRef, condition: "exists", timeout_ms: 100 }));
  assert.equal(waited.matched, true);
  const asserted = structured(await tool("assert", "ui_assert", { selector: { title: "TextEdit" }, condition: "exists" }));
  assert.equal(asserted.matched, true);

  const badObservation = await tool("bad-observation", "ui_action", { observation_id: tree.observationId, ref: dialogRef, action: "press" });
  assert.equal(badObservation.result.isError, true);
  assert.match(badObservation.result.content[0].text, /not present in observation/);

  const semantic = structured(await tool("semantic", "ui_action", {
    observation_id: tree.observationId,
    ref: rootRef,
    action: "focus",
    precondition: { title: "TextEdit" },
    verify: { condition: "focused", expected: true, timeout_ms: 100 },
  }));
  assert.equal(semantic.performed, true);
  assert.equal(semantic.verification.matched, true);

  const ocr = await tool("ocr", "ui_ocr", { target: "region", region: { x: 0, y: 0, width: 10, height: 10 }, include_screenshot: true });
  assert.equal(ocr.result.isError, false, JSON.stringify(ocr));
  assert.equal(ocr.result.content[1].type, "image");
  assert.equal(ocr.result.structuredContent.fullText, "Visible text");

  const visual = structured(await tool("visual", "ui_wait_visual", { target: "display", condition: "changed", timeout_ms: 100 }));
  assert.equal(visual.matched, true);

  const dialogs = structured(await tool("dialogs", "ui_dialogs", { pid: 123 }));
  assert.equal(dialogs.count, 1);
  assert.equal(dialogs.dialogs[0].ref, dialogRef);

  await fs.rm(fallbackMarker, { force: true });
  const autoFallback = structured(await tool("auto-fallback", "ui_mouse", {
    pid: 123, input_mode: "auto", action: "click", x: 5, y: 6,
    verify: { pid: 123, selector: { identifier: "fixture.counter" }, condition: "value_equals", expected: "foreground-fallback", timeout_ms: 50 },
  }));
  assert.equal(autoFallback.foregroundFallbackUsed, true);
  assert.equal(autoFallback.inputMode, "foreground");
  await fs.rm(fallbackMarker, { force: true });
  const explicitBackground = await tool("background-no-fallback", "ui_mouse", {
    pid: 123, input_mode: "background", action: "click", x: 5, y: 6,
    verify: { pid: 123, selector: { identifier: "fixture.counter" }, condition: "value_equals", expected: "foreground-fallback", timeout_ms: 50 },
  });
  assert.equal(explicitBackground.result.isError, true);
  assert.match(explicitBackground.result.content[0].text, /postcondition/i);
  await assert.rejects(fs.stat(fallbackMarker), (error) => error?.code === "ENOENT");

  // Strict mode must cover all new mutation channels, including targets resolved by window id.
  await fs.writeFile(settingsFile, JSON.stringify({ strictApprovals: true }), { mode: 0o600 });
  const blocked = await tool("keyboard-blocked", "ui_keyboard", { text: "STRICT_SECRET" });
  assert.equal(blocked.result.isError, true);
  assert.match(blocked.result.content[0].text, /Strict approvals is enabled/);

  await approveTextEdit();
  const approved = structured(await tool("keyboard-approved", "ui_keyboard", { text: "STRICT_SECRET" }));
  assert.equal(approved.performed, true);
  await assert.rejects(fs.stat(approvalFile), (error) => error?.code === "ENOENT");

  await approveTextEdit();
  const windowAction = structured(await tool("window-action", "ui_window_action", { window_id: 9, action: "move", x: 10, y: 20 }));
  assert.equal(windowAction.performed, true);

  // File-dialog `path` is a selected file, not an app identity. With no pid the
  // resolver must approve the actual frontmost TextEdit application.
  await approveTextEdit();
  const fileAction = structured(await tool("file-dialog", "ui_file_dialog", { path: "/tmp/demo.txt", mode: "save" }));
  assert.equal(fileAction.performed, true);

  // A semantic cross-application drag must require both source and destination apps.
  await approveTextEdit();
  const crossAppBlocked = await tool("drag-cross-blocked", "ui_drag_drop", { source_ref: rootRef, destination_ref: previewRef });
  assert.equal(crossAppBlocked.result.isError, true);
  assert.match(crossAppBlocked.result.content[0].text, /does not allow: Preview/);
  await approveApps(["TextEdit", "Preview"]);
  const crossAppApproved = structured(await tool("drag-cross-approved", "ui_drag_drop", { source_ref: rootRef, destination_ref: previewRef }));
  assert.equal(crossAppApproved.performed, true);

  await approveTextEdit();
  const sequenceStrictBlocked = await tool("sequence-strict-blocked", "ui_sequence", { steps: [
    { op: "action", args: { ref: rootRef, action: "press" } },
    { op: "app_activate", args: { pid: 456 } },
  ] });
  assert.equal(sequenceStrictBlocked.result.isError, true);
  assert.match(sequenceStrictBlocked.result.content[0].text, /does not allow: Preview/);
  await approveApps(["TextEdit", "Preview"]);
  const sequenceStrictApproved = structured(await tool("sequence-strict-approved", "ui_sequence", { steps: [
    { op: "action", args: { ref: rootRef, action: "press" } },
    { op: "app_activate", args: { pid: 456 } },
  ] }));
  assert.equal(sequenceStrictApproved.performed, true);

  await fs.writeFile(settingsFile, JSON.stringify({ strictApprovals: false }), { mode: 0o600 });
  structured(await tool("drag", "ui_drag_drop", { from_x: 1, from_y: 2, to_x: 3, to_y: 4 }));
  structured(await tool("dialog-action", "ui_dialog_action", { pid: 123, action: "button", button_title: "Confirm" }));
  structured(await tool("clipboard-write", "ui_clipboard_write", { text: "CLIPBOARD_SECRET" }));
  structured(await tool("set-value", "ui_action", { ref: rootRef, action: "set_value", value: "FIELD_SECRET" }));
  const sequence = await tool("sequence", "ui_sequence", { steps: [
    { op: "keyboard", args: { text: "SEQUENCE_SECRET" } },
    { op: "ax_query", args: { pid: 123, selector: { title: "Increment" } } },
    { op: "screenshot", args: { target: "window", window_id: 9 } },
  ] });
  assert.equal(sequence.result.isError, false, JSON.stringify(sequence));
  assert.equal(sequence.result.content[1].type, "image");
  assert.equal(sequence.result.structuredContent.stepCount, 3);
  assert.equal(sequence.result.structuredContent.results[2].result.target.virtualCursor.x, 11);
  assert.match(sequence.result.structuredContent.observationId, /^uiobs_/);

  const audit = await fs.readFile(auditFile, "utf8");
  assert.doesNotMatch(audit, /STRICT_SECRET/);
  assert.doesNotMatch(audit, /CLIPBOARD_SECRET/);
  assert.doesNotMatch(audit, /FIELD_SECRET/);
  assert.doesNotMatch(audit, /SEQUENCE_SECRET/);
  assert.match(audit, /REDACTED/);

  console.log("desktop-control: ok");
} finally {
  child.kill("SIGTERM");
  await new Promise((resolve) => { if (child.exitCode !== null) resolve(); else child.once("close", resolve); });
  rl.close();
  await fs.rm(tempRoot, { recursive: true, force: true });
}
