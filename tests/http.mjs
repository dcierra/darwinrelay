// Regression test for the HTTP front end: auth, cross-client id isolation,
// credential scrubbing, and malformed-body handling.
import assert from "node:assert/strict";
import path from "node:path";
import os from "node:os";
import fsp from "node:fs/promises";
import { execFile, spawn } from "node:child_process";
import { fileURLToPath } from "node:url";
import { promisify } from "node:util";

const ROOT = path.dirname(path.dirname(fileURLToPath(import.meta.url)));
const execFileAsync = promisify(execFile);
const TARGET = process.argv[2] || path.join(ROOT, "mcp-http.mjs");
const BRIDGE = path.join(ROOT, "bridge.mjs");

const TOKEN = "test-token-that-is-long-enough-32";
const PORT = Number(process.env.DARWINRELAY_TEST_PORT || 8901);
const BASE = `http://127.0.0.1:${PORT}`;

// Negative cases first: the token guards are the whole authorization boundary,
// so verify the server refuses to start before testing anything else.
async function verifyRefusesToStart(token, expected, extraEnv = {}) {
  const child = spawn(process.execPath, [TARGET], {
    stdio: ["ignore", "ignore", "pipe"],
    env: {
      ...process.env,
      DARWINRELAY_HTTP_TOKEN: token,
      DARWINRELAY_HTTP_PORT: String(PORT),
      ...extraEnv,
    },
  });
  let err = "";
  child.stderr.on("data", (d) => {
    err += d.toString();
  });
  const code = await new Promise((r) => child.once("exit", r));
  assert.equal(code, 78, `expected exit 78 for token ${JSON.stringify(token)}, got ${code}: ${err}`);
  assert.match(err, expected);
}
await verifyRefusesToStart("", /Refusing to start without auth/);
await verifyRefusesToStart("too-short", /at least 24 bytes/);
await verifyRefusesToStart("ü".repeat(30), /printable ASCII/);
await verifyRefusesToStart(TOKEN, /OAUTH_CLIENT_SECRET must be at most 4096 bytes/, {
  DARWINRELAY_OAUTH_CLIENT_SECRET: "x".repeat(4097),
});
console.log("  PASS  refuses to start without a usable bearer token or bounded OAuth client secret");

// The token-file path must honour the same exit-78 contract, not surface a raw
// ENOENT stack with exit 1.
const tokenDir = await fsp.realpath(await fsp.mkdtemp(path.join(os.tmpdir(), "darwinrelay-tok-")));
const emptyToken = path.join(tokenDir, "empty");
await fsp.writeFile(emptyToken, "   \n");
await verifyRefusesToStart("", /could not be read/, {
  DARWINRELAY_HTTP_TOKEN_FILE: path.join(tokenDir, "does-not-exist"),
});
await verifyRefusesToStart("", /is empty/, { DARWINRELAY_HTTP_TOKEN_FILE: emptyToken });
await fsp.rm(tokenDir, { recursive: true, force: true });
console.log("  PASS  token file failures exit 78 with a message naming the file");

const dataDir = await fsp.realpath(await fsp.mkdtemp(path.join(os.tmpdir(), "darwinrelay-http-")));
const logDir = path.join(dataDir, "logs");
const auditFile = path.join(logDir, "audit.jsonl");
await fsp.writeFile(path.join(dataDir, "FULL_ACCESS_ENABLED"), "I_UNDERSTAND_THIS_GRANTS_FULL_ACCESS\n");

const server = spawn(process.execPath, [TARGET], {
  stdio: ["ignore", "ignore", "pipe"],
  env: {
    ...process.env,
    DARWINRELAY_HTTP_TOKEN: TOKEN,
    DARWINRELAY_HTTP_PORT: String(PORT),
    DARWINRELAY_ENTRY: BRIDGE,
    DARWINRELAY_DATA_DIR: dataDir,
    DARWINRELAY_LOG_DIR: logDir,
    DARWINRELAY_UNLOCK_FILE: path.join(dataDir, "FULL_ACCESS_ENABLED"),
    DARWINRELAY_AUDIT_MODE: "metadata",
  },
});
let stderr = "";
let serverExit = null;
server.stderr.on("data", (d) => {
  stderr += d.toString();
});
server.once("exit", (code) => {
  serverExit = code;
});

async function waitForListen() {
  for (let i = 0; i < 100; i += 1) {
    // EADDRINUSE is an unhandled 'error' on server.listen, so the process dies.
    // Catching it here reports the real cause instead of "never listened".
    if (serverExit !== null) {
      throw new Error(`server exited ${serverExit} before listening. stderr:\n${stderr}`);
    }
    try {
      if ((await fetch(`${BASE}/healthz`)).ok) return;
    } catch {}
    await new Promise((r) => setTimeout(r, 50));
  }
  throw new Error(`server never listened. stderr:\n${stderr}`);
}

function rpc(body, token = TOKEN, extraHeaders = {}) {
  return fetch(`${BASE}/mcp`, {
    method: "POST",
    headers: {
      "content-type": "application/json",
      accept: "application/json, text/event-stream",
      ...(token ? { authorization: `Bearer ${token}` } : {}),
      ...extraHeaders,
    },
    body: typeof body === "string" ? body : JSON.stringify(body),
    // Without this, an id-collision regression manifests as a 600-second hang
    // rather than a failure, because the overwritten waiter never settles.
    signal: AbortSignal.timeout(15_000),
  });
}

const results = [];
const ok = (name) => {
  results.push(`  PASS  ${name}`);
};

try {
  await waitForListen();

  // --- auth -----------------------------------------------------------------
  assert.equal((await rpc({ jsonrpc: "2.0", id: 1, method: "ping" }, "")).status, 401);
  assert.equal((await rpc({ jsonrpc: "2.0", id: 1, method: "ping" }, "wrong-token-long-enough-here")).status, 401);
  ok("401 on missing and wrong bearer token");

  // --- handshake ------------------------------------------------------------
  const init = await (
    await rpc({
      jsonrpc: "2.0",
      id: 1,
      method: "initialize",
      params: { protocolVersion: "2025-06-18", capabilities: {}, clientInfo: { name: "t", version: "0" } },
    })
  ).json();
  assert.equal(init.id, 1);
  assert.ok(init.result?.serverInfo?.name);
  assert.equal((await rpc({ jsonrpc: "2.0", method: "notifications/initialized" })).status, 202);
  ok("initialize + initialized notification");

  // doctor.sh uses this helper for a real local initialize -> bridge_status smoke
  // without placing the bearer token in argv or the environment. Pin that path
  // against the same real HTTP front end used by the rest of this suite.
  const probeTokenFile = path.join(dataDir, "doctor-http-token");
  await fsp.writeFile(probeTokenFile, `${TOKEN}\n`, { mode: 0o600 });
  const probed = await execFileAsync(process.execPath, [
    path.join(ROOT, "scripts", "probe-bridge-status.mjs"),
    "--http-port", String(PORT),
    "--token-file", probeTokenFile,
  ], { timeout: 15_000, maxBuffer: 4_000_000 });
  assert.equal(probed.stderr, "");
  const probedStatus = JSON.parse(probed.stdout);
  assert.equal(probedStatus.bridgeVersion, JSON.parse(await fsp.readFile(path.join(ROOT, "package.json"), "utf8")).version);
  ok("doctor HTTP bridge_status probe uses a token file and reaches the real bridge");

  // --- DEFECT 1: concurrent identical client ids must not cross ------------
  // Two callers both use id:1. Each must get its own result back, with id:1.
  const rawSessionA = "chat-session-a-low-entropy";
  const rawSessionB = "chat-session-b-low-entropy";
  const [a, b] = await Promise.all([
    rpc({
      jsonrpc: "2.0",
      id: 1,
      method: "tools/call",
      params: { name: "shell_exec", arguments: { command: "sleep 0.4; printf CALLER_A_SECRET" } },
    }, TOKEN, { "mcp-session-id": rawSessionA }).then((r) => r.json()),
    rpc({
      jsonrpc: "2.0",
      id: 1,
      method: "tools/call",
      params: { name: "shell_exec", arguments: { command: "printf CALLER_B_ONLY" } },
    }, TOKEN, { "mcp-session-id": rawSessionB }).then((r) => r.json()),
  ]);
  const aText = JSON.stringify(a);
  const bText = JSON.stringify(b);
  assert.equal(a.id, 1, "caller A must get its own id back");
  assert.equal(b.id, 1, "caller B must get its own id back");
  assert.ok(aText.includes("CALLER_A_SECRET"), `A got wrong result: ${aText.slice(0, 300)}`);
  assert.ok(bText.includes("CALLER_B_ONLY"), `B got wrong result: ${bText.slice(0, 300)}`);
  assert.ok(!aText.includes("CALLER_B_ONLY"), "A leaked B's result");
  assert.ok(!bText.includes("CALLER_A_SECRET"), "B leaked A's result");
  ok("concurrent duplicate ids do not cross responses");

  // Correlation ids must remain correct under the exact same concurrency that
  // used to cross-wire duplicate client request ids. Raw MCP session ids and the
  // bearer credential must never be copied into audit.jsonl.
  const repeatA = await (
    await rpc({
      jsonrpc: "2.0",
      id: 7,
      method: "tools/call",
      params: { name: "shell_exec", arguments: { command: "printf CALLER_A_REPEAT" } },
    }, TOKEN, { "mcp-session-id": rawSessionA })
  ).json();
  assert.ok(JSON.stringify(repeatA).includes("CALLER_A_REPEAT"));

  const auditRaw = await fsp.readFile(auditFile, "utf8");
  const auditEntries = auditRaw
    .trim()
    .split("\n")
    .filter(Boolean)
    .map((line) => JSON.parse(line));
  const entryFor = (marker) => auditEntries.find((entry) => entry.tool === "shell_exec" && entry.argumentsPreview?.includes(marker));
  const auditA = entryFor("CALLER_A_SECRET");
  const auditB = entryFor("CALLER_B_ONLY");
  const auditARepeat = entryFor("CALLER_A_REPEAT");
  for (const entry of [auditA, auditB, auditARepeat]) {
    assert.ok(entry, "missing correlated shell_exec audit entry");
    assert.match(entry.correlationId, /^req_[A-Za-z0-9_-]{16,}$/);
    assert.match(entry.transportRequestId, /^http_[A-Za-z0-9_-]{16,}$/);
    assert.match(entry.sessionCorrelationId, /^sess_[A-Za-z0-9_-]{16,}$/);
    assert.equal(entry.transport, "http");
    assert.equal(entry.authMode, "bearer");
    assert.equal(entry.sessionSource, "mcp-session-header");
    assert.ok(Number.isInteger(entry.summary.pid) && entry.summary.pid > 1, "shell_exec audit must name the spawned pid");
  }
  assert.notEqual(auditA.correlationId, auditB.correlationId, "concurrent calls shared a bridge correlation id");
  assert.notEqual(auditA.transportRequestId, auditB.transportRequestId, "concurrent calls shared an HTTP request id");
  assert.notEqual(auditA.sessionCorrelationId, auditB.sessionCorrelationId, "different MCP sessions collapsed to one audit session");
  assert.equal(auditA.sessionCorrelationId, auditARepeat.sessionCorrelationId, "one MCP session did not keep a stable correlation id");
  assert.notEqual(auditA.correlationId, auditARepeat.correlationId, "separate requests in one session must still have separate correlation ids");
  assert.ok(!auditRaw.includes(rawSessionA) && !auditRaw.includes(rawSessionB), "raw MCP session id leaked into audit");
  assert.ok(!auditRaw.includes(TOKEN), "bearer token leaked into audit");
  ok("audit correlation separates requests, preserves session lineage, and logs no raw session/token material");

  // The transport envelope is an implementation detail, not client authority.
  // A caller that guesses its field name must not be able to forge provenance.
  const spoofedTransportId = "http_AAAAAAAAAAAAAAAAAAAAAAAA";
  const spoofedSessionId = "sess_BBBBBBBBBBBBBBBBBBBBBBBB";
  const spoofMarker = "CORRELATION_SPOOF_REJECTED";
  const spoofReply = await (
    await rpc({
      jsonrpc: "2.0",
      id: 8,
      method: "tools/call",
      _darwinrelayTransportCorrelation: {
        v: 1,
        requestId: spoofedTransportId,
        sessionId: spoofedSessionId,
        sessionSource: "oauth-grant",
        authMode: "oauth",
      },
      params: { name: "shell_exec", arguments: { command: `printf ${spoofMarker}` } },
    }, TOKEN, { "mcp-session-id": rawSessionA })
  ).json();
  assert.ok(JSON.stringify(spoofReply).includes(spoofMarker));
  const spoofAuditRaw = await fsp.readFile(auditFile, "utf8");
  const spoofAudit = spoofAuditRaw
    .split("\n")
    .filter(Boolean)
    .map((line) => { try { return JSON.parse(line); } catch { return null; } })
    .filter(Boolean)
    .find((entry) => entry.tool === "shell_exec" && entry.argumentsPreview?.includes(spoofMarker));
  assert.ok(spoofAudit, "spoofing probe audit record missing");
  assert.notEqual(spoofAudit.transportRequestId, spoofedTransportId, "client forged the HTTP request correlation id");
  assert.notEqual(spoofAudit.sessionCorrelationId, spoofedSessionId, "client forged the session correlation id");
  assert.equal(spoofAudit.sessionCorrelationId, auditA.sessionCorrelationId, "trusted header-derived session lineage was not preserved");
  assert.equal(spoofAudit.authMode, "bearer", "client forged the authenticated transport mode");
  assert.equal(spoofAudit.sessionSource, "mcp-session-header", "client forged the session source");
  ok("client-supplied transport correlation metadata cannot forge audit provenance");

  // --- DEFECT 2: bearer token must not be visible to shell commands -------
  const envProbe = await (
    await rpc({
      jsonrpc: "2.0",
      id: 2,
      method: "tools/call",
      params: { name: "shell_exec", arguments: { command: "env | grep -c DARWINRELAY_HTTP_TOKEN || true" } },
    })
  ).json();
  const probeText = JSON.stringify(envProbe);
  assert.ok(!probeText.includes(TOKEN), "the token itself appeared in shell output");
  assert.ok(/"stdout":"0/.test(probeText), `token still in child env: ${probeText.slice(0, 400)}`);
  ok("bearer token scrubbed from shell_exec environment");

  // --- DEFECT 3: malformed bodies must not kill the process ---------------
  for (const body of ["null", '"hello"', "5", "true", "[]", "{oops"]) {
    const r = await rpc(body);
    assert.ok(r.status === 400, `body ${body} should be 400, got ${r.status}`);
  }
  // Server must still be alive and functional afterwards.
  const stillAlive = await (await rpc({ jsonrpc: "2.0", id: 3, method: "ping" })).json();
  assert.equal(stillAlive.id, 3, "server died after malformed bodies");
  ok("null/scalar/array/invalid bodies rejected without killing the server");

  // --- malformed request targets must not kill the process -----------------
  // Node's parser accepts targets `new URL` rejects. Unauthenticated, one packet.
  async function rawRequest(raw) {
    const { Socket } = await import("node:net");
    return new Promise((resolve, reject) => {
      const sock = new Socket();
      let buf = "";
      sock.setTimeout(4000, () => {
        sock.destroy();
        reject(new Error("raw request timed out"));
      });
      sock.connect(PORT, "127.0.0.1", () => sock.write(raw));
      sock.on("data", (d) => {
        buf += d.toString();
        // Keep-alive means 'close' may never fire; the status line is enough.
        if (buf.includes("\r\n")) {
          sock.destroy();
          resolve(buf);
        }
      });
      sock.on("close", () => resolve(buf));
      sock.on("error", reject);
    });
  }
  for (const raw of [
    "GET //[/mcp HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n",
    "GET /mcp HTTP/1.1\r\nHost: [\r\n\r\n",
    "GET http://[/mcp HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n",
  ]) {
    const reply = await rawRequest(raw);
    assert.match(reply, /^HTTP\/1\.1 400 /, `expected 400 for ${JSON.stringify(raw.split("\r\n")[0])}, got: ${reply.slice(0, 80)}`);
  }
  const survived = await (await rpc({ jsonrpc: "2.0", id: 6, method: "ping" })).json();
  assert.equal(survived.id, 6, "server died after malformed request targets");
  ok("malformed request targets rejected without killing the server");

  // --- misc ---------------------------------------------------------------
  assert.equal((await fetch(`${BASE}/nope`)).status, 404);
  assert.equal((await fetch(`${BASE}/mcp`, { method: "GET", headers: { authorization: `Bearer ${TOKEN}` } })).status, 405);
  ok("404 off-path, 405 on GET /mcp");

  // --- handshake replay: kill the child, next call must still work ----------
  // Pins the notifications/initialized replay: without it bridge.mjs answers
  // -32002 "Server not initialized" on every call after a child restart.
  const pidBefore = await (
    await rpc({ jsonrpc: "2.0", id: 4, method: "tools/call", params: { name: "shell_exec", arguments: { command: "echo $PPID" } } })
  ).json();
  // Read the value structurally, and take the LAST line: `shell_exec` uses a
  // login shell, so profile banners can precede the pid on stdout. A regex
  // anchored to the start of stdout would capture the banner instead — a
  // digit-leading banner would make this SIGKILL an unrelated process.
  const stdout = pidBefore?.result?.structuredContent?.stdout;
  assert.equal(typeof stdout, "string", `no stdout in reply: ${JSON.stringify(pidBefore).slice(0, 300)}`);
  const lastLine = stdout.trim().split("\n").pop().trim();
  assert.match(lastLine, /^\d+$/, `expected a bare pid, got ${JSON.stringify(lastLine)}`);
  const bridgePid = Number(lastLine);

  // Refuse to signal anything that is not our own bridge child.
  const { execFileSync } = await import("node:child_process");
  const actualParent = execFileSync("ps", ["-o", "ppid=", "-p", String(bridgePid)], { encoding: "utf8" }).trim();
  assert.equal(
    actualParent,
    String(server.pid),
    `pid ${bridgePid} is not a child of the server under test (parent ${actualParent}, expected ${server.pid}); refusing to kill`,
  );
  process.kill(bridgePid, "SIGKILL");
  await new Promise((r) => setTimeout(r, 100));
  const unavailable = await rpc({ jsonrpc: "2.0", id: 41, method: "ping" });
  const unavailableText = await unavailable.text();
  assert.equal(unavailable.status, 503, `expected a transient 503 during bridge respawn backoff, got ${unavailable.status}`);
  assert.match(unavailableText, /bridge temporarily unavailable/);
  assert.doesNotMatch(
    unavailableText,
    /code=|signal=|FULL_ACCESS|bridge\.mjs|MacDeveloperBridge|DarwinRelay\/|Users\//,
    `internal bridge detail leaked to the HTTP client: ${unavailableText}`,
  );
  await new Promise((r) => setTimeout(r, 2300)); // clear RESPAWN_BACKOFF_MS
  const afterKill = await (
    await rpc({ jsonrpc: "2.0", id: 5, method: "tools/call", params: { name: "shell_exec", arguments: { command: "printf survived" } } })
  ).json();
  const afterText = JSON.stringify(afterKill);
  assert.ok(!afterText.includes("-32002"), `handshake was not replayed after respawn: ${afterText.slice(0, 300)}`);
  assert.ok(afterText.includes("survived"), `call after respawn failed: ${afterText.slice(0, 300)}`);
  ok("bridge respawn replays handshake; client needs no re-initialize");

  // SSE-only client must still get a usable body.
  const sse = await fetch(`${BASE}/mcp`, {
    method: "POST",
    headers: { "content-type": "application/json", accept: "text/event-stream", authorization: `Bearer ${TOKEN}` },
    body: JSON.stringify({ jsonrpc: "2.0", id: 9, method: "ping" }),
  });
  const sseBody = await sse.text();
  assert.ok(sse.headers.get("content-type")?.includes("text/event-stream"), "expected SSE content-type");
  assert.ok(sseBody.includes('"id":9'), `SSE frame missing payload: ${sseBody}`);
  ok("SSE-only Accept receives a single event frame");

  console.log(results.join("\n"));
  console.log("http test passed");
} catch (e) {
  console.log(results.join("\n"));
  console.log(`\n  FAIL  ${e.message}`);
  console.log(`--- server stderr ---\n${stderr}`);
  process.exitCode = 1;
} finally {
  server.kill("SIGTERM");
  await fsp.rm(dataDir, { recursive: true, force: true });
}
