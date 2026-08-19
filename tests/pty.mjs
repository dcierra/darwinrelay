// Interactive pty session tests. Negative cases first.
//
// Everything here drives the real bridge over stdio and a real pty allocated by
// lib/ptyhelper.pl. Nothing is stubbed: a pty that is not a pty is exactly the
// failure that ruled out script(1), so a suite that mocked the terminal would
// certify the thing it is supposed to catch.
//
// Two invariants are checked after EVERY case, not just the ones about killing:
//   - the bridge process is gone;
//   - every helper and every session leader this file caused to exist is gone,
//     verified through the process table (ps) and matched against the command
//     line recorded at spawn time, so a recycled pid cannot read as an orphan and
//     an orphan cannot read as a recycled pid.
// A green run that leaves an unrestricted interactive shell on the machine is an
// invisible failure, and this endpoint is publicly reachable.
//
// Cases collect their own failures instead of aborting the file, because the
// value of the suite is the full picture of what works; the exit code is still
// non-zero if anything failed.

import { spawn } from "node:child_process";
import assert from "node:assert/strict";
import fsp from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import readline from "node:readline";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const bridgePath = path.resolve(here, "..", "bridge.mjs");
// macOS: /var is a symlink to /private/var, and a path the bridge echoes back is
// already resolved. Comparing an unresolved temp path against it compares two
// different strings for the same directory — a real bug came from exactly that.
const temporaryRoot = await fsp.realpath(await fsp.mkdtemp(path.join(os.tmpdir(), "darwinrelay-pty-")));
const FULL_ACCESS_ACK = "I_UNDERSTAND_THIS_GRANTS_FULL_ACCESS";
const CASE_TIMEOUT_MS = 120_000;
const CTRL_C = String.fromCharCode(3);
const ESC = String.fromCharCode(27);

const results = [];
let failures = 0;
let cases = 0;
// Only ever pids this file caused to be spawned, and only ever reclaimed after
// their recorded command line still matches.
const trackedProcesses = [];

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

// audit_tail returns a byte tail, so its first line can be a fragment. Parsing
// defensively keeps an assertion about the log's CONTENT from failing as a parse
// error about its framing.
function auditEntries(text) {
  return text
    .split("\n")
    .filter((line) => line.startsWith("{"))
    .map((line) => { try { return JSON.parse(line); } catch { return null; } })
    .filter(Boolean);
}

function withTimeout(promise, ms, label) {
  let timer;
  return Promise.race([
    promise,
    new Promise((_, reject) => {
      timer = setTimeout(() => reject(new Error(`${label} exceeded ${ms}ms`)), ms);
      timer.unref();
    }),
  ]).finally(() => clearTimeout(timer));
}

async function poll(predicate, { attempts = 60, delayMs = 100, label = "condition" } = {}) {
  for (let attempt = 0; attempt < attempts; attempt += 1) {
    const value = await predicate();
    if (value) return value;
    await sleep(delayMs);
  }
  throw new Error(`timed out waiting for ${label}`);
}

// The process table, not a return value. Every false containment verdict this
// project has shipped came from trusting the reporter instead of the OS.
function ps(pid, format) {
  return new Promise((resolve) => {
    const proc = spawn("ps", ["-o", format, "-p", String(pid)], { stdio: ["ignore", "pipe", "ignore"] });
    let out = "";
    proc.stdout.on("data", (chunk) => { out += chunk.toString(); });
    proc.once("error", () => resolve(""));
    proc.once("close", () => resolve(out.trim()));
  });
}

const psCommand = (pid) => ps(pid, "command=");

// A SIGKILLed leader lingers as a zombie until it is reaped, and a pid can be
// reused by an unrelated process. Both would be misread by a bare kill(pid, 0),
// so liveness means: present, not a zombie, and still the command we recorded.
async function stillRunning(pid, recordedCommand) {
  if (!Number.isInteger(pid) || pid <= 1) return false;
  const line = await ps(pid, "stat=,command=");
  if (!line) return false;
  const [stat] = line.split(/\s+/, 1);
  if (stat.startsWith("Z")) return false;
  const command = line.slice(stat.length).trim();
  if (!recordedCommand) return true;
  return command === recordedCommand;
}

function processGroupGone(pgid) {
  try {
    process.kill(-pgid, 0);
    return false;
  } catch (error) {
    return error?.code === "ESRCH";
  }
}

// ---------------------------------------------------------------------------
// Harness

let bridgeCounter = 0;

async function startBridge(context, { env = {} } = {}) {
  bridgeCounter += 1;
  const dataDir = path.join(temporaryRoot, `bridge-${bridgeCounter}`);
  const logDir = path.join(dataDir, "logs");
  const workDir = path.join(dataDir, "work");
  await fsp.mkdir(workDir, { recursive: true });
  const unlockFile = path.join(dataDir, "FULL_ACCESS_ENABLED");
  // A file latch, never DARWINRELAY_FULL_ACCESS_ACK: the env acknowledgement is
  // deliberately not a kill-switch surface, so a suite that used it could not test
  // revocation at all.
  await fsp.writeFile(unlockFile, `${FULL_ACCESS_ACK}\n`);

  const child = spawn(process.execPath, [bridgePath], {
    // A minimal environment on purpose: DARWINRELAY_FULL_ACCESS_ACK must not
    // leak in from the developer's shell, or the revocation cases would be
    // testing a latch that is deliberately bypassed.
    env: {
      PATH: process.env.PATH,
      HOME: process.env.HOME,
      DARWINRELAY_DATA_DIR: dataDir,
      DARWINRELAY_LOG_DIR: logDir,
      DARWINRELAY_UNLOCK_FILE: unlockFile,
      DARWINRELAY_AUDIT_MODE: "metadata",
      ...env,
    },
    stdio: ["pipe", "pipe", "pipe"],
  });
  let stderr = "";
  child.stderr.on("data", (chunk) => { stderr += chunk.toString(); });

  const pending = new Map();
  let nextId = 1;
  readline.createInterface({ input: child.stdout, crlfDelay: Infinity }).on("line", (line) => {
    let message;
    try { message = JSON.parse(line); } catch { return; }
    const entry = pending.get(message.id);
    if (!entry) return;
    clearTimeout(entry.timer);
    pending.delete(message.id);
    entry.resolve(message);
  });
  const exited = new Promise((resolve) => child.once("exit", (code) => resolve(code)));
  child.once("exit", (code, signal) => {
    for (const { reject, timer } of pending.values()) {
      clearTimeout(timer);
      reject(new Error(`bridge exited code=${code} signal=${signal}: ${stderr}`));
    }
    pending.clear();
  });

  const bridge = {
    child,
    exited,
    dataDir,
    logDir,
    workDir,
    unlockFile,
    get stderr() { return stderr; },
    // Every request is bounded. A regression that hangs a handler must fail this
    // suite, not stall it.
    request(method, params = {}, timeoutMs = 30_000) {
      const id = nextId++;
      return new Promise((resolve, reject) => {
        const timer = setTimeout(() => {
          pending.delete(id);
          reject(new Error(`bridge request timed out: ${method}; stderr=${stderr}`));
        }, timeoutMs);
        timer.unref();
        pending.set(id, { resolve, reject, timer });
        child.stdin.write(`${JSON.stringify({ jsonrpc: "2.0", id, method, params })}\n`);
      });
    },
    async call(name, args = {}, timeoutMs = 30_000) {
      const response = await bridge.request("tools/call", { name, arguments: args }, timeoutMs);
      if (response.error) throw new Error(`tools/call ${name} -> ${JSON.stringify(response.error)}`);
      return response.result;
    },
    // Success path: assert isError false and hand back the structured payload.
    async ok(name, args = {}, timeoutMs = 30_000) {
      const result = await bridge.call(name, args, timeoutMs);
      assert.equal(result.isError, false, `${name} failed: ${JSON.stringify(result.structuredContent)}`);
      return result.structuredContent;
    },
    // Failure path: dispatchTool errors come back as an isError result whose
    // structuredContent is { error, name } — the ptyError code is NOT carried, so
    // the message is the only thing a client can key on and the only thing a test
    // can assert.
    async fails(name, args = {}, timeoutMs = 30_000) {
      const result = await bridge.call(name, args, timeoutMs);
      assert.equal(result.isError, true, `${name} unexpectedly succeeded: ${JSON.stringify(result.structuredContent)}`);
      return String(result.structuredContent.error);
    },
    async stop() {
      if (child.exitCode !== null || child.signalCode !== null) return child.exitCode;
      child.kill("SIGTERM");
      const code = await Promise.race([exited, sleep(5_000).then(() => "timeout")]);
      if (code === "timeout") {
        child.kill("SIGKILL");
        await exited;
        throw new Error("bridge ignored SIGTERM");
      }
      return code;
    },
  };

  context.bridges.push(bridge);
  await bridge.request("initialize", {
    protocolVersion: "2025-06-18",
    clientInfo: { name: "pty-test", version: "1" },
    capabilities: {},
  });
  child.stdin.write(`${JSON.stringify({ jsonrpc: "2.0", method: "notifications/initialized" })}\n`);
  return bridge;
}

// Starting a session ALWAYS goes through here, so no case can forget to register
// what it created for the orphan sweep.
async function startSession(context, bridge, args) {
  const session = await bridge.ok("pty_start", args);
  assert.ok(/^pty_[0-9a-f]{8}$/.test(session.sessionId), `unexpected session id ${session.sessionId}`);
  assert.ok(Number.isInteger(session.leaderPid) && session.leaderPid > 1, "pty_start must report a real leader pid");
  assert.ok(Number.isInteger(session.helperPid) && session.helperPid > 1, "pty_start must report a real helper pid");
  assert.match(session.pts, /^\/dev\/tty/, "pty_start must report the slave device it allocated");
  const tracked = {
    id: session.sessionId,
    leaderPid: session.leaderPid,
    helperPid: session.helperPid,
    leaderCommand: await psCommand(session.leaderPid),
    helperCommand: await psCommand(session.helperPid),
  };
  context.sessions.push(tracked);
  trackedProcesses.push(tracked);
  return session;
}

// The requirement is "no orphaned helper or shell after each case". script(1) is
// not used — lib/ptyhelper.pl owns /dev/ptmx directly — so the two things that can
// outlive a case are the perl helper and the session leader's process group.
async function assertNoOrphans(context, label) {
  for (const tracked of context.sessions) {
    await poll(async () => !(await stillRunning(tracked.helperPid, tracked.helperCommand)), {
      attempts: 40,
      delayMs: 100,
      label: `${label}: pty helper ${tracked.helperPid} (${tracked.helperCommand}) to be gone`,
    });
    await poll(async () => !(await stillRunning(tracked.leaderPid, tracked.leaderCommand)), {
      attempts: 40,
      delayMs: 100,
      label: `${label}: session leader ${tracked.leaderPid} (${tracked.leaderCommand}) to be gone`,
    });
    await poll(() => processGroupGone(tracked.leaderPid), {
      attempts: 40,
      delayMs: 100,
      label: `${label}: process group ${tracked.leaderPid} to be gone`,
    });
  }
}

async function runCase(name, fn) {
  const context = { bridges: [], sessions: [] };
  const startedAt = Date.now();
  cases += 1;
  try {
    await withTimeout(fn(context), CASE_TIMEOUT_MS, `case '${name}'`);
    for (const bridge of context.bridges) await bridge.stop();
    await assertNoOrphans(context, name);
    results.push(`  PASS  ${name} (${Date.now() - startedAt}ms)`);
  } catch (error) {
    failures += 1;
    const detail = String(error?.stack || error).split("\n").slice(0, 6).join("\n        ");
    results.push(`  FAIL  ${name} (${Date.now() - startedAt}ms)\n        ${detail}`);
    for (const bridge of context.bridges) {
      try { await bridge.stop(); } catch {}
    }
    try {
      await assertNoOrphans(context, name);
    } catch (orphan) {
      results.push(`        ORPHAN  ${orphan.message}`);
    }
  }
}

// ---------------------------------------------------------------------------
// Negative cases first.

await runCase("pty tools are absent, not broken, when the helper cannot run", async (context) => {
  const bridge = await startBridge(context, {
    env: { DARWINRELAY_PTY_HELPER: path.join(temporaryRoot, "no-such-helper.pl") },
  });
  const listed = await bridge.request("tools/list");
  const names = listed.result.tools.map((tool) => tool.name);
  assert.deepEqual(names.filter((name) => name.startsWith("pty_")), [], "an unavailable pty must be a loud absence, not six tools that fail at call time");
  assert.ok(names.includes("shell_exec"), "the rest of the bridge must be unaffected");
  // Advertised set and callable set must agree in BOTH directions.
  const call = await bridge.request("tools/call", { name: "pty_start", arguments: { command: "/bin/sh" } });
  assert.equal(call.error?.code, -32601, `expected -32601, got ${JSON.stringify(call.error || call.result)}`);
  const status = await bridge.ok("bridge_status");
  assert.equal(status.ptyAvailable, false);
  assert.equal(status.ptyHelper, null);
  assert.deepEqual(status.ptySessions, []);
  assert.match(bridge.stderr, /pty helper unavailable|pty support self-test/, "the operator must be told why the tools vanished");
});

await runCase("unknown, malformed and cross-instance session ids are refused by every pty tool", async (context) => {
  const bridge = await startBridge(context);
  const other = await startBridge(context);
  // A live session on ANOTHER bridge: ids are per-process and must not be
  // guessable across instances.
  const foreign = await startSession(context, other, { command: "/bin/cat", cwd: other.workDir });

  const unknownIds = ["pty_deadbeef", foreign.sessionId];
  for (const sessionId of unknownIds) {
    for (const [tool, args] of [
      ["pty_read", { cursor: 0 }],
      ["pty_write", { data: "x" }],
      ["pty_resize", { cols: 80, rows: 24 }],
      ["pty_signal", { signal: "INT" }],
      ["pty_close", {}],
    ]) {
      const message = await bridge.fails(tool, { session_id: sessionId, ...args });
      assert.match(message, /Unknown pty session/, `${tool} accepted the unknown id ${sessionId}`);
    }
  }

  // The id becomes a filename in the jobs directory, so the character class is a
  // containment boundary and not a formatting preference.
  const malformed = ["../../etc/passwd", "pty_/../x", "pty a", "", "x".repeat(129), "pty_$(whoami)"];
  for (const sessionId of malformed) {
    const message = await bridge.fails("pty_read", { session_id: sessionId, cursor: 0 });
    assert.match(
      message,
      /Invalid session_id|'session_id' must be a non-empty string/,
      `pty_read accepted the malformed id ${JSON.stringify(sessionId)}: ${message}`,
    );
  }
  assert.equal((await fsp.readdir(path.join(bridge.dataDir, "jobs"))).length, 0, "a refused id must never create a jobs entry");

  await other.ok("pty_close", { session_id: foreign.sessionId, force: true });
});

await runCase("bad pty_start, pty_resize and pty_signal arguments fail closed", async (context) => {
  const bridge = await startBridge(context);

  assert.match(await bridge.fails("pty_start", {}), /'command' must be a non-empty string/);
  assert.match(await bridge.fails("pty_start", { command: "definitely-not-on-path-xyz" }), /not found on PATH/);
  assert.match(
    await bridge.fails("pty_start", { command: path.join(bridge.workDir, "missing-binary") }),
    /no such file/,
    "an absolute path must fail as ENOENT here, not as a session that is instantly dead with status 127",
  );
  const notExecutable = path.join(bridge.workDir, "not-executable.txt");
  await fsp.writeFile(notExecutable, "#!/bin/sh\n", { mode: 0o600 });
  assert.match(await bridge.fails("pty_start", { command: notExecutable }), /not executable/);
  assert.match(await bridge.fails("pty_start", { command: "/bin/cat", cwd: path.join(bridge.workDir, "no-such-dir") }), /is unusable: ENOENT/);
  assert.match(await bridge.fails("pty_start", { command: "/bin/cat", cwd: notExecutable }), /is not a directory/);
  assert.match(await bridge.fails("pty_start", { command: "/bin/cat", term: "nonsense" }), /'term' must be one of/);
  assert.match(await bridge.fails("pty_start", { command: "/bin/cat", cols: 5000 }), /'cols' must be between 20 and 500/);
  assert.match(await bridge.fails("pty_start", { command: "/bin/cat", args: ["ok", 7] }), /'args' must be an array of strings/);

  const session = await startSession(context, bridge, { command: "/bin/cat", cwd: bridge.workDir });
  assert.match(await bridge.fails("pty_resize", { session_id: session.sessionId, cols: 10, rows: 24 }), /'cols' must be between 20 and 500/);
  assert.match(await bridge.fails("pty_resize", { session_id: session.sessionId, cols: 80, rows: 1 }), /'rows' must be between 5 and 200/);
  assert.match(await bridge.fails("pty_resize", { session_id: session.sessionId, cols: 80 }), /'cols' and 'rows' are required/);
  // The enum is re-validated in dispatchTool, because the schema is a hint to the
  // client and this signal is aimed at a whole process group.
  for (const signal of ["SIGINT", "STOP", "9", "INT; rm -rf /", ""]) {
    const message = await bridge.fails("pty_signal", { session_id: session.sessionId, signal });
    assert.match(message, /must be one of INT, TERM, KILL|'signal' must be a non-empty string/, `pty_signal accepted ${JSON.stringify(signal)}`);
  }
  assert.match(
    await bridge.fails("pty_write", { session_id: session.sessionId, data: "y".repeat(70_000) }),
    /is 70000 bytes; the limit is 65536/,
  );
  await bridge.ok("pty_close", { session_id: session.sessionId, force: true });
});

await runCase("a closed session cannot be written to, still reads back, and is eventually evicted", async (context) => {
  const bridge = await startBridge(context, { env: { DARWINRELAY_PTY_MAX_SESSIONS: "2" } });
  const session = await startSession(context, bridge, {
    command: "/bin/sh",
    args: ["-c", "echo before-close; sleep 30"],
    cwd: bridge.workDir,
  });
  await poll(async () => (await bridge.ok("pty_read", { session_id: session.sessionId, cursor: 0 })).text.includes("before-close"), {
    label: "the session to produce output",
  });

  const closed = await bridge.ok("pty_close", { session_id: session.sessionId });
  assert.equal(closed.reason, "closed");
  assert.equal(closed.containmentVerified, true, "pty_close must verify the group is actually gone");

  // Reading an exited session is how final output is collected, so it must not
  // become an error the moment the session ends.
  const afterClose = await bridge.ok("pty_read", { session_id: session.sessionId, cursor: 0 });
  assert.equal(afterClose.exited, true);
  assert.equal(afterClose.closeReason, "closed");
  assert.match(afterClose.text, /before-close/);

  // Writing to it must not silently resurrect anything.
  assert.match(await bridge.fails("pty_write", { session_id: session.sessionId, data: "x" }), /has finished/);
  assert.match(await bridge.fails("pty_resize", { session_id: session.sessionId, cols: 80, rows: 24 }), /has finished/);
  assert.match(await bridge.fails("pty_signal", { session_id: session.sessionId, signal: "TERM" }), /has finished/);
  // Closing twice reports the recorded outcome instead of throwing.
  const again = await bridge.ok("pty_close", { session_id: session.sessionId });
  assert.equal(again.reason, "closed");

  // The table is capped INCLUDING exited sessions, so a closed id is reclaimed
  // rather than kept forever; the error then has to say so.
  await startSession(context, bridge, { command: "/bin/cat", cwd: bridge.workDir });
  await startSession(context, bridge, { command: "/bin/cat", cwd: bridge.workDir });
  const evicted = await bridge.fails("pty_read", { session_id: session.sessionId, cursor: 0 });
  assert.match(evicted, /Unknown pty session/);
  assert.match(evicted, /closed sessions are eventually evicted/, "the model needs to be told to start a new session, not poll a dead id forever");
});

// ---------------------------------------------------------------------------
// Round trip and streaming.

await runCase("start, write, read and close round trip against a real interactive prompt", async (context) => {
  const bridge = await startBridge(context);
  // A prompt that only exists on a tty: it refuses to run on a pipe, prints
  // without a trailing newline (so the client must see the prompt before any
  // answer is written), and echoes what it read.
  const prompt = path.join(bridge.workDir, "prompt.mjs");
  await fsp.writeFile(prompt, [
    'if (!process.stdin.isTTY || !process.stdout.isTTY) { process.stdout.write("NOT-A-TTY\\n"); process.exit(9); }',
    'process.stdout.write("tty=" + process.stdin.isTTY + " term=" + process.env.TERM + "\\n");',
    'process.stdout.write("Passphrase: ");',
    'let buffer = "";',
    'process.stdin.setEncoding("utf8");',
    'process.stdin.on("data", (chunk) => {',
    '  buffer += chunk;',
    // The client sends \r because that is what a terminal sends; ICRNL in the line
    // discipline turns it into \n before the program sees it. Accepting only one of
    // the two would make this program, not the bridge, the thing under test.
    '  const end = buffer.search(/[\\r\\n]/);',
    '  if (end < 0) return;',
    '  process.stdout.write("\\nGOT[" + buffer.slice(0, end) + "]\\n");',
    '  process.exit(0);',
    '});',
  ].join("\n"));

  const session = await startSession(context, bridge, {
    command: process.execPath,
    args: [prompt],
    cwd: bridge.workDir,
    cols: 100,
    rows: 40,
    label: "round trip",
  });
  assert.equal(session.cols, 100);
  assert.equal(session.rows, 40);
  assert.equal(session.cursor, 0);
  assert.equal(session.cwd, bridge.workDir);

  const prompted = await poll(async () => {
    const read = await bridge.ok("pty_read", { session_id: session.sessionId, cursor: 0, wait_ms: 1_000 });
    return read.text.includes("Passphrase: ") ? read : null;
  }, { label: "the interactive prompt" });
  assert.match(prompted.text, /tty=true term=xterm-256color/, "the child must be on a real terminal with TERM set");
  assert.equal(prompted.exited, false);
  assert.equal(prompted.lostBytes, 0);

  const written = await bridge.ok("pty_write", { session_id: session.sessionId, data: "correct horse battery\r" });
  assert.equal(written.bytesWritten, 22);

  const answered = await poll(async () => {
    const read = await bridge.ok("pty_read", { session_id: session.sessionId, cursor: prompted.nextCursor, wait_ms: 1_000 });
    return read.text.includes("GOT[") ? read : null;
  }, { label: "the program to consume the typed line" });
  assert.match(answered.text, /GOT\[correct horse battery\]/, "input must reach the program exactly as typed");
  assert.equal(answered.cursor, prompted.nextCursor, "reads must continue from the previous next_cursor without a gap");

  const finished = await poll(async () => {
    const read = await bridge.ok("pty_read", { session_id: session.sessionId, cursor: 0 });
    return read.exited ? read : null;
  }, { label: "the program to exit" });
  assert.equal(finished.exitCode, 0);
  assert.match(finished.text, /Passphrase: /, "the whole transcript stays readable after exit");

  const closed = await bridge.ok("pty_close", { session_id: session.sessionId });
  assert.equal(closed.containmentVerified, true);
  assert.equal(closed.totalBytes, finished.totalBytes);
});

await runCase("output keeps its order and loses nothing across repeated reads", async (context) => {
  const bridge = await startBridge(context);
  const total = 400;
  const session = await startSession(context, bridge, {
    command: "/bin/sh",
    args: ["-c", `i=1; while [ $i -le ${total} ]; do echo "L$i"; i=$((i+1)); done; echo END-OF-STREAM`],
    cwd: bridge.workDir,
  });

  let cursor = 0;
  let text = "";
  let reads = 0;
  await poll(async () => {
    // max_bytes at the schema minimum, so the boundaries land in the middle of
    // lines and the reassembly is actually exercised.
    const read = await bridge.ok("pty_read", { session_id: session.sessionId, cursor, max_bytes: 1_024, wait_ms: 500 });
    reads += 1;
    assert.equal(read.cursor, cursor, "a read must report the cursor it was given");
    assert.ok(read.nextCursor >= cursor, "next_cursor must never go backwards");
    assert.equal(read.lostBytes, 0, "nothing may be dropped while the ring is far from full");
    text += read.text;
    cursor = read.nextCursor;
    return read.exited && cursor >= read.totalBytes;
  }, { attempts: 200, delayMs: 50, label: "the full stream" });
  assert.ok(reads > 1, "the stream must have taken more than one read, or the boundary logic is untested");

  const lines = text.split("\n").filter((line) => line.length > 0);
  const expected = [...Array.from({ length: total }, (_, index) => `L${index + 1}`), "END-OF-STREAM"];
  assert.deepEqual(lines, expected, "every line, in order, exactly once");

  // A retried read is the normal case on a public endpoint: the same cursor must
  // return the same bytes rather than draining them.
  const first = await bridge.ok("pty_read", { session_id: session.sessionId, cursor: 0, max_bytes: 2_048 });
  const repeat = await bridge.ok("pty_read", { session_id: session.sessionId, cursor: 0, max_bytes: 2_048 });
  assert.equal(repeat.text, first.text);
  assert.equal(repeat.nextCursor, first.nextCursor);
  assert.equal(first.truncated, true, "a partial read must say more follows");
  const tail = await bridge.ok("pty_read", { session_id: session.sessionId, cursor: first.totalBytes, max_bytes: 2_048 });
  assert.equal(tail.text, "", "a cursor at the end returns nothing, not an error");
  assert.equal(tail.truncated, false);
  await bridge.ok("pty_close", { session_id: session.sessionId, force: true });
});

await runCase("multibyte output survives read boundaries and a wrapped ring", async (context) => {
  // 4096 is the floor the ring accepts, so the 300 lines below overrun it many
  // times over and every read starts mid-buffer.
  const bridge = await startBridge(context, { env: { DARWINRELAY_PTY_RING_BYTES: "4096" } });
  const session = await startSession(context, bridge, {
    command: "/bin/sh",
    args: ["-c", 'i=1; while [ $i -le 300 ]; do echo "$i:日本語テキスト-ünïcödé-🎉"; i=$((i+1)); done; echo UTF8-END'],
    cwd: bridge.workDir,
  });
  const done = await poll(async () => {
    const read = await bridge.ok("pty_read", { session_id: session.sessionId, cursor: 0, max_bytes: 1_000_000, wait_ms: 500 });
    return read.exited ? read : null;
  }, { label: "the generator to finish" });

  assert.ok(done.lostBytes > 0, "the ring must actually have overflowed for this case to mean anything");
  assert.equal(done.text.includes("�"), false, "a slice that starts mid-codepoint must be realigned, not turned into U+FFFD");
  assert.match(done.text, /UTF8-END/, "a full ring keeps the NEWEST bytes; a terminal's last screen is the one being looked at");
  // Line-anchored: "1:..." is a substring of "121:...", so a plain includes() would
  // pass on a ring that had dropped nothing.
  assert.equal(done.text.split("\n").includes("1:日本語テキスト-ünïcödé-🎉"), false, "the oldest bytes are the ones dropped");

  let cursor = 0;
  let text = "";
  await poll(async () => {
    const read = await bridge.ok("pty_read", { session_id: session.sessionId, cursor, max_bytes: 1_024 });
    text += read.text;
    cursor = read.nextCursor;
    return cursor >= read.totalBytes;
  }, { attempts: 100, delayMs: 20, label: "paged reads over a wrapped ring" });
  assert.equal(text.includes("�"), false, "paging over a wrapped ring must not manufacture replacement characters");
  const intact = text.split("\n").filter((line) => /^\d+:/.test(line));
  assert.ok(intact.length > 10, "expected many whole lines to survive");
  for (const line of intact) {
    assert.match(line, /^\d+:日本語テキスト-ünïcödé-🎉$/, `a line was corrupted crossing a read boundary: ${JSON.stringify(line)}`);
  }
});

await runCase("a program that writes CRLF keeps its output", async (context) => {
  // ONLCR turns every \n the child writes into \r\n, so a program that already
  // emits CRLF reaches the master as \r\r\n. The progress-redraw collapse must
  // still leave the line's text alone: there is no redraw here, only a line
  // ending. Anything that prints CRLF on a terminal — ssh, git, node's readline,
  // every TUI — depends on this.
  const bridge = await startBridge(context);
  const session = await startSession(context, bridge, {
    command: "/bin/sh",
    args: ["-c", "printf 'alpha\\r\\nbeta\\r\\n'; printf 'plain\\n'; printf 'step 1/3\\rstep 2/3\\rstep 3/3\\n'"],
    cwd: bridge.workDir,
  });
  const done = await poll(async () => {
    const read = await bridge.ok("pty_read", { session_id: session.sessionId, cursor: 0, wait_ms: 500 });
    return read.exited ? read : null;
  }, { label: "the program to finish" });

  const raw = await bridge.ok("pty_read", {
    session_id: session.sessionId,
    cursor: 0,
    strip_ansi: false,
    collapse_carriage_returns: false,
  });
  assert.match(raw.text, /alpha\r\r\n/, "the raw view must show what the terminal really carried");

  const lines = done.text.split("\n");
  assert.ok(lines.includes("alpha"), `a CRLF-terminated line must survive the default rendering; got ${JSON.stringify(done.text)}`);
  assert.ok(lines.includes("beta"), `a CRLF-terminated line must survive the default rendering; got ${JSON.stringify(done.text)}`);
  assert.ok(lines.includes("plain"));
  // And the redraw collapse it exists for still works.
  assert.ok(lines.includes("step 3/3"), "the last segment of a CR-redrawn line is the one to keep");
  assert.equal(done.text.includes("step 1/3"), false, "overwritten redraw segments must be dropped");
});

await runCase("stripping ANSI is stable across read boundaries", async (context) => {
  // The slice logic realigns UTF-8 and holds back a lone trailing CR, but an
  // escape sequence split by the same boundary is stripped by neither read: the
  // ESC lands at the end of one slice and the "[0m" at the start of the next, so
  // paging through coloured output puts raw escape bytes into text the tool
  // promised had them removed.
  const bridge = await startBridge(context);
  const session = await startSession(context, bridge, {
    command: "/bin/sh",
    args: ["-c", "i=1; while [ $i -le 300 ]; do printf '\\033[33mW%s\\033[0m-colourful-line-of-text\\n' $i; i=$((i+1)); done; echo ANSI-END"],
    cwd: bridge.workDir,
  });
  const whole = await poll(async () => {
    const read = await bridge.ok("pty_read", { session_id: session.sessionId, cursor: 0, max_bytes: 1_000_000, wait_ms: 500 });
    return read.exited ? read : null;
  }, { label: "the coloured generator to finish" });
  assert.equal(whole.text.includes(ESC), false, "a single read strips every escape");

  let cursor = 0;
  let paged = "";
  await poll(async () => {
    const read = await bridge.ok("pty_read", { session_id: session.sessionId, cursor, max_bytes: 1_024 });
    paged += read.text;
    cursor = read.nextCursor;
    return cursor >= read.totalBytes;
  }, { attempts: 200, delayMs: 10, label: "paged reads over coloured output" });

  assert.equal(paged.includes(ESC), false, "paging must not leak raw escape bytes into stripped text");
  assert.equal(paged, whole.text, "paged reads and one big read must render the same transcript");
});

// ---------------------------------------------------------------------------
// Bounds.

await runCase("the session cap is enforced and released by pty_close", async (context) => {
  const bridge = await startBridge(context, { env: { DARWINRELAY_PTY_MAX_SESSIONS: "2" } });
  const status = await bridge.ok("bridge_status");
  assert.equal(status.ptyLimits.maxSessions, 2);
  assert.equal(status.ptyLimits.ringBytesGlobal, 2 * status.ptyLimits.ringBytesPerSession, "the global retention bound is the per-session ring times the session cap");

  const first = await startSession(context, bridge, { command: "/bin/cat", cwd: bridge.workDir });
  const second = await startSession(context, bridge, { command: "/bin/cat", cwd: bridge.workDir });
  const refused = await bridge.fails("pty_start", { command: "/bin/cat", cwd: bridge.workDir });
  assert.match(refused, /pty session limit reached \(2 live\); close one with pty_close first\./);

  // kern.tty.ptmx_max is a system-wide 511: a refused start must not have leaked a
  // helper on its way out.
  const afterRefusal = await bridge.ok("bridge_status");
  assert.equal(afterRefusal.ptySessions.filter((entry) => !entry.exited).length, 2);

  await bridge.ok("pty_close", { session_id: first.sessionId });
  const third = await startSession(context, bridge, { command: "/bin/cat", cwd: bridge.workDir });
  assert.notEqual(third.sessionId, first.sessionId);
  await bridge.ok("pty_close", { session_id: second.sessionId, force: true });
  await bridge.ok("pty_close", { session_id: third.sessionId, force: true });
});

await runCase("the session cap holds against concurrent pty_start", async (context) => {
  // The cap used to be CHECKED and then yielded on (await fsp.stat(cwd)) before
  // anything was registered, so every concurrent request passed a check none of
  // them had yet invalidated: measured, 60 concurrent starts produced 58 live
  // ptys against a cap of 8. kern.tty.ptmx_max is 511 system-wide, so a large
  // enough batch takes Terminal.app and ssh away from the operator — the path to
  // scripts/disable.sh — and mcp-http.mjs caps neither connections nor
  // concurrent requests.
  const cap = 3;
  const bridge = await startBridge(context, { env: { DARWINRELAY_PTY_MAX_SESSIONS: String(cap) } });
  const attempts = 24;
  const settled = await Promise.all(
    Array.from({ length: attempts }, () => bridge.call("pty_start", { command: "/bin/cat", cwd: bridge.workDir })),
  );
  const started = settled.filter((result) => result.isError === false).map((result) => result.structuredContent);
  const refused = settled.filter((result) => result.isError === true);
  // Registered for the orphan sweep before anything can throw.
  for (const session of started) {
    context.sessions.push({
      id: session.sessionId,
      leaderPid: session.leaderPid,
      helperPid: session.helperPid,
      leaderCommand: await psCommand(session.leaderPid),
      helperCommand: await psCommand(session.helperPid),
    });
  }

  assert.equal(started.length + refused.length, attempts);
  assert.ok(started.length <= cap, `${started.length} sessions started against a cap of ${cap}`);
  assert.equal(refused.length, attempts - started.length);
  for (const result of refused) {
    assert.match(String(result.structuredContent.error), /pty session limit reached/);
  }

  // The bridge's own view has to agree, and so does the process table: a refused
  // start must not have leaked a helper on its way out.
  const status = await bridge.ok("bridge_status");
  const live = status.ptySessions.filter((entry) => !entry.exited);
  assert.equal(live.length, started.length);
  assert.ok(live.length <= cap);
  for (const session of started) {
    assert.equal(await stillRunning(session.helperPid), true, "a started session must have a live helper");
  }

  // And the cap is a bound, not a one-shot: closing one frees exactly one slot.
  await bridge.ok("pty_close", { session_id: started[0].sessionId, force: true });
  const replacement = await startSession(context, bridge, { command: "/bin/cat", cwd: bridge.workDir });
  await bridge.fails("pty_start", { command: "/bin/cat", cwd: bridge.workDir });
  await bridge.ok("pty_close", { session_id: replacement.sessionId, force: true });
  for (const session of started.slice(1)) {
    await bridge.ok("pty_close", { session_id: session.sessionId, force: true });
  }
});

await runCase("the per-session output cap drops the oldest bytes and says so", async (context) => {
  const bridge = await startBridge(context, { env: { DARWINRELAY_PTY_RING_BYTES: "4096" } });
  const session = await startSession(context, bridge, {
    command: "/bin/sh",
    args: ["-c", 'i=0; while [ $i -lt 800 ]; do echo "line-$i-paddingpaddingpadding"; i=$((i+1)); done; echo RING-END'],
    cwd: bridge.workDir,
  });
  const done = await poll(async () => {
    const read = await bridge.ok("pty_read", { session_id: session.sessionId, cursor: 0, max_bytes: 1_000_000, wait_ms: 500 });
    return read.exited ? read : null;
  }, { label: "the noisy generator to finish" });

  assert.ok(done.totalBytes > 20_000, `expected a lot of output, got ${done.totalBytes}`);
  assert.equal(done.retainedBytes, 4_096, "retention is a fixed-capacity ring, not a growing chunk list");
  assert.equal(done.lostBytes, done.totalBytes - done.retainedBytes, "lost_bytes must account for exactly what the ring dropped");
  assert.ok(Buffer.byteLength(done.text, "utf8") <= 4_096);
  assert.match(done.text, /RING-END/, "the newest bytes are the ones kept");
  assert.equal(done.text.includes("line-0-"), false, "the oldest bytes are the ones dropped");

  // A cursor that fell behind the ring is not an error: it resumes at the oldest
  // retained byte and reports how much it missed.
  const behind = await bridge.ok("pty_read", { session_id: session.sessionId, cursor: 5, max_bytes: 1_000_000 });
  assert.ok(behind.lostBytes > 0);
  assert.equal(behind.nextCursor, done.totalBytes);
  await bridge.ok("pty_close", { session_id: session.sessionId, force: true });
});

await runCase("an idle session is reclaimed even while it is producing output", async (context) => {
  // "Output from the child does not count as activity" is the documented rule, and
  // it is the one that matters: a forgotten `tail -f` would otherwise hold an
  // unrestricted shell open forever.
  const bridge = await startBridge(context, { env: { DARWINRELAY_PTY_IDLE_TIMEOUT_MS: "1500" } });
  const status = await bridge.ok("bridge_status");
  assert.equal(status.ptyLimits.idleTimeoutMs, 1_500);

  const chatty = await startSession(context, bridge, {
    command: "/bin/sh",
    args: ["-c", "while :; do echo chatter; sleep 0.2; done"],
    cwd: bridge.workDir,
  });
  const silent = await startSession(context, bridge, {
    command: "/bin/sh",
    args: ["-c", "while :; do sleep 1; done"],
    cwd: bridge.workDir,
  });

  // Watched through bridge_status, NOT through pty_read: a read is a tool call
  // against the session and resets its idle clock, so a polling reader would keep
  // the session alive forever and the test would be measuring itself.
  // The sweeper runs every 5s, so the deadline is the timeout plus one sweep.
  const summaryOf = async (id) => {
    const status = await bridge.ok("bridge_status");
    const entry = status.ptySessions.find((item) => item.id === id);
    assert.ok(entry, `session ${id} vanished from bridge_status`);
    return entry.exited ? entry : null;
  };
  const reclaimed = await poll(() => summaryOf(chatty.sessionId), {
    attempts: 40, delayMs: 500, label: "the idle sweeper to reclaim a chatty session",
  });
  assert.equal(reclaimed.closeReason, "idle_timeout");
  assert.ok(reclaimed.totalBytes > 0, "the chatty session really was producing output the whole time it was 'idle'");
  assert.ok(processGroupGone(chatty.leaderPid), "an idle reclaim must take the process group, not just the bookkeeping");
  // Its output stays readable after reclamation.
  const finalRead = await bridge.ok("pty_read", { session_id: chatty.sessionId, cursor: 0, max_bytes: 2_048 });
  assert.equal(finalRead.exited, true);
  assert.match(finalRead.text, /chatter/);

  const other = await poll(() => summaryOf(silent.sessionId), {
    attempts: 40, delayMs: 500, label: "the silent session to be reclaimed too",
  });
  assert.equal(other.closeReason, "idle_timeout");
  assert.match(bridge.stderr, /idle for \d+ms; reclaiming/);
});

await runCase("the lifetime ceiling reclaims a session that is being actively used", async (context) => {
  const bridge = await startBridge(context, {
    env: { DARWINRELAY_PTY_MAX_LIFETIME_MS: "5000", DARWINRELAY_PTY_IDLE_TIMEOUT_MS: "600000" },
  });
  const session = await startSession(context, bridge, {
    command: "/bin/sh",
    args: ["-c", "while :; do sleep 1; done"],
    cwd: bridge.workDir,
  });
  const reclaimed = await poll(async () => {
    // Reading keeps the session non-idle, so only the lifetime ceiling can end it.
    const read = await bridge.ok("pty_read", { session_id: session.sessionId, cursor: 0 });
    return read.exited ? read : null;
  }, { attempts: 30, delayMs: 500, label: "the lifetime ceiling" });
  assert.equal(reclaimed.closeReason, "max_lifetime");
  assert.ok(processGroupGone(session.leaderPid));
});

await runCase("oversized writes are refused rather than queued", async (context) => {
  const bridge = await startBridge(context);
  // A child that never reads stdin: the pty fills, the helper blocks, and the
  // outbound buffer would grow without limit if writes were queued.
  const session = await startSession(context, bridge, {
    command: "/bin/sh",
    args: ["-c", "while :; do sleep 5; done"],
    cwd: bridge.workDir,
  });
  // 64 KiB per write, but shaped as 1023-byte lines. A single 65536-byte run with
  // no line ending is refused earlier and for a different reason — the terminal
  // would discard it — and that refusal would not exercise the outbound buffer at
  // all. Same payload size, same bound under test.
  const payload = `${"z".repeat(1_023)}\r`.repeat(64);
  assert.equal(Buffer.byteLength(payload), 65_536);
  let refusal = null;
  for (let attempt = 0; attempt < 60 && refusal === null; attempt += 1) {
    const result = await bridge.call("pty_write", { session_id: session.sessionId, data: payload });
    if (result.isError) refusal = String(result.structuredContent.error);
  }
  assert.ok(refusal, "60 unread 64 KiB writes were all accepted; the outbound buffer is unbounded");
  assert.match(refusal, /bytes of unread input; retry once the program consumes it/);
  // The refusal must not have broken the session.
  const status = await bridge.ok("bridge_status");
  const entry = status.ptySessions.find((item) => item.id === session.sessionId);
  assert.equal(entry.exited, false, "backpressure must be a refusal, not a session kill");
  await bridge.ok("pty_close", { session_id: session.sessionId, force: true });
});

// ---------------------------------------------------------------------------
// Signals and geometry.

await runCase("a line the terminal would discard is refused, not reported as written", async (context) => {
  // Canonical mode is the default for every session and for every interactive
  // prompt these tools exist to drive. On Darwin its line discipline DISCARDS an
  // input line of MAX_CANON (1024) bytes or more ENTIRELY — it does not truncate
  // it. Measured on the shipped code: 1023 bytes arrived intact; 1024, 2000,
  // 4096, 20000 and 65000 all arrived as literally nothing while pty_write
  // returned the full bytesWritten. An SSH key, a commit body or a base64 blob
  // was silently lost while the model was told it had been delivered.
  const bridge = await startBridge(context);
  const reader = () => ({
    command: "/bin/sh",
    args: ["-c", "IFS= read -r line; echo \"GOT=${#line}\""],
    cwd: bridge.workDir,
  });

  // The largest line that really works still works.
  const ok = await startSession(context, bridge, reader());
  const okWrite = await bridge.ok("pty_write", { session_id: ok.sessionId, data: `${"A".repeat(1_023)}\r` });
  assert.equal(okWrite.bytesWritten, 1_024);
  const okOut = await poll(async () => {
    const read = await bridge.ok("pty_read", { session_id: ok.sessionId, cursor: 0, wait_ms: 500 });
    return read.text.includes("GOT=") ? read.text : null;
  }, { label: "the program to report what it received" });
  assert.match(okOut, /GOT=1023/, "1023 bytes plus a terminator is under MAX_CANON and must be delivered");

  // One byte more is refused, with the reason, instead of being reported written.
  const over = await startSession(context, bridge, reader());
  const refused = await bridge.fails("pty_write", { session_id: over.sessionId, data: `${"A".repeat(4_096)}\r` });
  assert.match(refused, /canonical mode/);
  assert.match(refused, /1023/, "the refusal must say what would work");

  // And chunking does not evade it: MAX_CANON applies to the line the discipline
  // is assembling, not to one write. Measured, the same over-long line sent in
  // 200-byte pieces was discarded exactly the same way.
  const chunked = await startSession(context, bridge, reader());
  await bridge.ok("pty_write", { session_id: chunked.sessionId, data: "B".repeat(600) });
  const chunkRefusal = await bridge.fails("pty_write", { session_id: chunked.sessionId, data: "B".repeat(600) });
  assert.match(chunkRefusal, /canonical mode/);

  // A raw-mode session has no MAX_CANON, and must NOT be refused: the guard is
  // about what the terminal really does, not a blanket length limit.
  const raw = await startSession(context, bridge, {
    command: "/bin/sh",
    args: ["-c", "stty raw -echo; head -c 5000 | wc -c; stty sane"],
    cwd: bridge.workDir,
  });
  const accepted = await poll(async () => {
    const result = await bridge.call("pty_write", { session_id: raw.sessionId, data: "C".repeat(5_000) });
    return result.isError ? null : result.structuredContent;
  }, { attempts: 40, delayMs: 100, label: "the raw-mode session to accept a 5000-byte write" });
  assert.equal(accepted.canonicalMode, false, "a raw-mode session must be allowed the write, and told apart from a canonical one");
  const rawOut = await poll(async () => {
    const read = await bridge.ok("pty_read", { session_id: raw.sessionId, cursor: 0, wait_ms: 500 });
    return /5000/.test(read.text) ? read.text : null;
  }, { attempts: 40, delayMs: 100, label: "the raw-mode program to count 5000 bytes" });
  assert.match(rawOut, /5000/, "every byte must reach a program whose terminal is in raw mode");

  for (const session of [ok, over, chunked, raw]) {
    await bridge.ok("pty_close", { session_id: session.sessionId, force: true });
  }
});

await runCase("pty_signal delivers SIGINT to the foreground program", async (context) => {
  const bridge = await startBridge(context);
  const session = await startSession(context, bridge, {
    command: "/bin/sh",
    args: ["-c", "trap 'echo TRAPPED_INT; exit 42' INT; echo ARMED; while :; do sleep 0.2; done"],
    cwd: bridge.workDir,
  });
  await poll(async () => (await bridge.ok("pty_read", { session_id: session.sessionId, cursor: 0, wait_ms: 500 })).text.includes("ARMED"), {
    label: "the trap to be armed",
  });

  const signalled = await bridge.ok("pty_signal", { session_id: session.sessionId, signal: "INT" });
  assert.equal(signalled.delivered, true, "delivery is reported by the helper's own kill(2), not assumed");
  assert.equal(signalled.signal, "INT");
  assert.equal(signalled.targetProcessGroup, session.leaderPid);

  const finished = await poll(async () => {
    const read = await bridge.ok("pty_read", { session_id: session.sessionId, cursor: 0, wait_ms: 500 });
    return read.exited ? read : null;
  }, { label: "the trapped program to exit" });
  assert.match(finished.text, /TRAPPED_INT/, "the signal must reach the program, not just the kernel");
  assert.equal(finished.exitCode, 42, "the program's own exit status must be reported");
  assert.ok(processGroupGone(session.leaderPid));
});

await runCase("Ctrl-C written to the terminal interrupts the foreground program and keeps the shell", async (context) => {
  const bridge = await startBridge(context);
  const session = await startSession(context, bridge, {
    command: "/bin/sh",
    args: ["-i"],
    cwd: bridge.workDir,
    env: { PS1: "READY> " },
  });
  await poll(async () => (await bridge.ok("pty_read", { session_id: session.sessionId, cursor: 0, wait_ms: 500 })).text.includes("READY> "), {
    label: "the shell prompt",
  });
  await bridge.ok("pty_write", { session_id: session.sessionId, data: "sleep 30\r" });
  await sleep(500);
  // 0x03 through the line discipline, which is what makes this different from
  // pty_signal: only the foreground job gets it.
  await bridge.ok("pty_write", { session_id: session.sessionId, data: CTRL_C });

  const interrupted = await poll(async () => {
    const read = await bridge.ok("pty_read", { session_id: session.sessionId, cursor: 0, wait_ms: 500 });
    return read.text.includes("^C") ? read : null;
  }, { label: "the foreground sleep to be interrupted" });
  assert.equal(interrupted.exited, false, "the shell itself must survive a Ctrl-C aimed at its child");

  await bridge.ok("pty_write", { session_id: session.sessionId, data: "echo STILL_ALIVE\r" });
  const alive = await poll(async () => {
    const read = await bridge.ok("pty_read", { session_id: session.sessionId, cursor: 0, wait_ms: 500 });
    return read.text.includes("STILL_ALIVE") ? read : null;
  }, { label: "the shell to keep accepting commands" });
  assert.equal(alive.exited, false);
  await bridge.ok("pty_close", { session_id: session.sessionId });
});

await runCase("an ordinary background job does not survive pty_close", async (context) => {
  // `cmd &` at an interactive prompt. No disown, no setsid, no attacker: job
  // control simply puts the job in its own process group, so a kill aimed at
  // -leaderPid never reaches it. Measured on the shipped code, pty_close returned
  // containmentVerified:true while ps showed the job still running, reparented to
  // pid 1 — and containmentVerified is the one field the design calls honest.
  const bridge = await startBridge(context);
  const session = await startSession(context, bridge, {
    command: "/bin/zsh",
    args: ["-f", "-i"],
    cwd: bridge.workDir,
  });
  await bridge.ok("pty_write", {
    session_id: session.sessionId,
    data: "/bin/sh -c 'while :; do sleep 5; done' & echo BG=$!\r",
  });
  const backgroundPid = await poll(async () => {
    const read = await bridge.ok("pty_read", { session_id: session.sessionId, cursor: 0, wait_ms: 500 });
    const match = /BG=(\d+)/.exec(read.text);
    return match ? Number(match[1]) : null;
  }, { attempts: 40, delayMs: 100, label: "the background job to report its pid" });

  const backgroundCommand = await psCommand(backgroundPid);
  assert.match(backgroundCommand, /while :; do sleep 5; done/, "the test must be looking at the job it started");
  // It really is outside the leader's process group — that is the whole point.
  const backgroundGroup = (await ps(backgroundPid, "pgid=")).trim();
  assert.notEqual(Number(backgroundGroup), session.leaderPid, "job control must have given the job its own group");

  let closed;
  try {
    closed = await bridge.ok("pty_close", { session_id: session.sessionId });
  } finally {
    // Never leave it behind if an assertion above threw, and only after the
    // recorded command line still matches.
    if (await stillRunning(backgroundPid, backgroundCommand)) {
      try { process.kill(backgroundPid, "SIGKILL"); } catch {}
    }
  }
  assert.ok(closed.ttyProcessesKilled.includes(backgroundPid), `the background job must be reclaimed by pts, not just by pgid; got ${JSON.stringify(closed.ttyProcessesKilled)}`);
  assert.deepEqual(closed.uncontainedPids, []);
  assert.equal(closed.containmentVerified, true);
  await poll(async () => !(await stillRunning(backgroundPid, backgroundCommand)), {
    attempts: 40,
    delayMs: 100,
    label: "the background job to be gone",
  });
});

await runCase("pty_resize changes the window size the child sees", async (context) => {
  const bridge = await startBridge(context);
  const winch = path.join(bridge.workDir, "winch.mjs");
  await fsp.writeFile(winch, [
    'process.stdout.write("SIZE:" + process.stdout.columns + "x" + process.stdout.rows + "\\n");',
    'process.on("SIGWINCH", () => process.stdout.write("WINCH:" + process.stdout.columns + "x" + process.stdout.rows + "\\n"));',
    'setInterval(() => {}, 1000);',
  ].join("\n"));

  const session = await startSession(context, bridge, {
    command: process.execPath,
    args: [winch],
    cwd: bridge.workDir,
    cols: 100,
    rows: 40,
  });
  await poll(async () => (await bridge.ok("pty_read", { session_id: session.sessionId, cursor: 0, wait_ms: 500 })).text.includes("SIZE:100x40"), {
    label: "the child to report its initial geometry",
  });

  const resized = await bridge.ok("pty_resize", { session_id: session.sessionId, cols: 132, rows: 50 });
  assert.equal(resized.ok, true);
  assert.equal(resized.cols, 132);
  assert.equal(resized.rows, 50);

  const observed = await poll(async () => {
    const read = await bridge.ok("pty_read", { session_id: session.sessionId, cursor: 0, wait_ms: 1_000 });
    return read.text.includes("WINCH:") ? read : null;
  }, { label: "SIGWINCH to reach the child" });
  assert.match(
    observed.text,
    /WINCH:132x50/,
    `the child must see the new geometry, not just be told a number: ${JSON.stringify(observed.text)}`,
  );
  assert.equal(observed.cols, 132, "pty_read reports the kernel's size, which must have followed the resize");
  assert.equal(observed.rows, 50);
  await bridge.ok("pty_close", { session_id: session.sessionId, force: true });

  // And the size is real to a program that asks the tty directly.
  const sizes = await startSession(context, bridge, {
    command: "/bin/sh",
    args: ["-c", "printf 'STTY[%s] TPUT[%sx%s]\\n' \"$(stty size)\" \"$(tput cols)\" \"$(tput lines)\""],
    cwd: bridge.workDir,
    cols: 111,
    rows: 44,
  });
  const reported = await poll(async () => {
    const read = await bridge.ok("pty_read", { session_id: sizes.sessionId, cursor: 0, wait_ms: 500 });
    return read.text.includes("STTY[") ? read : null;
  }, { label: "stty and tput output" });
  assert.match(reported.text, /STTY\[44 111\]/, `stty must see the requested geometry: ${JSON.stringify(reported.text)}`);
  assert.match(reported.text, /TPUT\[111x44\]/, "tput needs TERM as well as a winsize");
});

// ---------------------------------------------------------------------------
// Revocation and teardown. Containment is asserted through the process table.

async function heartbeatSession(context, bridge) {
  const marker = path.join(bridge.workDir, "heartbeat.txt");
  await fsp.writeFile(marker, "");
  // A grandchild in the same group, so the assertion covers more than the leader:
  // "the group is gone" is the claim, and a surviving grandchild keeps writing.
  const session = await startSession(context, bridge, {
    command: "/bin/sh",
    args: ["-c", `( while :; do printf x >> ${marker}; sleep 0.2; done ) & echo GRANDCHILD=$!; wait`],
    cwd: bridge.workDir,
  });
  const read = await poll(async () => {
    const value = await bridge.ok("pty_read", { session_id: session.sessionId, cursor: 0, wait_ms: 1_000 });
    return /GRANDCHILD=\d+/.test(value.text) ? value : null;
  }, { label: "the grandchild pid" });
  const grandchild = Number(/GRANDCHILD=(\d+)/.exec(read.text)[1]);
  const grandchildCommand = await psCommand(grandchild);
  await poll(async () => (await fsp.stat(marker)).size > 0, { label: "the heartbeat to start" });
  return { session, marker, grandchild, grandchildCommand };
}

// Measured while writing this: lib/ptyhelper.pl ALSO reclaims the group on its own
// when its stdin reaches EOF, so a SIGKILLed bridge still leaves nothing behind
// even for a session running `trap '' HUP`. That is welcome defence in depth, and
// it means "the group is gone" alone cannot prove which layer killed it. The
// process-table checks below are therefore paired, on the revocation path, with an
// audit assertion that the BRIDGE performed the group kill itself.
async function assertSessionContained(bridge, live, label) {
  await poll(async () => !(await stillRunning(live.session.leaderPid, null)), {
    attempts: 60, delayMs: 100, label: `${label}: leader ${live.session.leaderPid} to leave the process table`,
  });
  await poll(async () => !(await stillRunning(live.session.helperPid, null)), {
    attempts: 60, delayMs: 100, label: `${label}: helper ${live.session.helperPid} to leave the process table`,
  });
  await poll(async () => !(await stillRunning(live.grandchild, live.grandchildCommand)), {
    attempts: 60, delayMs: 100, label: `${label}: grandchild ${live.grandchild} to leave the process table`,
  });
  // The process table can lie by omission if a pid is merely reparented, so the
  // last check is behavioural: the work has to have stopped.
  const before = (await fsp.stat(live.marker)).size;
  await sleep(1_000);
  const after = (await fsp.stat(live.marker)).size;
  assert.equal(after, before, `${label}: the session was still doing work ${after - before} bytes after it was reported contained`);
}

await runCase("removing the unlock file during a tool call terminates the session and exits 78", async (context) => {
  // A high recheck interval isolates the per-call latch: whatever kills this
  // session, it is not the background sweep.
  const bridge = await startBridge(context, { env: { DARWINRELAY_UNLOCK_RECHECK_MS: "60000" } });
  const live = await heartbeatSession(context, bridge);

  await fsp.rm(bridge.unlockFile, { force: true });
  // Deliberately not awaited: on this path exitAfterFlush can win the race with
  // the response, so containment — not a returned error — is what is asserted.
  bridge.call("pty_read", { session_id: live.session.sessionId, cursor: 0 }, 9_000).catch(() => {});

  const code = await Promise.race([bridge.exited, sleep(15_000).then(() => "timeout")]);
  assert.equal(code, 78, `a revoked bridge must exit 78; stderr=${bridge.stderr}`);
  await assertSessionContained(bridge, live, "per-call revocation");
  assert.match(bridge.stderr, /Full-access unlock revoked/);

  const audit = await fsp.readFile(path.join(bridge.logDir, "audit.jsonl"), "utf8");
  const revocation = auditEntries(audit).find((entry) => entry.summary?.revoked === true);
  assert.ok(revocation, "a revocation that leaves no audit trace is the one event that must not");
});

await runCase("removing the unlock file with no further tool calls still terminates the session", async (context) => {
  // The case a call-triggered latch cannot cover. Without the recheck interval,
  // "removing the unlock file kills pty sessions" is false for exactly as long as
  // the client stops talking — and an idle interactive shell is the likeliest
  // thing to be left behind.
  const bridge = await startBridge(context, { env: { DARWINRELAY_UNLOCK_RECHECK_MS: "400" } });
  const live = await heartbeatSession(context, bridge);

  await fsp.rm(bridge.unlockFile, { force: true });
  const code = await Promise.race([bridge.exited, sleep(15_000).then(() => "timeout")]);
  assert.equal(code, 78, `an idle bridge must notice the removed latch and exit 78; stderr=${bridge.stderr}`);
  await assertSessionContained(bridge, live, "idle revocation");

  // The bridge's own reclaim, named in the audit record: this is what separates
  // "the kill switch worked" from "the helper happened to clean up after itself
  // when its parent died".
  const audit = await fsp.readFile(path.join(bridge.logDir, "audit.jsonl"), "utf8");
  const record = auditEntries(audit).find((entry) => entry.tool === "pty_unlock_recheck");
  assert.ok(record, "the idle recheck must leave its own audit record");
  assert.equal(record.summary.revoked, true);
  assert.deepEqual(
    record.summary.sessions.map((entry) => entry.id),
    [live.session.sessionId],
    "the record must name the session it reclaimed, not just a count",
  );
  const reclaimed = record.summary.reclaimed.find((entry) => entry.sessionId === live.session.sessionId);
  assert.equal(reclaimed.reason, "revoked");
  assert.equal(reclaimed.leaderGroupKilled, true, `the bridge itself must have killed the group: ${JSON.stringify(reclaimed)}`);
  assert.equal(reclaimed.helperKilled, true);
});

await runCase("SIGTERM and a closed transport both reclaim live sessions", async (context) => {
  // SIGTERM is exactly what scripts/disable.sh sends, and mcp-http.mjs sends it to
  // this child on its own shutdown, so this path runs in normal operation.
  const terminated = await startBridge(context);
  const liveTerm = await heartbeatSession(context, terminated);
  terminated.child.kill("SIGTERM");
  assert.equal(await Promise.race([terminated.exited, sleep(10_000).then(() => "timeout")]), 0);
  await assertSessionContained(terminated, liveTerm, "SIGTERM");

  const closed = await startBridge(context);
  const liveClose = await heartbeatSession(context, closed);
  closed.child.stdin.end();
  assert.equal(await Promise.race([closed.exited, sleep(10_000).then(() => "timeout")]), 0, `stderr=${closed.stderr}`);
  await assertSessionContained(closed, liveClose, "transport close");
});

// ---------------------------------------------------------------------------
// Bookkeeping the reclaimer and the audit log depend on.

await runCase("a killed helper is noticed and its shell is reclaimed, not orphaned", async (context) => {
  // The model can do this to itself with shell_exec: `pkill -f ptyhelper.pl`.
  //
  // The pty child used to inherit the helper's fd 3 — bridge.mjs's control pipe —
  // so when the helper died the pipe never reached EOF, node's stdio[3] never
  // closed, and the 'close' handler that reclaims the leader group never ran.
  // Measured on the shipped code at t=1,3,6,12,20s: helper dead, leader alive and
  // reparented to pid 1, bridge_status still reporting exited:false. It stayed
  // that way until the idle sweeper fired, up to 15 minutes by default, holding a
  // session slot the whole time — and a SIGKILL of the bridge inside that window
  // left an unrestricted shell with nothing left to reclaim it.
  //
  // The shell here ignores every signal the master-close hangup could deliver, so
  // only an explicit group kill can end it.
  const bridge = await startBridge(context);
  const session = await startSession(context, bridge, {
    command: "/bin/sh",
    args: ["-c", "trap '' HUP TERM INT QUIT; while :; do sleep 5; done"],
    cwd: bridge.workDir,
  });
  const tracked = context.sessions[context.sessions.length - 1];
  assert.equal(await stillRunning(session.leaderPid, tracked.leaderCommand), true);

  // Only a pid this file caused to exist, and only after its recorded command
  // line still matches.
  assert.equal(await stillRunning(session.helperPid, tracked.helperCommand), true);
  process.kill(session.helperPid, "SIGKILL");

  const reported = await poll(async () => {
    const status = await bridge.ok("bridge_status");
    const entry = status.ptySessions.find((item) => item.id === session.sessionId);
    return entry && entry.exited ? entry : null;
  }, { attempts: 50, delayMs: 100, label: "the bridge to notice its helper died" });
  assert.equal(reported.exited, true, "a session whose helper is gone must not be reported as live");

  await poll(async () => !(await stillRunning(session.leaderPid, tracked.leaderCommand)), {
    attempts: 50,
    delayMs: 100,
    label: "the orphaned session leader to be reclaimed",
  });
  assert.equal(processGroupGone(session.leaderPid), true);

  // The slot must come back too, or a model that loses a helper loses capacity
  // until the idle sweeper runs.
  const replacement = await startSession(context, bridge, { command: "/bin/cat", cwd: bridge.workDir });
  await bridge.ok("pty_close", { session_id: replacement.sessionId, force: true });
});

await runCase("a session is recorded for the reclaimer and its keystrokes are never audited", async (context) => {
  const bridge = await startBridge(context, { env: { DARWINRELAY_AUDIT_MODE: "full" } });
  const session = await startSession(context, bridge, {
    command: "/bin/cat",
    cwd: bridge.workDir,
    label: "audit case",
  });

  const metadataPath = path.join(bridge.dataDir, "jobs", `${session.sessionId}.json`);
  const metadata = JSON.parse(await fsp.readFile(metadataPath, "utf8"));
  assert.equal(metadata.kind, "pty");
  assert.equal(metadata.pid, session.leaderPid);
  assert.equal(metadata.processGroupId, session.leaderPid, "disable.sh kills the GROUP; a leader pid recorded as something else is a missed reclaim");
  assert.equal(metadata.helperPid, session.helperPid);
  assert.equal(metadata.stdoutPath, null);
  assert.equal(metadata.label, "audit-case", "a label becomes part of a filename, so it is sanitised");
  // disable.sh parses startedAt with this exact format and SILENTLY SKIPS an entry
  // it cannot parse, then prints "Disabled" having signalled nothing.
  const parsed = await new Promise((resolve) => {
    const date = spawn("date", ["-j", "-u", "-f", "%Y-%m-%dT%H:%M:%S", metadata.startedAt.split(".")[0], "+%s"], { stdio: ["ignore", "pipe", "ignore"] });
    let out = "";
    date.stdout.on("data", (chunk) => { out += chunk.toString(); });
    date.once("close", (code) => resolve(code === 0 ? Number(out.trim()) : null));
  });
  assert.ok(parsed > 0, `startedAt '${metadata.startedAt}' must be parseable by disable.sh`);

  // shell_job_status reads the same directory; a pty entry has no log files and
  // must not throw an opaque error on that account.
  const jobStatus = await bridge.ok("shell_job_status", { job_id: session.sessionId });
  assert.equal(jobStatus.kind, "pty");

  const secret = "correct-horse-battery-staple-9f2c";
  await bridge.ok("pty_write", { session_id: session.sessionId, data: `${secret}\r` });
  await poll(async () => (await bridge.ok("pty_read", { session_id: session.sessionId, cursor: 0, wait_ms: 500 })).text.includes(secret), {
    label: "cat to echo the line back",
  });

  const audit = await bridge.ok("audit_tail", { max_bytes: 1_000_000 });
  assert.equal(
    audit.text.includes(secret),
    false,
    "AUDIT_MODE=full must not turn pty_write into a plaintext password store; a passphrase looks like any other word to the redactor",
  );
  assert.match(audit.text, /"tool":"pty_write"/, "the call must still be recorded");
  assert.match(audit.text, /\[REDACTED \d+ bytes sha256:[0-9a-f]{16}\]/, "the record keeps a correlatable shape without the secret");
  assert.equal(audit.text.includes('"tool":"pty_read"'), true);
  const readEntries = auditEntries(audit.text).filter((entry) => entry.tool === "pty_read");
  assert.ok(readEntries.length > 0, "pty_read must be audited");
  for (const entry of readEntries) {
    assert.equal(JSON.stringify(entry).includes(secret), false, "the transcript itself must never be audited: it contains everything typed at a no-echo prompt");
    assert.equal(typeof entry.summary.returnedBytes, "number", "byte counts and offsets only");
  }

  await bridge.ok("pty_close", { session_id: session.sessionId });
  await assert.rejects(fsp.stat(metadataPath), "a clean close must prune the tombstone the reclaimer would otherwise chase");
});

// --- D1/D2: the two terminal-sweep fixes that shipped with no test -----------
//
// Both were verified by hand against their original reproductions and then left
// unlocked, under a changelog line that claimed every fix had one. These close that.

await runCase("a naturally exited session sweeps a disowned background job", async (context) => {
  // D2. The sweep ran only from killPtySession, never from the close handler, so a
  // session that ended on its own left the job behind — and the stale job metadata
  // named the already-dead leader, so scripts/disable.sh skipped it too. `disown`
  // matters: it removes the job from the shell's table, so nothing but the terminal
  // scan can find it.
  const bridge = await startBridge(context);
  const session = await startSession(context, bridge, {
    command: "/bin/zsh",
    args: ["-f", "-i"],
    cwd: bridge.workDir,
  });
  await bridge.ok("pty_write", {
    session_id: session.sessionId,
    data: "/bin/sh -c 'while :; do sleep 5; done' & echo BG=$!; disown\r",
  });
  const backgroundPid = await poll(async () => {
    const read = await bridge.ok("pty_read", { session_id: session.sessionId, cursor: 0, wait_ms: 500 });
    const match = /BG=(\d+)/.exec(read.text);
    return match ? Number(match[1]) : null;
  }, { attempts: 40, delayMs: 100, label: "the disowned job to report its pid" });
  const backgroundCommand = await psCommand(backgroundPid);
  assert.match(backgroundCommand, /while :; do sleep 5; done/, "the test must be looking at the job it started");

  // No wait, and no extra read. The write above forces a terminal scan, so the job is
  // recorded before pty_write returns.
  //
  // An earlier version of this case slept 1.2 s first, because the scan was throttled to
  // 1 s and a write deferred its scan to "the next call". That made the test pass while
  // the reproduction in the fix's own comment still failed — a job backgrounded and
  // abandoned in one breath escaped at gaps of 0 ms and 300 ms. The sleep is removed
  // deliberately: this now exercises the zero-gap case, which is the one that mattered.

  // End the session the way a user would: no pty_close anywhere in this case.
  await bridge.ok("pty_write", { session_id: session.sessionId, data: "exit\r" });
  try {
    await poll(async () => (await stillRunning(backgroundPid, backgroundCommand)) ? null : true,
      { attempts: 60, delayMs: 100, label: "the disowned job to be reclaimed after a natural exit" });
  } finally {
    if (await stillRunning(backgroundPid, backgroundCommand)) {
      try { process.kill(backgroundPid, "SIGKILL"); } catch {}
    }
  }
  assert.equal(await stillRunning(backgroundPid, backgroundCommand), false,
    "a job holding the terminal must be reclaimed when the session exits on its own, with no pty_close");
});

await runCase("a killed bridge lets the helper sweep the terminal itself", async (context) => {
  // D1. teardown('parent_gone') did only kill_group, and interactive job control puts
  // every `cmd &` in its own pgid, so the job survived a SIGKILLed bridge reparented to
  // pid 1. This is the one path no in-process revocation can cover, so the helper has
  // to do it — and it must snapshot the terminal BEFORE the group kill, because Darwin
  // revoke()s the terminal when the session leader exits and `ps -t` then finds nothing.
  const bridge = await startBridge(context);
  const session = await startSession(context, bridge, {
    command: "/bin/zsh",
    args: ["-f", "-i"],
    cwd: bridge.workDir,
  });
  await bridge.ok("pty_write", {
    session_id: session.sessionId,
    data: "/bin/sh -c 'while :; do sleep 5; done' & echo BG=$!\r",
  });
  const backgroundPid = await poll(async () => {
    const read = await bridge.ok("pty_read", { session_id: session.sessionId, cursor: 0, wait_ms: 500 });
    const match = /BG=(\d+)/.exec(read.text);
    return match ? Number(match[1]) : null;
  }, { attempts: 40, delayMs: 100, label: "the background job to report its pid" });
  const backgroundCommand = await psCommand(backgroundPid);
  const helperPid = session.helperPid;

  // SIGKILL, not stop(): no exit handler, no revocation path, nothing but the helper
  // noticing its stdin closed.
  process.kill(bridge.child.pid, "SIGKILL");
  try {
    await poll(async () => (await stillRunning(backgroundPid, backgroundCommand)) ? null : true,
      // The helper's fail-closed path can legitimately spend up to ~6 s in two
      // bounded ps scans plus the leader's graceful-exit window. Eight seconds
      // was enough on a developer Mac but proved too tight on a loaded hosted
      // macOS runner, where the safety path was still progressing normally.
      { attempts: 200, delayMs: 100, label: "the helper to reclaim the job after the bridge was killed" });
  } finally {
    if (await stillRunning(backgroundPid, backgroundCommand)) {
      try { process.kill(backgroundPid, "SIGKILL"); } catch {}
    }
  }
  assert.equal(await stillRunning(backgroundPid, backgroundCommand), false,
    "the helper must sweep its own terminal when its bridge dies");
  assert.equal(await stillRunning(helperPid), false, "the helper must not outlive its own teardown");
});

// ---------------------------------------------------------------------------

console.log(results.join("\n"));
try {
  if (failures > 0) {
    console.log(`\n  ${failures} of ${cases} pty cases FAILED`);
    process.exitCode = 1;
  } else {
    console.log("pty test passed");
  }
} finally {
  // Only pids this file caused to exist, and only while the recorded command line
  // still matches: a recycled pid must never be signalled.
  for (const tracked of trackedProcesses) {
    if (await stillRunning(tracked.leaderPid, tracked.leaderCommand)) {
      try { process.kill(-tracked.leaderPid, "SIGKILL"); } catch {}
      try { process.kill(tracked.leaderPid, "SIGKILL"); } catch {}
    }
    if (await stillRunning(tracked.helperPid, tracked.helperCommand)) {
      try { process.kill(tracked.helperPid, "SIGKILL"); } catch {}
    }
  }
  await fsp.rm(temporaryRoot, { recursive: true, force: true });
}
