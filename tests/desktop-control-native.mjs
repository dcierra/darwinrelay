import { spawn, spawnSync } from "node:child_process";
import assert from "node:assert/strict";
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import readline from "node:readline";
import { fileURLToPath } from "node:url";

if (process.platform !== "darwin") {
  console.log("desktop-control-native: skipped (not macOS)");
  process.exit(0);
}

const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.resolve(here, "..");
const bridgePath = path.join(root, "bridge.mjs");
const tempRoot = await fs.mkdtemp(path.join(os.tmpdir(), "mdb-desktop-native-"));
const helperPath = path.join(tempRoot, "MacUIHelper");
const cursorPath = path.join(tempRoot, "MacUICursorOverlay");
const fixtureApp = path.join(tempRoot, "MDBDesktopFixture.app");
const fixtureExe = path.join(fixtureApp, "Contents", "MacOS", "MDBDesktopFixture");
const dataDir = path.join(tempRoot, "data");
const logDir = path.join(tempRoot, "logs");
await fs.mkdir(dataDir, { recursive: true });
await fs.mkdir(logDir, { recursive: true });

function run(command, args, env = {}) {
  const result = spawnSync(command, args, { cwd: root, env: { ...process.env, ...env }, encoding: "utf8", timeout: 120_000 });
  assert.equal(result.status, 0, `${command} ${args.join(" ")} failed:\n${result.stdout}\n${result.stderr}`);
  return result.stdout.trim();
}

run("bash", ["scripts/build-mac-ui-helper.sh"], { MAC_DEV_BRIDGE_UI_HELPER_OUTPUT: helperPath });
run("bash", ["scripts/build-mac-ui-cursor.sh"], { MAC_DEV_BRIDGE_UI_CURSOR_OUTPUT: cursorPath });
run("bash", ["scripts/build-desktop-fixture.sh"], { MDB_DESKTOP_FIXTURE_APP: fixtureApp });

// GitHub-hosted macOS is not an interactive desktop contract. Depending on the
// runner image it may report usable TCC permissions while AXPress/CGEvent delivery
// still fails nondeterministically. CI already exercises every MCP desktop tool
// deterministically in desktop-control.mjs; here it must still compile the real
// Swift helper and AppKit fixture. Self-hosted interactive CI can opt into the
// mutable native E2E explicitly.
if (process.env.CI && process.env.MDB_RUN_NATIVE_DESKTOP_E2E !== "1") {
  console.log("desktop-control-native: runtime skipped on hosted CI; helper/fixture build passed (set MDB_RUN_NATIVE_DESKTOP_E2E=1 on interactive self-hosted CI)");
  await fs.rm(tempRoot, { recursive: true, force: true });
  process.exit(0);
}

function helper(command, payload = {}) {
  const result = spawnSync(helperPath, [command], { input: `${JSON.stringify(payload)}\n`, encoding: "utf8", timeout: 60_000 });
  const parsed = JSON.parse(result.stdout || "{}");
  if (!parsed.ok) throw Object.assign(new Error(parsed.error?.message || `helper ${command} failed`), { code: parsed.error?.code });
  return parsed.result;
}

const permissionStatus = helper("status");
if (!permissionStatus.accessibilityTrusted || !permissionStatus.screenRecordingGranted) {
  console.log(`desktop-control-native: runtime skipped (Accessibility=${permissionStatus.accessibilityTrusted}, ScreenRecording=${permissionStatus.screenRecordingGranted}); build passed`);
  await fs.rm(tempRoot, { recursive: true, force: true });
  process.exit(0);
}

// The fixture bundle id is unique to this test. Reclaim a stale fixture from a
// previously interrupted local run so AX selection cannot bind to the wrong instance.
spawnSync("pkill", ["-9", "-f", "MDBDesktopFixture.app/Contents/MacOS/MDBDesktopFixture"], { stdio: "ignore" });
const fixture = spawn(fixtureExe, [], { detached: true, stdio: "ignore" });
fixture.unref();
let fixturePid = fixture.pid;
for (let i = 0; i < 60; i += 1) {
  const apps = helper("apps", { include_background: true }).applications;
  const app = apps.find((candidate) => candidate.pid === fixturePid);
  if (app) { break; }
  await new Promise((resolve) => setTimeout(resolve, 100));
}
assert.ok(Number.isInteger(fixturePid) && fixturePid > 1, "fixture did not start");
// NSRunningApplication can appear before AppKit has published the window/control AX
// subtree. Wait for the fixture's stable identifier instead of racing first paint.
let fixtureAxReady = false;
for (let i = 0; i < 80; i += 1) {
  try {
    const tree = helper("tree", { pid: fixturePid, max_depth: 8, max_elements: 700, include_values: true });
    const stack = [tree.root];
    while (stack.length) {
      const node = stack.pop();
      if (node?.identifier === "fixture.input") { fixtureAxReady = true; break; }
      stack.push(...(node?.children || []));
    }
    if (fixtureAxReady) break;
  } catch {}
  await new Promise((resolve) => setTimeout(resolve, 75));
}
assert.equal(fixtureAxReady, true, "fixture Accessibility tree did not become ready");

const bridge = spawn(process.execPath, [bridgePath], {
  stdio: ["pipe", "pipe", "pipe"],
  env: {
    ...process.env,
    MAC_DEV_BRIDGE_DATA_DIR: dataDir,
    MAC_DEV_BRIDGE_LOG_DIR: logDir,
    MAC_DEV_BRIDGE_AUDIT_MODE: "metadata",
    MAC_DEV_BRIDGE_UI_HELPER: helperPath,
    MAC_DEV_BRIDGE_UI_CURSOR_HELPER: cursorPath,
    MAC_DEV_BRIDGE_FULL_ACCESS_ACK: "I_UNDERSTAND_THIS_GRANTS_FULL_ACCESS",
  },
});
const rl = readline.createInterface({ input: bridge.stdout });
const pending = new Map();
let bridgeStderr = "";
bridge.stderr.on("data", (chunk) => { bridgeStderr += chunk.toString("utf8"); });
rl.on("line", (line) => {
  const message = JSON.parse(line);
  const entry = pending.get(message.id);
  if (entry) { clearTimeout(entry.timer); pending.delete(message.id); entry.resolve(message); }
});
let nextId = 1;
const meta = {
  "io.modelcontextprotocol/protocolVersion": "2026-07-28",
  "io.modelcontextprotocol/clientInfo": { name: "desktop-native", version: "1" },
  "io.modelcontextprotocol/clientCapabilities": {},
};
function request(name, args = {}, timeoutMs = 30_000) {
  const id = nextId++;
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => { pending.delete(id); reject(new Error(`timeout ${name}; stderr=${bridgeStderr}`)); }, timeoutMs);
    pending.set(id, { resolve, reject, timer });
    bridge.stdin.write(`${JSON.stringify({ jsonrpc: "2.0", id, method: "tools/call", params: { _meta: meta, name, arguments: args } })}\n`);
  });
}
function structured(response) {
  assert.equal(response.result?.isError, false, JSON.stringify(response));
  return response.result.structuredContent;
}
function walk(node) {
  return [node, ...(node.children || []).flatMap(walk)];
}
function byIdentifier(tree, identifier) {
  const node = walk(tree.root).find((candidate) => candidate.identifier === identifier);
  assert.ok(node, `missing AX element ${identifier}`);
  return node;
}

try {
  const windows = structured(await request("ui_window_list", { max_windows: 500, on_screen_only: true }));
  const fixtureWindow = windows.windows.find((window) => window.ownerPid === fixturePid && window.layer === 0 && window.bounds?.width > 500);
  assert.ok(fixtureWindow, "fixture window not found through CoreGraphics");

  let observed = structured(await request("ui_observe", { pid: fixturePid, target: "window", window_id: fixtureWindow.windowId, max_depth: 8, max_elements: 600 }));
  assert.match(observed.observationId, /^uiobs_/);
  assert.equal(observed.screenshot.target.kind, "window");
  let tree = observed.tree;
  let input = byIdentifier(tree, "fixture.input");
  let increment = byIdentifier(tree, "fixture.increment");

  const queriedIncrement = structured(await request("ui_ax_query", { pid: fixturePid, selector: { identifier: "fixture.increment", role: "AXButton" }, limit: 5 }));
  assert.equal(queriedIncrement.count, 1);
  assert.equal(queriedIncrement.elements[0].identifier, "fixture.increment");
  assert.match(queriedIncrement.observationId, /^uiobs_/);
  const incrementCenter = { x: increment.frame.x + increment.frame.width / 2, y: increment.frame.y + increment.frame.height / 2 };
  const hit = structured(await request("ui_ax_at", { pid: fixturePid, x: incrementCenter.x, y: incrementCenter.y }));
  assert.ok(hit.ref?.startsWith(`ax:${fixturePid}:`), "AX hit-test should return an addressable ref");
  assert.ok(hit.frame, "AX hit-test should return semantic geometry");

  const virtualCursor = structured(await request("ui_cursor", { action: "move", x: incrementCenter.x, y: incrementCenter.y, duration_ms: 0 }));
  assert.equal(virtualCursor.visible, true);
  assert.equal(virtualCursor.physicalCursorMoved, false);
  const cursorShot = structured(await request("ui_screenshot", { target: "window", window_id: fixtureWindow.windowId, format: "png" }));
  assert.equal(cursorShot.target.virtualCursor.x, incrementCenter.x);
  assert.equal(cursorShot.target.virtualCursor.y, incrementCenter.y);

  const setValue = structured(await request("ui_action", {
    observation_id: observed.observationId,
    ref: input.ref,
    action: "set_value",
    value: "native-control-ok",
    precondition: { identifier: "fixture.input", value: "initial" },
    verify: { selector: { identifier: "fixture.input" }, condition: "value_equals", expected: "native-control-ok", timeout_ms: 1500 },
  }));
  assert.equal(setValue.verification.matched, true);

  // Exercise actual CoreGraphics keyboard delivery, not only protocol wiring.
  const keyboardTree = structured(await request("ui_tree", { pid: fixturePid, max_depth: 8, max_elements: 700 }));
  const keyboardInput = byIdentifier(keyboardTree, "fixture.input");
  structured(await request("ui_action", { observation_id: keyboardTree.observationId, ref: keyboardInput.ref, action: "set_value", value: "" }));
  structured(await request("ui_action", { ref: keyboardInput.ref, action: "focus" }));
  const keyboardTyped = structured(await request("ui_keyboard", {
    pid: fixturePid, input_mode: "foreground", activate_target: true, text: "typed-by-keyboard",
    verify: { pid: fixturePid, selector: { identifier: "fixture.input" }, condition: "value_equals", expected: "typed-by-keyboard", timeout_ms: 1500 },
  }));
  assert.equal(keyboardTyped.verification.matched, true);
  assert.equal(keyboardTyped.typedCharacters, "typed-by-keyboard".length);

  const incremented = structured(await request("ui_action", {
    observation_id: observed.observationId,
    ref: increment.ref,
    action: "press",
    precondition: { identifier: "fixture.increment", title: "Increment" },
    verify: { selector: { identifier: "fixture.counter" }, condition: "value_equals", expected: "Counter: 1", timeout_ms: 1500 },
  }));
  assert.equal(incremented.verification.matched, true);
  assert.equal(structured(await request("ui_assert", { pid: fixturePid, selector: { identifier: "fixture.counter" }, condition: "value_equals", expected: "Counter: 1" })).matched, true);

  const sequenceQuery = structured(await request("ui_ax_query", { pid: fixturePid, selector: { identifier: "fixture.increment" }, limit: 1 }));
  const sequence = structured(await request("ui_sequence", { steps: [
    { op: "action", args: { observation_id: sequenceQuery.observationId, ref: sequenceQuery.elements[0].ref, action: "press" } },
    { op: "wait_for", args: { pid: fixturePid, selector: { identifier: "fixture.counter" }, condition: "value_equals", expected: "Counter: 2", timeout_ms: 1500 } },
  ] }));
  assert.equal(sequence.stepCount, 2);
  assert.equal(sequence.results[1].result.matched, true);

  const backgroundMove = structured(await request("ui_mouse", { pid: fixturePid, input_mode: "background", preserve_focus: true, action: "move", x: incrementCenter.x, y: incrementCenter.y }));
  assert.equal(backgroundMove.inputMode, "background");
  assert.equal(backgroundMove.targetPid, fixturePid);

  const ocr = structured(await request("ui_ocr", { target: "window", window_id: fixtureWindow.windowId, recognition_level: "accurate" }, 60_000));
  assert.ok(ocr.blockCount > 0);
  assert.match(ocr.fullText, /Increment|Desktop Control Fixture|Open Dialog/i);

  const moved = structured(await request("ui_window_action", { window_id: fixtureWindow.windowId, action: "set_bounds", x: fixtureWindow.bounds.x + 12, y: fixtureWindow.bounds.y + 12, width: 700, height: 500 }));
  assert.equal(moved.performed, true);
  assert.ok(Math.abs(moved.window.frame.width - 700) < 8);

  observed = structured(await request("ui_observe", { pid: fixturePid, target: "window", window_id: fixtureWindow.windowId, max_depth: 8, max_elements: 700 }));
  tree = observed.tree;
  const dialogButton = byIdentifier(tree, "fixture.open_dialog");
  structured(await request("ui_action", { observation_id: observed.observationId, ref: dialogButton.ref, action: "press" }));
  assert.equal(structured(await request("ui_wait_for", { pid: fixturePid, selector: { role: "AXSheet" }, condition: "exists", timeout_ms: 2000 })).matched, true);
  const dialogs = structured(await request("ui_dialogs", { pid: fixturePid }));
  assert.equal(dialogs.count, 1);
  structured(await request("ui_dialog_action", { pid: fixturePid, action: "button", button_title: "Confirm" }));
  assert.equal(structured(await request("ui_wait_for", { pid: fixturePid, selector: { identifier: "fixture.status" }, condition: "value_equals", expected: "Dialog confirmed", timeout_ms: 2000 })).matched, true);

  observed = structured(await request("ui_observe", { pid: fixturePid, target: "window", window_id: fixtureWindow.windowId, max_depth: 8, max_elements: 700 }));
  tree = observed.tree;
  const flash = byIdentifier(tree, "fixture.flash");
  const visualPromise = request("ui_wait_visual", { target: "window", window_id: fixtureWindow.windowId, condition: "changed", timeout_ms: 3000, interval_ms: 100, threshold: 0.005, changed_fraction: 0.005 }, 10_000);
  await new Promise((resolve) => setTimeout(resolve, 250));
  structured(await request("ui_action", { observation_id: observed.observationId, ref: flash.ref, action: "press" }));
  const visual = structured(await visualPromise);
  assert.equal(visual.matched, true);

  const fileTree = structured(await request("ui_tree", { pid: fixturePid, max_depth: 8, max_elements: 700 }));
  const fileButton = byIdentifier(fileTree, "fixture.open_file");
  structured(await request("ui_action", { observation_id: fileTree.observationId, ref: fileButton.ref, action: "press" }));
  assert.equal(structured(await request("ui_wait_for", { pid: fixturePid, selector: { role: "AXSheet" }, condition: "exists", timeout_ms: 2000 })).matched, true);
  // Verify the picker helper against a real NSOpenPanel without selecting user data.
  const samplePath = path.join(tempRoot, "picker-sample.txt");
  await fs.writeFile(samplePath, "fixture\n");
  structured(await request("ui_file_dialog", { pid: fixturePid, path: samplePath, mode: "open", confirm: true }));
  assert.equal(structured(await request("ui_wait_for", { pid: fixturePid, selector: { identifier: "fixture.status" }, condition: "value_contains", expected: "picker-sample.txt", timeout_ms: 3000 })).matched, true);

  const saveTree = structured(await request("ui_tree", { pid: fixturePid, max_depth: 8, max_elements: 800 }));
  const saveButton = byIdentifier(saveTree, "fixture.save_file");
  structured(await request("ui_action", { observation_id: saveTree.observationId, ref: saveButton.ref, action: "press" }));
  assert.equal(structured(await request("ui_wait_for", { pid: fixturePid, selector: { role: "AXSheet" }, condition: "exists", timeout_ms: 2000 })).matched, true);
  const savePath = path.join(tempRoot, "saved-by-fixture.txt");
  structured(await request("ui_file_dialog", { pid: fixturePid, path: savePath, mode: "save", confirm: true }));
  assert.equal(structured(await request("ui_wait_for", { pid: fixturePid, selector: { identifier: "fixture.status" }, condition: "value_contains", expected: "saved-by-fixture.txt", timeout_ms: 3000 })).matched, true);

  // Keep synthetic pointer input last so a failed OS-level delivery cannot mask
  // the preceding semantic/dialog coverage. Interactive native E2E requires the
  // slider's visible state to change.
  const dragTree = structured(await request("ui_tree", { pid: fixturePid, max_depth: 8, max_elements: 700 }));
  const slider = byIdentifier(dragTree, "fixture.slider");
  const sliderFrame = slider.frame;
  const dragResult = structured(await request("ui_drag_drop", {
    from_x: sliderFrame.x + sliderFrame.width * 0.25,
    from_y: sliderFrame.y + sliderFrame.height / 2,
    to_x: sliderFrame.x + sliderFrame.width - 15,
    to_y: sliderFrame.y + sliderFrame.height / 2,
    duration_ms: 350,
  }));
  assert.equal(dragResult.performed, true);
  assert.ok(dragResult.to.x > dragResult.from.x, "drag should route from left to right");
  const afterDrag = structured(await request("ui_tree", { pid: fixturePid, max_depth: 8, max_elements: 700 }));
  const sliderAfter = byIdentifier(afterDrag, "fixture.slider");
  assert.notEqual(sliderAfter.value, "25", "drag should change the fixture slider value on an interactive desktop");

  console.log("desktop-control-native: ok");
} finally {
  bridge.kill("SIGTERM");
  await new Promise((resolve) => { if (bridge.exitCode !== null) resolve(); else bridge.once("close", resolve); });
  rl.close();
  try { process.kill(-fixturePid, "SIGKILL"); } catch {}
  try { process.kill(fixturePid, "SIGKILL"); } catch {}
  await new Promise((resolve) => setTimeout(resolve, 100));
  await fs.rm(tempRoot, { recursive: true, force: true });
}
