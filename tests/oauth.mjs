// Regression test for the OAuth 2.1 authorization server inside mcp-http.mjs:
// discovery documents, the 401 challenge, authorization_code + PKCE S256,
// refresh rotation, revocation, on-disk state handling, and the static bearer
// path OAuth must not have broken.
//
// Every fetch carries an AbortSignal: a regression that hangs a handler instead
// of answering must fail this suite, not stall it for ten minutes.
import assert from "node:assert/strict";
import crypto from "node:crypto";
import path from "node:path";
import os from "node:os";
import fsp from "node:fs/promises";
import fs from "node:fs";
import { Socket } from "node:net";
import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";

const ROOT = path.dirname(path.dirname(fileURLToPath(import.meta.url)));
const TARGET = process.argv[2] || path.join(ROOT, "mcp-http.mjs");
const BRIDGE = path.join(ROOT, "bridge.mjs");

const TOKEN = "oauth-test-token-that-is-long-enough";
const ROTATED_TOKEN = "oauth-test-token-after-rotation-xyz";
const CLIENT_ID = "darwinrelay-oauth-test-client";
const CLIENT_SECRET = "oauth-test-client-secret-0123456789";
// Measured from ChatGPT's connector dialog. The allowlist is exact-match only, so
// these two literals are the whole accepted set unless an operator adds more.
const REDIRECT = "https://chatgpt.com/connector/oauth/7WkU7U_Y2vFg";
const REDIRECT_ALT = "https://chatgpt.com/connector_platform_oauth_redirect";
const EXTRA_REDIRECT = "https://client.example/cb";

const FETCH_TIMEOUT_MS = 15_000;
// 8901 belongs to tests/http.mjs. Every server gets its own port so a socket left
// in TIME_WAIT by an earlier phase cannot become an EADDRINUSE exit 74.
let nextPort = Number(process.env.DARWINRELAY_TEST_PORT || 8902);

const results = [];
const ok = (name) => {
  results.push(`  PASS  ${name}`);
};

const tempRoot = await fsp.realpath(await fsp.mkdtemp(path.join(os.tmpdir(), "darwinrelay-oauth-")));
const logDir = path.join(tempRoot, "logs");
const unlockFile = path.join(tempRoot, "FULL_ACCESS_ENABLED");
await fsp.mkdir(logDir, { recursive: true });
await fsp.writeFile(unlockFile, "I_UNDERSTAND_THIS_GRANTS_FULL_ACCESS\n");

// Each server gets its own DATA_DIR because oauth-state.json lives there and the
// restart phases deliberately corrupt it. realpath is mandatory: macOS resolves
// /var through a symlink, and an unresolved temp path made an earlier suite
// compare two different strings for the same directory.
function freshDataDir(tag) {
  return fsp.mkdtemp(path.join(tempRoot, `${tag}-`)).then(fsp.realpath);
}

const servers = [];

async function startServer({ dataDir, token = TOKEN, env = {}, label = "server" }) {
  const port = nextPort;
  nextPort += 1;
  const s = { label, port, base: `http://127.0.0.1:${port}`, stderr: "", exit: null, dataDir };
  s.child = spawn(process.execPath, [TARGET], {
    stdio: ["ignore", "ignore", "pipe"],
    env: {
      ...process.env,
      DARWINRELAY_HTTP_TOKEN: token,
      DARWINRELAY_HTTP_PORT: String(port),
      DARWINRELAY_ENTRY: BRIDGE,
      DARWINRELAY_DATA_DIR: dataDir,
      DARWINRELAY_LOG_DIR: logDir,
      DARWINRELAY_UNLOCK_FILE: unlockFile,
      DARWINRELAY_AUDIT_MODE: "off",
      DARWINRELAY_OAUTH_CLIENT_ID: CLIENT_ID,
      // Pinned empty so an operator's own shell environment cannot silently
      // change what this suite is testing.
      DARWINRELAY_OAUTH_CLIENT_SECRET: "",
      DARWINRELAY_OAUTH_REDIRECT_URIS: "",
      DARWINRELAY_PUBLIC_URL: "",
      ...env,
    },
  });
  servers.push(s);
  s.child.stderr.on("data", (d) => {
    s.stderr += d.toString();
  });
  s.exited = new Promise((resolve) => {
    s.child.once("exit", (code, signal) => {
      s.exit = code === null ? signal : code;
      resolve();
    });
  });

  for (let i = 0; i < 200; i += 1) {
    // Fail fast with the child's own diagnosis: an exit-78 config refusal or an
    // exit-74 EADDRINUSE must not be reported as "never listened".
    if (s.exit !== null) throw new Error(`${label} exited ${s.exit} before listening. stderr:\n${s.stderr}`);
    try {
      const r = await fetch(`${s.base}/healthz`, { signal: AbortSignal.timeout(2000) });
      await r.text();
      if (r.ok) return s;
    } catch {}
    await new Promise((r) => setTimeout(r, 50));
  }
  throw new Error(`${label} never listened on ${port}. stderr:\n${s.stderr}`);
}

// Only ever signals a ChildProcess handle this file spawned, so there is no pid
// whose parentage needs verifying. SIGTERM first: mcp-http.mjs's handler kills its
// own bridge child synchronously, so escalating cannot orphan a grandchild.
async function stop(s) {
  if (s.exit !== null) return;
  try {
    s.child.kill("SIGTERM");
  } catch {}
  const hard = setTimeout(() => {
    try {
      s.child.kill("SIGKILL");
    } catch {}
  }, 800);
  await s.exited;
  clearTimeout(hard);
}

// --- request helpers -------------------------------------------------------
// The body is always drained and returned alongside the status. Two reasons:
// an assertion message that interpolates `await res.text()` before a later
// `res.json()` throws "Body is unusable" instead of failing the test, and an
// undici response whose body is never read holds its socket open.
//
// redirect:"manual" is not optional. Without it the 302 out of POST /authorize
// would make this suite issue a real request to chatgpt.com.
async function req(s, pathname, opts = {}) {
  const res = await fetch(`${s.base}${pathname}`, {
    redirect: "manual",
    signal: AbortSignal.timeout(FETCH_TIMEOUT_MS),
    ...opts,
  });
  const text = await res.text();
  let json = null;
  try {
    json = JSON.parse(text);
  } catch {}
  return { status: res.status, headers: res.headers, text, json };
}

function query(o) {
  const sp = new URLSearchParams();
  for (const [k, v] of Object.entries(o)) if (v !== null && v !== undefined) sp.set(k, v);
  return sp.toString();
}

// A string body is sent verbatim with no content-type, which is one of the paths
// parseForm() has to survive; an object is form-encoded with null/undefined keys
// omitted rather than stringified to "null".
function form(s, pathname, fields, headers = {}) {
  if (typeof fields === "string") return req(s, pathname, { method: "POST", headers, body: fields });
  return req(s, pathname, {
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded", ...headers },
    body: query(fields),
  });
}

function rpc(s, body, token) {
  return req(s, "/mcp", {
    method: "POST",
    headers: {
      "content-type": "application/json",
      accept: "application/json, text/event-stream",
      ...(token ? { authorization: `Bearer ${token}` } : {}),
    },
    body: typeof body === "string" ? body : JSON.stringify(body),
  });
}

// Probes whether a token authorizes /mcp without spawning bridge.mjs: an
// authorized GET is 405 ("POST JSON-RPC"), an unauthorized one is 401. Keeps the
// restart phases free of child processes.
async function tokenStatus(s, token) {
  const r = await req(s, "/mcp", { method: "GET", headers: token ? { authorization: `Bearer ${token}` } : {} });
  assert.ok(r.status === 401 || r.status === 405, `unexpected ${r.status} probing token validity: ${r.text.slice(0, 200)}`);
  return r.status;
}

function rawRequest(port, raw, timeoutMs = 5000) {
  return new Promise((resolve, reject) => {
    const sock = new Socket();
    let buf = "";
    sock.setTimeout(timeoutMs, () => {
      sock.destroy();
      reject(new Error("raw request timed out"));
    });
    sock.connect(port, "127.0.0.1", () => sock.write(raw));
    sock.on("data", (d) => {
      buf += d.toString();
    });
    sock.on("close", () => resolve(buf));
    sock.on("error", reject);
  });
}

async function raw(port, text) {
  const reply = await rawRequest(port, text);
  const split = reply.indexOf("\r\n\r\n");
  const head = split === -1 ? reply : reply.slice(0, split);
  const body = split === -1 ? "" : reply.slice(split + 4);
  const lines = head.split("\r\n");
  const headers = new Map();
  for (const line of lines.slice(1)) {
    const i = line.indexOf(":");
    if (i > 0) headers.set(line.slice(0, i).toLowerCase(), line.slice(i + 1).trim());
  }
  let json = null;
  try {
    json = JSON.parse(body);
  } catch {}
  return { status: Number(lines[0].split(" ")[1]), statusLine: lines[0], headers, body, json };
}

// --- OAuth flow helpers ----------------------------------------------------
function pkce() {
  // 43 base64url characters, inside RFC 7636's 43-128 unreserved range.
  const verifier = crypto.randomBytes(32).toString("base64url");
  const challenge = crypto.createHash("sha256").update(verifier, "ascii").digest("base64url");
  return { verifier, challenge };
}

function ridOf(html) {
  const m = /name="rid" value="([0-9a-f]{32})"/.exec(html);
  assert.ok(m, `no rid in consent page: ${html.slice(0, 400)}`);
  return m[1];
}

async function consent(s, overrides = {}) {
  const { verifier, challenge } = pkce();
  const state = overrides.state === undefined ? `st-${crypto.randomBytes(6).toString("hex")}` : overrides.state;
  const params = {
    response_type: "code",
    client_id: CLIENT_ID,
    redirect_uri: REDIRECT,
    code_challenge: challenge,
    code_challenge_method: "S256",
    ...overrides,
    state,
  };
  const res = await req(s, `/authorize?${query(params)}`);
  return { res, verifier, challenge, state, params };
}

// GET /authorize -> approve with the static bearer -> authorization code.
async function getCode(s, overrides = {}, approveToken = TOKEN) {
  const { res, verifier, state, params } = await consent(s, overrides);
  assert.equal(res.status, 200, `consent page not 200: ${res.status} ${res.text.slice(0, 300)}`);
  const rid = ridOf(res.text);
  const approved = await form(s, "/authorize", { rid, bearer: approveToken });
  assert.equal(approved.status, 302, `approval not 302: ${approved.status} ${approved.text.slice(0, 300)}`);
  const loc = new URL(approved.headers.get("location"));
  assert.equal(loc.origin + loc.pathname, params.redirect_uri, "code went to an unexpected callback");
  const code = loc.searchParams.get("code");
  assert.match(code || "", /^[A-Za-z0-9_-]{43}$/, `malformed code: ${code}`);
  return { code, verifier, state, loc, redirectUri: params.redirect_uri };
}

function exchange(s, fields, headers = {}) {
  return form(s, "/token", { grant_type: "authorization_code", client_id: CLIENT_ID, ...fields }, headers);
}

async function tokens(s, overrides = {}, approveToken = TOKEN) {
  const got = await getCode(s, overrides, approveToken);
  const res = await exchange(s, { code: got.code, code_verifier: got.verifier, redirect_uri: got.redirectUri });
  assert.equal(res.status, 200, `token exchange failed: ${res.status} ${res.text.slice(0, 300)}`);
  return { ...res.json, code: got.code, verifier: got.verifier };
}

function refresh(s, refresh_token, extra = {}) {
  return form(s, "/token", { grant_type: "refresh_token", client_id: CLIENT_ID, refresh_token, ...extra });
}

async function initBridge(s, token) {
  const init = await rpc(
    s,
    {
      jsonrpc: "2.0",
      id: 1,
      method: "initialize",
      params: { protocolVersion: "2025-06-18", capabilities: {}, clientInfo: { name: "oauth-test", version: "0" } },
    },
    token,
  );
  assert.ok(init.json?.result?.serverInfo?.name, `initialize failed: ${init.text.slice(0, 300)}`);
  assert.equal((await rpc(s, { jsonrpc: "2.0", method: "notifications/initialized" }, token)).status, 202);
}

const stateFile = (s) => path.join(s.dataDir, "oauth-state.json");
const readState = (s) => JSON.parse(fs.readFileSync(stateFile(s), "utf8"));
const writeState = (s, obj) => fs.writeFileSync(stateFile(s), JSON.stringify(obj));
const digestOf = (token) => crypto.createHash("sha256").update(token, "latin1").digest("hex");
const tokenRecord = (s, kind, token) => readState(s)[kind].find((record) => record.d === digestOf(token));

let main;
try {
  main = await startServer({ dataDir: await freshDataDir("main"), label: "main", env: { DARWINRELAY_AUDIT_MODE: "metadata" } });
  const ORIGIN = main.base; // fetch sends Host: 127.0.0.1:<port>, so this is the derived origin
  const PRM = `${ORIGIN}/.well-known/oauth-protected-resource/mcp`;

  // The operator has no other way to learn the client_id, so this log line is
  // part of the contract.
  assert.match(main.stderr, new RegExp(`oauth client_id=${CLIENT_ID}\\b`), `client_id not logged: ${main.stderr}`);
  ok("startup logs the client_id an operator must paste into ChatGPT");

  // =========================================================================
  // NEGATIVE CASES FIRST
  // =========================================================================

  // --- /mcp still refuses everything it refused before ----------------------
  assert.equal((await rpc(main, { jsonrpc: "2.0", id: 1, method: "ping" })).status, 401);
  assert.equal((await rpc(main, { jsonrpc: "2.0", id: 1, method: "ping" }, "wrong-token-long-enough-here")).status, 401);
  // An OAuth-shaped token that was never issued must not authorize.
  assert.equal(await tokenStatus(main, crypto.randomBytes(32).toString("base64url")), 401);
  ok("401 on missing, wrong, and never-issued bearer tokens");

  // --- the 401 challenge must point at the metadata -------------------------
  const anon = await rpc(main, { jsonrpc: "2.0", id: 1, method: "ping" });
  const anonChallenge = anon.headers.get("www-authenticate") || "";
  assert.equal(anon.status, 401);
  assert.ok(anonChallenge.includes(`resource_metadata="${PRM}"`), `challenge lacks resource_metadata: ${anonChallenge}`);
  assert.ok(anonChallenge.includes('scope="mcp"'), `challenge lacks scope: ${anonChallenge}`);
  assert.ok(!/[\r\n]/.test(anonChallenge), "challenge header contains CR or LF");
  // RFC 6750 s3: no error code when the request carried no credential at all,
  // which is exactly the discovery probe.
  assert.ok(!anonChallenge.includes("error="), `unauthenticated probe should get no error code: ${anonChallenge}`);
  const presented = await rpc(main, { jsonrpc: "2.0", id: 1, method: "ping" }, "nope-nope-nope-nope-nope-nope");
  assert.ok(
    presented.headers.get("www-authenticate").includes('error="invalid_token"'),
    `a presented-but-bad token needs error=invalid_token: ${presented.headers.get("www-authenticate")}`,
  );
  ok("401 challenge carries resource_metadata, scope, and error only when a token was presented");

  // --- CORS must never leak off the discovery documents ---------------------
  for (const [pathname, opts] of [
    ["/mcp", { method: "POST", headers: { "content-type": "application/json" }, body: "{}" }],
    // A preflight that succeeded here would be the whole exploit.
    ["/mcp", { method: "OPTIONS" }],
    ["/token", { method: "POST" }],
    ["/token", { method: "OPTIONS" }],
    ["/authorize", {}],
    ["/authorize", { method: "OPTIONS" }],
    ["/revoke", { method: "POST" }],
    ["/revoke-all", { method: "POST" }],
  ]) {
    const r = await req(main, pathname, opts);
    assert.equal(
      r.headers.get("access-control-allow-origin"),
      null,
      `${pathname} must not be CORS-readable: a browser page could then drive shell execution`,
    );
  }
  ok("no access-control-allow-origin on /mcp, /token, /authorize or /revoke*");

  // --- redirect_uri: exact match or nothing --------------------------------
  const badRedirects = [
    // NOT rejected any more, and deliberately so: ChatGPT mints a new callback path
    // per connector, so `<base>X` is indistinguishable from a legitimate second
    // connector. Rejecting it broke every connector after the first. The compensating
    // controls are that the path SHAPE is still enforced (see the cases below), the
    // consent page displays the exact callback it will redirect to, and approval
    // requires the bridge token. Moved to the accepted set below.
    [`${REDIRECT}.evil.example`, "suffix extension onto another host label"],
    [`${REDIRECT}/`, "trailing slash"],
    [`${REDIRECT}?x=1`, "appended query"],
    [`${REDIRECT}#f`, "appended fragment"],
    [`${REDIRECT}/../..`, "dot-segment climb"],
    [`${REDIRECT} `, "trailing space"],
    ["https://chatgpt.com/connector/oauth/", "prefix truncation"],
    ["https://chatgpt.com/connector/oauth", "parent path"],
    ["https://Chatgpt.com/connector/oauth/7WkU7U_Y2vFg", "host case change"],
    ["http://chatgpt.com/connector/oauth/7WkU7U_Y2vFg", "scheme downgrade"],
    ["https://chatgpt.com:443/connector/oauth/7WkU7U_Y2vFg", "explicit default port"],
    ["https://chatgpt.com.evil.example/connector/oauth/7WkU7U_Y2vFg", "suffix-confusable host"],
    ["https://evil.example/connector/oauth/7WkU7U_Y2vFg", "wrong host"],
    [`https://evil.example/?u=${encodeURIComponent(REDIRECT)}`, "allowlisted value smuggled into a query"],
    [EXTRA_REDIRECT, "not configured on this server"],
    ["[", "value that would throw inside new URL"],
    ["", "empty"],
    [null, "absent"],
  ];
  for (const [uri, why] of badRedirects) {
    const { res } = await consent(main, { redirect_uri: uri });
    assert.equal(res.status, 400, `redirect_uri (${why}) should be 400, got ${res.status}`);
    assert.equal(res.headers.get("location"), null, `redirect_uri (${why}) produced an open redirect`);
    assert.ok(res.headers.get("content-type")?.includes("text/html"), `expected an HTML error page for ${why}`);
    if (uri) assert.ok(!res.text.includes(uri), `error page reflected the rejected redirect_uri (${why})`);
  }
  ok(`${badRedirects.length} rejected redirect_uri forms answer 400 with no Location`);

  // Pin the per-connector behaviour: any token under /connector/oauth/ is a valid
  // ChatGPT callback, because that is how ChatGPT allocates them — a new path per
  // connector. Asserting only the rejections would leave this un-pinned, and it is the
  // property that broke every connector after the first.
  for (const [uri, label] of [
    ["https://chatgpt.com/connector/oauth/7WkU7U_Y2vFg", "first observed connector"],
    ["https://chatgpt.com/connector/oauth/9Jf_WtxFPY80", "second observed connector"],
    [`${REDIRECT}X`, "suffix extension — indistinguishable from a new connector"],
  ]) {
    const { res } = await consent(main, { redirect_uri: uri });
    assert.equal(res.status, 200, `${label} should reach the consent page, got ${res.status}`);
    assert.ok(res.text.includes(uri), `${label}: consent page must show the callback it will redirect to`);
  }
  ok("per-connector ChatGPT callbacks are accepted and shown on the consent page");

  // --- client_id is compared exactly, before any redirect ------------------
  for (const cid of [null, "", "wrong-client", `${CLIENT_ID}x`, CLIENT_ID.toUpperCase()]) {
    const { res } = await consent(main, { client_id: cid });
    assert.equal(res.status, 400, `client_id ${JSON.stringify(cid)} should be 400, got ${res.status}`);
    assert.equal(res.headers.get("location"), null, `client_id ${JSON.stringify(cid)} produced a redirect`);
  }
  ok("unknown client_id is a 400 page, never a redirect");

  // --- invalid requests from a known client redirect the error --------------
  const redirectedFailures = [
    [{ response_type: "token" }, "unsupported_response_type"],
    [{ response_type: null }, "unsupported_response_type"],
    [{ code_challenge_method: "plain" }, "invalid_request"],
    [{ code_challenge_method: null }, "invalid_request"],
    [{ code_challenge: null }, "invalid_request"],
    [{ code_challenge: "a".repeat(42) }, "invalid_request"],
    [{ code_challenge: "a".repeat(129) }, "invalid_request"],
    [{ code_challenge: `${"a".repeat(40)}+/=` }, "invalid_request"],
    [{ resource: "https://evil.example" }, "invalid_target"],
    [{ resource: "not a url" }, "invalid_target"],
    [{ resource: `${ORIGIN}/mcp#frag` }, "invalid_target"],
  ];
  for (const [overrides, expected] of redirectedFailures) {
    const { res, state } = await consent(main, { ...overrides, state: "keep-me" });
    assert.equal(res.status, 302, `${JSON.stringify(overrides)} should redirect the error, got ${res.status}`);
    const loc = res.headers.get("location");
    assert.ok(loc.startsWith(`${REDIRECT}?`), `an error redirect must use the allowlisted literal: ${loc}`);
    const u = new URL(loc);
    assert.equal(u.searchParams.get("error"), expected, `wrong error for ${JSON.stringify(overrides)}: ${loc}`);
    assert.equal(u.searchParams.get("state"), state, "state must survive an error redirect");
    assert.equal(u.searchParams.get("iss"), ORIGIN, "RFC 9207 iss missing from the error redirect");
  }
  ok(`${redirectedFailures.length} invalid authorization requests redirect an OAuth error with state and iss`);

  // --- method guards -------------------------------------------------------
  for (const [pathname, method] of [
    ["/authorize", "PUT"],
    ["/authorize", "DELETE"],
    ["/token", "GET"],
    ["/revoke", "GET"],
    ["/revoke-all", "GET"],
    ["/.well-known/oauth-authorization-server", "POST"],
  ]) {
    assert.equal((await req(main, pathname, { method })).status, 405, `${method} ${pathname} should be 405`);
  }
  ok("405 on every wrong method across the new routes");

  // --- /token refuses everything it should, before any code exists ---------
  const tokenFailures = [
    [{}, 401, "invalid_client"],
    [{ client_id: "wrong" }, 401, "invalid_client"],
    [{ client_id: `${CLIENT_ID}x` }, 401, "invalid_client"],
    [{ client_id: CLIENT_ID }, 400, "unsupported_grant_type"],
    [{ client_id: CLIENT_ID, grant_type: "password" }, 400, "unsupported_grant_type"],
    [{ client_id: CLIENT_ID, grant_type: "client_credentials" }, 400, "unsupported_grant_type"],
    [{ client_id: CLIENT_ID, grant_type: "authorization_code" }, 400, "invalid_request"],
    [{ client_id: CLIENT_ID, grant_type: "authorization_code", code: "" }, 400, "invalid_request"],
    [{ client_id: CLIENT_ID, grant_type: "authorization_code", code: "nope", code_verifier: "v".repeat(43) }, 400, "invalid_grant"],
    [{ client_id: CLIENT_ID, grant_type: "refresh_token" }, 400, "invalid_request"],
    [{ client_id: CLIENT_ID, grant_type: "refresh_token", refresh_token: "nope" }, 400, "invalid_grant"],
  ];
  for (const [fields, status, error] of tokenFailures) {
    const r = await form(main, "/token", fields);
    assert.equal(r.status, status, `${JSON.stringify(fields)} -> ${r.status} ${r.text.slice(0, 200)}`);
    assert.equal(r.json?.error, error, `${JSON.stringify(fields)} -> ${r.text.slice(0, 200)}, expected ${error}`);
    assert.equal(r.headers.get("cache-control"), "no-store", "token errors must not be cacheable");
  }
  ok(`${tokenFailures.length} /token refusals return the right OAuth error code`);

  // --- an unknown token is not an existence oracle -------------------------
  const revokeUnknown = await form(main, "/revoke", { token: crypto.randomBytes(32).toString("base64url") });
  assert.equal(revokeUnknown.status, 200);
  assert.deepEqual(revokeUnknown.json, { ok: true });
  ok("/revoke answers 200 for an unknown token (RFC 7009, no existence oracle)");

  // --- /revoke-all is static-bearer only -----------------------------------
  const revokeAllAnon = await req(main, "/revoke-all", { method: "POST" });
  assert.equal(revokeAllAnon.status, 401);
  assert.ok(revokeAllAnon.headers.get("www-authenticate")?.startsWith("Bearer "), "401 must still challenge");
  ok("/revoke-all rejects an unauthenticated caller");

  // =========================================================================
  // DISCOVERY DOCUMENTS
  // =========================================================================
  const prmRoot = await req(main, "/.well-known/oauth-protected-resource");
  assert.equal(prmRoot.status, 200);
  assert.ok(prmRoot.headers.get("content-type")?.includes("application/json"), "PRM must be JSON");
  assert.equal(prmRoot.headers.get("cache-control"), "no-store");
  assert.equal(prmRoot.headers.get("access-control-allow-origin"), "*");
  assert.equal(prmRoot.json.resource, ORIGIN, "the root PRM must claim the origin it was fetched from");
  assert.deepEqual(prmRoot.json.authorization_servers, [ORIGIN]);
  assert.deepEqual(prmRoot.json.scopes_supported, ["mcp"]);
  assert.deepEqual(prmRoot.json.bearer_methods_supported, ["header"]);

  const prmMcp = await req(main, "/.well-known/oauth-protected-resource/mcp");
  assert.equal(prmMcp.status, 200);
  assert.equal(prmMcp.json.resource, `${ORIGIN}/mcp`, "the /mcp PRM must claim ORIGIN/mcp or a strict client silently drops it");
  assert.deepEqual(prmMcp.json.authorization_servers, [ORIGIN]);
  ok("both protected-resource documents are 200 JSON whose resource matches their own URL");

  // Every alias serves the SAME issuer, the root origin. An alias claiming
  // ORIGIN/mcp contradicted the iss this server returns in the authorization
  // response, and RFC 9207 s2.4 makes that mismatch a MUST-reject: the client
  // completed consent, took the code and silently dropped it. The cross-check
  // against the live iss is in the full-flow section below.
  const AS_PATHS = [
    "/.well-known/oauth-authorization-server",
    "/.well-known/oauth-authorization-server/mcp",
    "/.well-known/openid-configuration",
    "/.well-known/openid-configuration/mcp",
    "/mcp/.well-known/openid-configuration",
  ];
  for (const pathname of AS_PATHS) {
    const r = await req(main, pathname);
    assert.equal(r.status, 200, `${pathname} -> ${r.status}`);
    assert.ok(r.headers.get("content-type")?.includes("application/json"), `${pathname} must be JSON`);
    const d = r.json;
    assert.equal(d.issuer, ORIGIN, `${pathname} issuer must be the single root issuer`);
    assert.equal(d.authorization_endpoint, `${ORIGIN}/authorize`, `${pathname} authorization_endpoint`);
    assert.equal(d.token_endpoint, `${ORIGIN}/token`, `${pathname} token_endpoint`);
    assert.equal(d.revocation_endpoint, `${ORIGIN}/revoke`, `${pathname} revocation_endpoint`);
    assert.deepEqual(d.response_types_supported, ["code"], `${pathname} response_types_supported`);
    assert.deepEqual(d.response_modes_supported, ["query"], `${pathname} response_modes_supported`);
    assert.deepEqual(d.code_challenge_methods_supported, ["S256"], `${pathname} must advertise S256 or MCP clients abort`);
    assert.deepEqual(d.scopes_supported, ["mcp"], `${pathname} scopes_supported`);
    assert.ok(d.grant_types_supported.includes("authorization_code"), `${pathname} grant_types_supported`);
    assert.ok(d.grant_types_supported.includes("refresh_token"), `${pathname} grant_types_supported`);
    assert.ok(!d.grant_types_supported.includes("implicit"), "the implicit grant is forbidden by OAuth 2.1");
    assert.ok(d.token_endpoint_auth_methods_supported.includes("none"), `${pathname} must allow a public client`);
    assert.equal(d.authorization_response_iss_parameter_supported, true, `${pathname} iss support`);
    // Advertising either of these routes ChatGPT into DCR or CIMD, neither of
    // which this server implements; its dialog reported both as unavailable.
    assert.equal(d.registration_endpoint, undefined, `${pathname} must not advertise dynamic client registration`);
    assert.equal(d.client_id_metadata_document_supported, undefined, `${pathname} must not advertise CIMD`);
    assert.ok(!r.text.includes(TOKEN) && !r.text.includes(CLIENT_SECRET), "a discovery document leaked a credential");
  }
  ok("all five authorization-server documents share one issuer and advertise no registration/CIMD hints");

  const optionsPrm = await req(main, "/.well-known/oauth-protected-resource", { method: "OPTIONS" });
  assert.equal(optionsPrm.status, 204);
  assert.equal(optionsPrm.headers.get("access-control-allow-origin"), "*");
  const headPrm = await req(main, "/.well-known/oauth-protected-resource", { method: "HEAD" });
  assert.equal(headPrm.status, 200);
  assert.equal(headPrm.text, "");
  // Exact-equality routing: a startsWith match here would also swallow GET /nope.
  assert.equal((await req(main, "/.well-known/oauth-protected-resource/")).status, 404);
  assert.equal((await req(main, "/.well-known/oauth-protected-resourceX")).status, 404);
  assert.equal((await req(main, "/nope")).status, 404);
  assert.equal((await req(main, "/.well-known/oauth-protected-resource?probe=1")).status, 200);
  ok("discovery honours OPTIONS/HEAD, ignores a query string, and routes by exact path");

  // =========================================================================
  // STATIC BEARER REGRESSION GUARD
  // =========================================================================
  await initBridge(main, TOKEN);
  const bearerTools = await rpc(main, { jsonrpc: "2.0", id: 2, method: "tools/list" }, TOKEN);
  assert.ok(bearerTools.json?.result?.tools?.length > 0, `static bearer lost tools/list: ${bearerTools.text.slice(0, 300)}`);
  ok("static bearer token still initializes and lists tools");

  // =========================================================================
  // FULL authorization_code + PKCE S256 FLOW
  // =========================================================================
  // A state shaped like an XSS payload proves the consent page reflects nothing:
  // state, redirect_uri and code_challenge stay server-side in authReqs.
  const xssState = '"><script>alert(1)</script>';
  const flow = await consent(main, { state: xssState });
  assert.equal(flow.res.status, 200);
  assert.ok(flow.res.headers.get("content-type")?.includes("text/html"));
  assert.match(flow.res.headers.get("content-security-policy") || "", /default-src 'none'/);
  assert.equal(flow.res.headers.get("x-frame-options"), "DENY");
  const consentHtml = flow.res.text;
  assert.ok(!consentHtml.includes("<script"), "the consent page must contain no script at all");
  assert.ok(!consentHtml.includes(xssState), "the consent page reflected the state parameter");
  assert.ok(!consentHtml.includes(flow.challenge), "the consent page reflected the code_challenge");
  assert.ok(!consentHtml.includes(TOKEN), "the consent page leaked the bridge token");
  const redirectRow = /<dt>Will redirect to<\/dt><dd><code>([^<]*)<\/code><\/dd>/.exec(consentHtml);
  assert.ok(redirectRow, "the consent page is missing its redirect destination row");
  assert.equal(redirectRow[1], REDIRECT, "the consent page must show the exact validated redirect destination");
  assert.ok(consentHtml.includes(CLIENT_ID), "the consent page must show the client_id");
  assert.match(consentHtml, /unrestricted shell access/, "the consent page must state what approval grants");
  ok("consent page is script-free, reflects no attacker-controlled parameter, and names the risk");

  const approved = await form(main, "/authorize", { rid: ridOf(consentHtml), bearer: TOKEN });
  assert.equal(approved.status, 302);
  const cb = new URL(approved.headers.get("location"));
  assert.equal(cb.origin + cb.pathname, REDIRECT);
  assert.equal(cb.searchParams.get("state"), xssState, "state must round-trip verbatim");
  assert.equal(cb.searchParams.get("iss"), ORIGIN);
  // The invariant, checked against the live value rather than against a repeated
  // literal: a client validates iss by exact string comparison with the issuer of
  // whichever metadata document it resolved, so a single disagreeing alias makes
  // that client discard an already-approved code with nothing reaching /token.
  for (const pathname of AS_PATHS) {
    assert.equal(
      (await req(main, pathname)).json.issuer,
      cb.searchParams.get("iss"),
      `${pathname} advertises an issuer the authorization response does not return`,
    );
  }
  const flowCode = cb.searchParams.get("code");

  const issued = await exchange(main, { code: flowCode, code_verifier: flow.verifier, redirect_uri: REDIRECT });
  assert.equal(issued.status, 200, `token exchange failed: ${issued.text.slice(0, 300)}`);
  assert.equal(issued.headers.get("cache-control"), "no-store");
  assert.ok(issued.headers.get("content-type")?.includes("application/json"), "the token response must be JSON");
  const grant = issued.json;
  assert.equal(grant.token_type, "Bearer", "ChatGPT requires this exact token_type");
  assert.equal(grant.expires_in, 3600);
  assert.equal(grant.scope, "mcp");
  assert.match(grant.access_token, /^[A-Za-z0-9_-]{43}$/);
  // Omitting refresh_token lets the ChatGPT connect succeed and then hides every
  // tool, before any expiry.
  assert.match(grant.refresh_token, /^[A-Za-z0-9_-]{43}$/);
  assert.notEqual(grant.access_token, grant.refresh_token);
  assert.notEqual(grant.access_token, TOKEN);
  const grantAccessRecord = tokenRecord(main, "access", grant.access_token);
  const grantRefreshRecord = tokenRecord(main, "refresh", grant.refresh_token);
  assert.match(grantAccessRecord?.sid || "", /^sess_[A-Za-z0-9_-]{16,}$/);
  assert.equal(grantAccessRecord.sid, grantRefreshRecord?.sid, "one OAuth grant must share one opaque session correlation id");
  assert.ok(!JSON.stringify(readState(main)).includes(grant.access_token), "OAuth state persisted plaintext access token while adding correlation metadata");

  const oauthTools = await rpc(main, { jsonrpc: "2.0", id: 3, method: "tools/list" }, grant.access_token);
  assert.ok(oauthTools.json?.result?.tools?.length > 0, `OAuth token could not list tools: ${oauthTools.text.slice(0, 300)}`);

  // No Mcp-Session-Id here: the audit lineage must come from the separately
  // generated OAuth grant sid, never from the access token itself.
  const oauthProbeMarker = `OAUTH_CORRELATION_${crypto.randomBytes(6).toString("hex")}`;
  const oauthProbe = await rpc(main, {
    jsonrpc: "2.0",
    id: 31,
    method: "tools/call",
    params: { name: "shell_exec", arguments: { command: `printf ${oauthProbeMarker}` } },
  }, grant.access_token);
  assert.equal(oauthProbe.status, 200, `OAuth correlation probe failed: ${oauthProbe.text.slice(0, 300)}`);
  const auditPath = path.join(logDir, "audit.jsonl");
  const oauthAuditRaw = await fsp.readFile(auditPath, "utf8");
  const oauthAuditEntry = oauthAuditRaw
    .split("\n")
    .filter(Boolean)
    .map((line) => { try { return JSON.parse(line); } catch { return null; } })
    .filter(Boolean)
    .find((entry) => entry.tool === "shell_exec" && entry.argumentsPreview?.includes(oauthProbeMarker));
  assert.ok(oauthAuditEntry, "OAuth shell_exec audit record missing");
  assert.equal(oauthAuditEntry.authMode, "oauth");
  assert.equal(oauthAuditEntry.sessionSource, "oauth-grant");
  assert.equal(oauthAuditEntry.sessionCorrelationId, grantAccessRecord.sid);
  assert.match(oauthAuditEntry.transportRequestId || "", /^http_[A-Za-z0-9_-]{16,}$/);
  assert.match(oauthAuditEntry.correlationId || "", /^req_[A-Za-z0-9_-]{16,}$/);
  assert.ok(!oauthAuditRaw.includes(grant.access_token), "OAuth access token leaked into audit while correlating a grant");
  assert.ok(!oauthAuditRaw.includes(grant.refresh_token), "OAuth refresh token leaked into audit while correlating a grant");
  ok("authorization_code + PKCE S256 ends in authenticated tools with opaque OAuth-grant audit lineage");

  // A refresh token must not be usable as an access token.
  assert.equal(await tokenStatus(main, grant.refresh_token), 401);
  ok("a refresh token does not authorize /mcp");

  // An omitted state must not come back as the string "null" or "undefined".
  const noState = await getCode(main, { state: null });
  assert.equal(noState.loc.searchParams.has("state"), false, "state was invented for a request that sent none");
  assert.equal(noState.loc.searchParams.get("iss"), ORIGIN);
  ok("a request without state gets a callback without state");

  // --- the resource parameter is accepted in every documented shape --------
  const seenAccessTokens = new Set([grant.access_token]);
  for (const resource of [undefined, ORIGIN, `${ORIGIN}/mcp`, `${ORIGIN}/mcp/`, ORIGIN.toUpperCase()]) {
    const overrides = resource === undefined ? {} : { resource };
    const got = await getCode(main, overrides);
    const r = await exchange(main, {
      code: got.code,
      code_verifier: got.verifier,
      redirect_uri: got.redirectUri,
      ...overrides,
    });
    assert.equal(r.status, 200, `resource ${String(resource)} rejected: ${r.text.slice(0, 300)}`);
    assert.ok(!seenAccessTokens.has(r.json.access_token), "two grants produced the same access token");
    seenAccessTokens.add(r.json.access_token);
  }
  ok("resource is accepted absent, as the origin, and as origin/mcp");

  // =========================================================================
  // NEGATIVES THAT NEED A REAL CODE FIRST
  // =========================================================================
  const replay = await exchange(main, { code: flowCode, code_verifier: flow.verifier, redirect_uri: REDIRECT });
  assert.equal(replay.status, 400);
  assert.equal(replay.json.error, "invalid_grant");
  ok("an authorization code cannot be redeemed twice");

  // The code is popped before validation specifically so a parallel replay cannot
  // win. Two in-flight redemptions of one code must yield exactly one grant.
  const racer = await getCode(main);
  const raced = await Promise.all([
    exchange(main, { code: racer.code, code_verifier: racer.verifier, redirect_uri: REDIRECT }),
    exchange(main, { code: racer.code, code_verifier: racer.verifier, redirect_uri: REDIRECT }),
  ]);
  assert.equal(
    raced.filter((r) => r.status === 200).length,
    1,
    `a raced code redemption produced ${raced.map((r) => r.status).join("/")}`,
  );
  assert.equal(raced.find((r) => r.status !== 200).json.error, "invalid_grant");
  ok("two concurrent redemptions of one code produce exactly one grant");

  const pkceFlow = await getCode(main);
  const badPkce = await exchange(main, {
    code: pkceFlow.code,
    code_verifier: crypto.randomBytes(32).toString("base64url"),
    redirect_uri: REDIRECT,
  });
  assert.equal(badPkce.status, 400);
  assert.equal(badPkce.json.error, "invalid_grant");
  // The code is popped before validation, so even the correct verifier must now
  // fail: a failed PKCE check may not leave a retryable code behind.
  const retryAfterBadPkce = await exchange(main, {
    code: pkceFlow.code,
    code_verifier: pkceFlow.verifier,
    redirect_uri: REDIRECT,
  });
  assert.equal(retryAfterBadPkce.status, 400);
  assert.equal(retryAfterBadPkce.json.error, "invalid_grant");
  ok("a wrong PKCE verifier is rejected and consumes the code");

  for (const fields of [
    { code_verifier: null },
    { code_verifier: "" },
    { code_verifier: "a".repeat(42) },
    { code_verifier: "a".repeat(129) },
    { code_verifier: `${"a".repeat(40)}+/=` },
  ]) {
    const got = await getCode(main);
    const r = await exchange(main, { code: got.code, redirect_uri: REDIRECT, ...fields });
    assert.equal(r.status, 400, `verifier ${JSON.stringify(fields)} -> ${r.status}`);
    assert.equal(r.json.error, "invalid_request", `verifier ${JSON.stringify(fields)} -> ${r.text.slice(0, 200)}`);
  }
  ok("missing and malformed code_verifier values are rejected before any comparison");

  const mismatch = await getCode(main);
  const wrongRedirect = await exchange(main, {
    code: mismatch.code,
    code_verifier: mismatch.verifier,
    redirect_uri: REDIRECT_ALT,
  });
  assert.equal(wrongRedirect.status, 400);
  assert.equal(wrongRedirect.json.error, "invalid_grant");
  ok("/token rejects a redirect_uri that differs from the authorization request");

  const badTargetFlow = await getCode(main);
  const badTarget = await exchange(main, {
    code: badTargetFlow.code,
    code_verifier: badTargetFlow.verifier,
    redirect_uri: REDIRECT,
    resource: "https://evil.example",
  });
  assert.equal(badTarget.status, 400);
  assert.equal(badTarget.json.error, "invalid_target");
  ok("/token rejects a resource that does not identify this server");

  // --- rid is single use, and a wrong approval token re-arms it -------------
  const single = await consent(main);
  const singleRid = ridOf(single.res.text);
  assert.equal((await form(main, "/authorize", { rid: singleRid, bearer: TOKEN })).status, 302);
  const reused = await form(main, "/authorize", { rid: singleRid, bearer: TOKEN });
  assert.equal(reused.status, 400, "an approval link must not be reusable");
  assert.match(reused.text, /expired/i);
  assert.equal((await form(main, "/authorize", { rid: "0".repeat(32), bearer: TOKEN })).status, 400);
  ok("an approval rid is single use and an unknown rid is refused");

  const wrongApproval = await consent(main);
  const wrongRid = ridOf(wrongApproval.res.text);
  const refused = await form(main, "/authorize", { rid: wrongRid, bearer: "not-the-bridge-token-but-long-enough" });
  assert.equal(refused.status, 403, "a wrong approval token must not issue a code");
  assert.equal(refused.headers.get("location"), null, "a refused approval must not redirect");
  const retryRid = ridOf(refused.text);
  assert.notEqual(retryRid, wrongRid, "the retry must use a fresh rid");
  assert.equal((await form(main, "/authorize", { rid: wrongRid, bearer: TOKEN })).status, 400, "the failed rid must be dead");
  assert.equal(
    (await form(main, "/authorize", { rid: retryRid, bearer: TOKEN })).status,
    302,
    "the re-armed rid must accept the correct token",
  );
  ok("a wrong approval token yields 403 with a fresh rid; the old rid is dead");

  // =========================================================================
  // REFRESH ROTATION
  // =========================================================================
  const first = await tokens(main);
  const refreshed = await refresh(main, first.refresh_token);
  assert.equal(refreshed.status, 200, `refresh failed: ${refreshed.text.slice(0, 300)}`);
  const second = refreshed.json;
  const firstRefreshRecord = tokenRecord(main, "refresh", first.refresh_token);
  const secondAccessRecord = tokenRecord(main, "access", second.access_token);
  const secondRefreshRecord = tokenRecord(main, "refresh", second.refresh_token);
  assert.match(firstRefreshRecord?.sid || "", /^sess_[A-Za-z0-9_-]{16,}$/);
  assert.equal(secondAccessRecord?.sid, firstRefreshRecord.sid, "refresh changed OAuth session correlation lineage");
  assert.equal(secondRefreshRecord?.sid, firstRefreshRecord.sid, "rotated refresh token lost OAuth session correlation lineage");
  assert.notEqual(second.access_token, first.access_token);
  assert.notEqual(second.refresh_token, first.refresh_token);
  assert.equal(second.token_type, "Bearer");
  assert.match(second.refresh_token, /^[A-Za-z0-9_-]{43}$/, "a refresh must return a refresh token too");
  assert.equal(await tokenStatus(main, second.access_token), 405, "the refreshed access token must work");
  assert.equal(await tokenStatus(main, first.access_token), 405, "refreshing must not revoke the live access token");
  // ChatGPT has been observed refreshing before every call and retrying, so the
  // previous refresh token stays usable inside the rotation grace window.
  const graceful = await refresh(main, first.refresh_token);
  assert.equal(graceful.status, 200, `the previous refresh token must survive the grace window: ${graceful.text.slice(0, 200)}`);
  assert.equal(await tokenStatus(main, graceful.json.access_token), 405);
  const refreshWrongClient = await form(main, "/token", {
    grant_type: "refresh_token",
    client_id: "someone-else",
    refresh_token: second.refresh_token,
  });
  assert.equal(refreshWrongClient.status, 401);
  assert.equal(refreshWrongClient.json.error, "invalid_client");
  const refreshWrongResource = await refresh(main, second.refresh_token, { resource: "https://evil.example" });
  assert.equal(refreshWrongResource.status, 400);
  assert.equal(refreshWrongResource.json.error, "invalid_target");
  ok("refresh_token rotates, keeps the old access token, and honours the grace window");

  // =========================================================================
  // REVOCATION
  // =========================================================================
  const doomed = await tokens(main);
  assert.equal(await tokenStatus(main, doomed.access_token), 405);
  assert.equal((await form(main, "/revoke", { token: doomed.access_token })).status, 200);
  assert.equal(await tokenStatus(main, doomed.access_token), 401, "a revoked access token still authorized");
  // Revoking the access token must not silently kill its refresh token.
  const stillRefreshable = await refresh(main, doomed.refresh_token);
  assert.equal(stillRefreshable.status, 200, `revoking an access token killed the refresh token: ${stillRefreshable.text.slice(0, 200)}`);
  const fromRefresh = stillRefreshable.json;
  assert.equal((await form(main, "/revoke", { token: doomed.refresh_token })).status, 200);
  const deadRefresh = await refresh(main, doomed.refresh_token);
  assert.equal(deadRefresh.status, 400);
  assert.equal(deadRefresh.json.error, "invalid_grant");
  ok("/revoke kills exactly the presented access or refresh token");

  // /revoke is unauthenticated, so anyone who learns the bridge token could aim it
  // at the static bearer. It must be inert there, not a remote self-lockout.
  assert.equal((await form(main, "/revoke", { token: TOKEN })).status, 200);
  assert.equal(await tokenStatus(main, TOKEN), 405, "/revoke disabled the static bearer token");
  ok("/revoke cannot disable the static bearer token");

  // An OAuth token must not be able to revoke the operator's other sessions.
  const revokeAllAsOauth = await req(main, "/revoke-all", {
    method: "POST",
    headers: { authorization: `Bearer ${fromRefresh.access_token}` },
  });
  assert.equal(revokeAllAsOauth.status, 401, "an OAuth token must not reach /revoke-all");
  assert.equal(await tokenStatus(main, fromRefresh.access_token), 405, "the rejected call must not have revoked anything");

  // Issued but unredeemed: /revoke-all clears pending codes too, or a stale
  // browser tab could still trade one in after the operator revoked everything.
  const pendingCode = await getCode(main);
  const revokeAll = await req(main, "/revoke-all", { method: "POST", headers: { authorization: `Bearer ${TOKEN}` } });
  assert.equal(revokeAll.status, 200);
  assert.ok(
    revokeAll.json.revoked.access > 0 && revokeAll.json.revoked.refresh > 0,
    `nothing was revoked: ${revokeAll.text.slice(0, 200)}`,
  );
  for (const t of [...seenAccessTokens, second.access_token, graceful.json.access_token, fromRefresh.access_token]) {
    assert.equal(await tokenStatus(main, t), 401, "/revoke-all left an access token alive");
  }
  assert.equal((await refresh(main, fromRefresh.refresh_token)).status, 400, "/revoke-all left a refresh token alive");
  const staleCode = await exchange(main, {
    code: pendingCode.code,
    code_verifier: pendingCode.verifier,
    redirect_uri: REDIRECT,
  });
  assert.equal(staleCode.status, 400, "/revoke-all left a pending authorization code redeemable");
  assert.equal(staleCode.json.error, "invalid_grant");
  assert.equal(await tokenStatus(main, TOKEN), 405, "/revoke-all must not touch the static bearer");
  ok("/revoke-all requires the static bearer, clears every OAuth token, and keeps the bearer working");

  // =========================================================================
  // MALFORMED INPUT ON EVERY NEW ROUTE
  // =========================================================================
  const junkBodies = [
    ["", {}],
    ["{oops", { "content-type": "application/json" }],
    ["null", { "content-type": "application/json" }],
    ['"hello"', { "content-type": "application/json" }],
    ["[1,2,3]", { "content-type": "application/json" }],
    ['{"grant_type":{"nested":true},"client_id":["a"]}', { "content-type": "application/json" }],
    ["%zz=%zz&grant_type=%", {}],
    ["grant_type=authorization_code&code=%e0%a4%a", {}],
    ["a=1&a=2&a=3", {}],
    [" ", {}],
    ["rid=%zz&bearer=%zz", {}],
    ["token=%zz", {}],
    ["=&=&=", {}],
  ];
  for (const [body, headers] of junkBodies) {
    for (const pathname of ["/token", "/authorize", "/revoke"]) {
      const r = await form(main, pathname, body, headers);
      assert.ok(
        r.status < 500,
        `POST ${pathname} answered ${r.status} for ${JSON.stringify(body).slice(0, 40)}; a 5xx means a throw escaped a handler`,
      );
    }
  }
  // Malformed client authentication headers must not throw either.
  for (const header of [
    "Basic",
    "Basic ",
    "Basic !!!!",
    `Basic ${Buffer.from("nocolon").toString("base64")}`,
    `Basic ${Buffer.from(":onlysecret").toString("base64")}`,
    "Bearer x",
    "Digest y",
  ]) {
    const r = await form(main, "/token", { grant_type: "authorization_code" }, { authorization: header });
    assert.ok(r.status === 400 || r.status === 401, `Authorization ${JSON.stringify(header)} -> ${r.status}`);
  }
  assert.equal(main.exit, null, "the server died on malformed input");
  assert.equal((await req(main, "/healthz")).status, 200);
  const survivor = await tokens(main);
  const survivorTools = await rpc(main, { jsonrpc: "2.0", id: 4, method: "tools/list" }, survivor.access_token);
  assert.ok(survivorTools.json?.result?.tools?.length > 0, "the server stopped serving MCP after malformed input");
  ok("malformed bodies and Authorization headers never 5xx and never kill the server");

  // --- raw-socket cases the fetch client cannot produce --------------------
  // Host is the only source of the public origin through cloudflared, so the
  // issuer has to follow it -- and an unusable Host must degrade, not 500.
  const hostDerived = await raw(
    main.port,
    "GET /.well-known/oauth-authorization-server HTTP/1.1\r\nHost: tunnel.example.test\r\nConnection: close\r\n\r\n",
  );
  assert.equal(hostDerived.status, 200, hostDerived.statusLine);
  assert.equal(hostDerived.json.issuer, "http://tunnel.example.test");
  for (const header of ["X-Forwarded-Proto: https", 'CF-Visitor: {"scheme":"https"}']) {
    const https = await raw(
      main.port,
      `GET /.well-known/oauth-authorization-server HTTP/1.1\r\nHost: tunnel.example.test\r\n${header}\r\nConnection: close\r\n\r\n`,
    );
    assert.equal(https.json.issuer, "https://tunnel.example.test", `${header} did not produce an https issuer`);
  }
  // No Host at all (HTTP/1.0), and a Host the origin regex rejects.
  assert.equal((await raw(main.port, "GET /.well-known/oauth-protected-resource HTTP/1.0\r\n\r\n")).status, 400);
  const oddHost = await raw(
    main.port,
    "GET /.well-known/oauth-protected-resource HTTP/1.1\r\nHost: a~b\r\nConnection: close\r\n\r\n",
  );
  assert.equal(oddHost.status, 400, "a Host the origin regex rejects must be a 400, not a header injection");
  const noHostMcp = await raw(main.port, "GET /mcp HTTP/1.0\r\n\r\n");
  assert.equal(noHostMcp.status, 401, "an unusable Host must still yield 401, never 500");
  assert.equal(noHostMcp.headers.get("www-authenticate"), 'Bearer scope="mcp"');
  const noHostAuthorize = await raw(
    main.port,
    `GET /authorize?${query({ client_id: CLIENT_ID, redirect_uri: REDIRECT })} HTTP/1.0\r\n\r\n`,
  );
  assert.equal(noHostAuthorize.status, 400);
  assert.equal(noHostAuthorize.headers.get("location"), undefined, "an origin-less /authorize must not redirect");
  // A Host that makes new URL throw was an unauthenticated one-packet process kill.
  for (const host of ["foo:bar", "my host", "xxx:70000"]) {
    const r = await raw(main.port, `GET /authorize HTTP/1.1\r\nHost: ${host}\r\nConnection: close\r\n\r\n`);
    assert.equal(r.status, 400, `Host ${JSON.stringify(host)} -> ${r.statusLine}`);
  }
  assert.equal(main.exit, null, "the server died on a hostile Host header");
  assert.equal((await req(main, "/healthz")).status, 200);
  ok("issuer follows Host, unusable Hosts degrade to 400/401, and the server survives all of them");

  // --- lenient client authentication where it must be lenient --------------
  // A client_secret this server was never configured with is ignored, not fatal:
  // a connector dialog that filled the field in must not be stranded.
  const strayFlow = await getCode(main);
  const stray = await exchange(main, {
    code: strayFlow.code,
    code_verifier: strayFlow.verifier,
    redirect_uri: REDIRECT,
    client_secret: "a-secret-this-server-never-knew",
  });
  assert.equal(stray.status, 200, `an unconfigured client_secret must be ignored: ${stray.text.slice(0, 300)}`);
  assert.match(main.stderr, /presented a client_secret but none is configured/);

  // No verbatim capture of ChatGPT's POST /token exists, so both encodings and
  // both client-authentication transports have to work.
  const jsonFlow = await getCode(main);
  const jsonRes = await req(main, "/token", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({
      grant_type: "authorization_code",
      client_id: CLIENT_ID,
      code: jsonFlow.code,
      code_verifier: jsonFlow.verifier,
      redirect_uri: REDIRECT,
      unknown_field: "must be ignored",
    }),
  });
  assert.equal(jsonRes.status, 200, `a JSON token request failed: ${jsonRes.text.slice(0, 300)}`);
  const basicFlow = await getCode(main);
  const basicRes = await req(main, "/token", {
    method: "POST",
    headers: {
      authorization: `Basic ${Buffer.from(`${CLIENT_ID}:`).toString("base64")}`,
      "content-type": "application/x-www-form-urlencoded",
    },
    body: query({
      grant_type: "authorization_code",
      code: basicFlow.code,
      code_verifier: basicFlow.verifier,
      redirect_uri: REDIRECT,
    }),
  });
  assert.equal(basicRes.status, 200, `HTTP Basic client authentication failed: ${basicRes.text.slice(0, 300)}`);
  ok("/token tolerates a JSON body, unknown fields, HTTP Basic, and an unconfigured client_secret");

  await stop(main);

  // =========================================================================
  // PERSISTENCE, EXPIRY AND BEARER ROTATION
  //
  // ACCESS_TTL_MS is one hour and CODE_TTL_MS one minute, neither overridable, so
  // natural expiry is unreachable in a test. Access-token expiry is exercised by
  // back-dating the persisted record and restarting, which is the same
  // `exp <= now` gate the live check uses. Authorization codes have no on-disk
  // form, so what is asserted for them instead is that a code never survives a
  // restart -- the property that makes their 60s TTL safe.
  // =========================================================================
  const persistDir = await freshDataDir("persist");
  let p = await startServer({ dataDir: persistDir, label: "persist-1" });
  const keep = await tokens(p);
  const doomedByClock = (await refresh(p, keep.refresh_token)).json;
  const shortLived = (await refresh(p, keep.refresh_token)).json;
  for (const t of [keep, doomedByClock, shortLived]) assert.equal(await tokenStatus(p, t.access_token), 405);
  await stop(p);

  const saved = readState(p);
  const savedKeepAccess = saved.access.find((record) => record.d === digestOf(keep.access_token));
  const savedKeepRefresh = saved.refresh.find((record) => record.d === digestOf(keep.refresh_token));
  assert.match(savedKeepAccess?.sid || "", /^sess_[A-Za-z0-9_-]{16,}$/);
  assert.equal(savedKeepRefresh?.sid, savedKeepAccess.sid, "persisted access/refresh records lost one OAuth session lineage");
  assert.equal(saved.client.id, CLIENT_ID, "the client_id must persist or the connector breaks inside ChatGPT");
  assert.equal((await fsp.stat(stateFile(p))).mode & 0o777, 0o600, "oauth-state.json must be 0600");
  assert.equal((await fsp.stat(persistDir)).mode & 0o777, 0o700, "the data dir must be 0700");
  assert.ok(saved.access.some((r) => r.d === digestOf(keep.access_token)), "the access token was not persisted");
  assert.ok(
    saved.access.every((r) => typeof r.exp === "number" && r.exp > Date.now()),
    "a persisted token is already expired",
  );
  assert.ok(!JSON.stringify(saved).includes(keep.access_token), "the plaintext access token was written to disk");
  assert.ok(!JSON.stringify(saved).includes(TOKEN), "the bridge token was written to the OAuth state file");
  ok("oauth-state.json is 0600, stores only digests, and keeps the client_id");

  p = await startServer({ dataDir: persistDir, label: "persist-2" });
  assert.equal(await tokenStatus(p, keep.access_token), 405, "a live access token must survive a restart");
  assert.equal(tokenRecord(p, "access", keep.access_token)?.sid, savedKeepAccess.sid, "OAuth session correlation id changed across restart");
  const refreshedAfterRestart = await refresh(p, keep.refresh_token);
  assert.equal(refreshedAfterRestart.status, 200, "a refresh token must survive a restart");
  assert.equal(tokenRecord(p, "access", refreshedAfterRestart.json.access_token)?.sid, savedKeepAccess.sid, "refresh after restart forked OAuth session lineage");
  assert.equal(tokenRecord(p, "refresh", refreshedAfterRestart.json.refresh_token)?.sid, savedKeepAccess.sid, "rotated refresh after restart forked OAuth session lineage");
  ok("access, refresh, and opaque OAuth session lineage survive a restart");
  await stop(p);

  // Back-date exactly one record. The untouched one is the control proving the
  // restart itself is not what invalidated the token.
  const backdated = readState(p);
  const victim = backdated.access.find((r) => r.d === digestOf(doomedByClock.access_token));
  assert.ok(victim, "the token to expire is not in the state file");
  victim.exp = Date.now() - 1000;
  writeState(p, backdated);
  p = await startServer({ dataDir: persistDir, label: "persist-expired" });
  assert.equal(await tokenStatus(p, doomedByClock.access_token), 401, "an expired access token still authorized");
  assert.equal(await tokenStatus(p, keep.access_token), 405, "the unexpired control token was dropped too");
  ok("an expired access token is refused while a live one is kept");
  await stop(p);

  // The check above is the load-time gate in rehydrate(). This one is the live
  // `exp <= Date.now()` gate inside the auth path, which only a token that
  // expires WHILE the server runs can reach. A record dated a few seconds out is
  // the only way there without an hour-long sleep.
  const shortDated = readState(p);
  const expiring = shortDated.access.find((r) => r.d === digestOf(shortLived.access_token));
  assert.ok(expiring, "the short-dated token is not in the state file");
  expiring.exp = Date.now() + 4000;
  writeState(p, shortDated);
  p = await startServer({ dataDir: persistDir, label: "persist-shortlived" });
  assert.equal(
    await tokenStatus(p, shortLived.access_token),
    405,
    "a token still inside its lifetime was refused (or this machine took 4s to start a node process)",
  );
  await new Promise((r) => setTimeout(r, Math.max(0, expiring.exp - Date.now()) + 250));
  assert.equal(await tokenStatus(p, shortLived.access_token), 401, "an access token past its exp still authorized");
  assert.equal(await tokenStatus(p, keep.access_token), 405, "the still-live control token was refused too");
  ok("an access token that expires while the server runs stops authorizing");
  await stop(p);

  // A hand-edited or truncated digest reaches Buffer.from(hex) inside the auth
  // path, where a short buffer makes timingSafeEqual throw -- turning every 401
  // into a 500.
  const corrupt = readState(p);
  corrupt.access = [
    null,
    "nope",
    {},
    { d: 123, exp: Date.now() + 60_000 },
    { d: "abcd", exp: Date.now() + 60_000 },
    { d: "Z".repeat(64), exp: Date.now() + 60_000 },
    { d: digestOf(keep.access_token), exp: "soon" },
    ...corrupt.access.filter((r) => r && r.d === digestOf(keep.access_token)),
  ];
  corrupt.refresh = "not-an-array";
  writeState(p, corrupt);
  p = await startServer({ dataDir: persistDir, label: "persist-corrupt" });
  assert.equal(await tokenStatus(p, keep.access_token), 405, "a valid record was lost among corrupt ones");
  for (const bogus of ["abcd", "Z".repeat(64), crypto.randomBytes(32).toString("base64url")]) {
    assert.equal(await tokenStatus(p, bogus), 401, `probing with ${bogus.slice(0, 8)} did not produce a clean 401`);
  }
  assert.equal((await req(p, "/.well-known/oauth-authorization-server")).status, 200);
  ok("corrupt records in oauth-state.json are dropped without turning a 401 into a 500");
  await stop(p);

  // An unparseable file must degrade to an empty store, not a dead endpoint.
  await fsp.writeFile(stateFile(p), "{ this is not json");
  p = await startServer({ dataDir: persistDir, label: "persist-garbage" });
  assert.equal(await tokenStatus(p, keep.access_token), 401);
  assert.match(p.stderr, /oauth state unreadable|OAuth state initialisation failed/);
  const regenerated = await tokens(p);
  assert.equal(await tokenStatus(p, regenerated.access_token), 405);
  ok("an unparseable state file degrades to an empty store and OAuth still works");

  const orphan = await getCode(p);
  await stop(p);
  p = await startServer({ dataDir: persistDir, label: "persist-code" });
  const orphanExchange = await exchange(p, { code: orphan.code, code_verifier: orphan.verifier, redirect_uri: REDIRECT });
  assert.equal(orphanExchange.status, 400, "an authorization code survived a restart");
  assert.equal(orphanExchange.json.error, "invalid_grant");
  const liveAcrossRotation = await tokens(p);
  ok("an authorization code never survives a restart");
  await stop(p);

  // Rotating the bearer token must revoke every OAuth session while keeping the
  // client_id, so the operator only has to re-approve.
  p = await startServer({ dataDir: persistDir, token: ROTATED_TOKEN, label: "persist-rotated" });
  assert.match(p.stderr, /bearer token rotated: revoked \d+ OAuth access and \d+ refresh token\(s\)/);
  assert.equal(await tokenStatus(p, liveAcrossRotation.access_token), 401, "rotation did not revoke the access token");
  assert.equal((await refresh(p, liveAcrossRotation.refresh_token)).status, 400, "rotation did not revoke the refresh token");
  assert.equal(await tokenStatus(p, ROTATED_TOKEN), 405, "the new bearer must work");
  assert.equal(await tokenStatus(p, TOKEN), 401, "the old bearer must not work");
  assert.equal(readState(p).client.id, CLIENT_ID, "the client_id must survive a rotation");
  // Approval now needs the rotated token, and a fresh grant must work again.
  const staleApproval = await consent(p);
  assert.equal((await form(p, "/authorize", { rid: ridOf(staleApproval.res.text), bearer: TOKEN })).status, 403);
  const afterRotation = await tokens(p, {}, ROTATED_TOKEN);
  assert.equal(await tokenStatus(p, afterRotation.access_token), 405, "OAuth must work again after a rotation");
  ok("rotating the bearer token revokes every OAuth session and preserves the client_id");
  await stop(p);

  // =========================================================================
  // PUBLIC_URL OVERRIDE, CLIENT SECRET, EXTRA REDIRECT URI, WRONG-APPROVAL FLOOD
  // =========================================================================
  const alt = await startServer({
    dataDir: await freshDataDir("alt"),
    label: "alt",
    env: {
      DARWINRELAY_PUBLIC_URL: "https://tunnel.example.test/",
      DARWINRELAY_OAUTH_CLIENT_SECRET: CLIENT_SECRET,
      DARWINRELAY_OAUTH_REDIRECT_URIS: `${EXTRA_REDIRECT} , `,
    },
  });
  const ALT_ORIGIN = "https://tunnel.example.test";
  const altAs = await req(alt, "/.well-known/oauth-authorization-server");
  assert.equal(altAs.json.issuer, ALT_ORIGIN, "DARWINRELAY_PUBLIC_URL must win over Host and lose its trailing slash");
  assert.equal(altAs.json.token_endpoint, `${ALT_ORIGIN}/token`);
  const forgedHost = await raw(
    alt.port,
    "GET /.well-known/oauth-protected-resource/mcp HTTP/1.1\r\nHost: attacker.example\r\nConnection: close\r\n\r\n",
  );
  assert.equal(forgedHost.json.resource, `${ALT_ORIGIN}/mcp`, "a forged Host must not override PUBLIC_URL");
  const altChallenge = (await rpc(alt, { jsonrpc: "2.0", id: 1, method: "ping" })).headers.get("www-authenticate");
  assert.ok(
    altChallenge.includes(`resource_metadata="${ALT_ORIGIN}/.well-known/oauth-protected-resource/mcp"`),
    `challenge ignored PUBLIC_URL: ${altChallenge}`,
  );
  ok("DARWINRELAY_PUBLIC_URL overrides the Host-derived origin everywhere");

  // Appended, never replaced: the measured ChatGPT callback must still work.
  const extra = await getCode(alt, { redirect_uri: EXTRA_REDIRECT });
  const extraTokens = await exchange(alt, {
    code: extra.code,
    code_verifier: extra.verifier,
    redirect_uri: EXTRA_REDIRECT,
    client_secret: CLIENT_SECRET,
  });
  assert.equal(extraTokens.status, 200, `a configured extra redirect_uri failed: ${extraTokens.text.slice(0, 300)}`);
  const builtIn = await getCode(alt, { redirect_uri: REDIRECT_ALT });
  const builtInTokens = await exchange(alt, {
    code: builtIn.code,
    code_verifier: builtIn.verifier,
    redirect_uri: REDIRECT_ALT,
    client_secret: CLIENT_SECRET,
  });
  assert.equal(builtInTokens.status, 200, "adding a redirect_uri dropped a built-in ChatGPT callback");
  ok("DARWINRELAY_OAUTH_REDIRECT_URIS appends to the built-in callbacks");

  // A configured secret is enforced whenever it is presented, in both transports.
  const secretFlow = await getCode(alt);
  const badSecret = await exchange(alt, {
    code: secretFlow.code,
    code_verifier: secretFlow.verifier,
    redirect_uri: REDIRECT,
    client_secret: "wrong-secret",
  });
  assert.equal(badSecret.status, 401);
  assert.equal(badSecret.json.error, "invalid_client");
  const oversizedSecretFlow = await getCode(alt);
  const oversizedSecret = await exchange(alt, {
    code: oversizedSecretFlow.code,
    code_verifier: oversizedSecretFlow.verifier,
    redirect_uri: REDIRECT,
    client_secret: "x".repeat(5000),
  });
  assert.equal(oversizedSecret.status, 401);
  assert.equal(oversizedSecret.json.error, "invalid_client");
  const basicSecretFlow = await getCode(alt);
  const basicSecret = await req(alt, "/token", {
    method: "POST",
    headers: {
      authorization: `Basic ${Buffer.from(`${CLIENT_ID}:${CLIENT_SECRET}`).toString("base64")}`,
      "content-type": "application/x-www-form-urlencoded",
    },
    body: query({
      grant_type: "authorization_code",
      code: basicSecretFlow.code,
      code_verifier: basicSecretFlow.verifier,
      redirect_uri: REDIRECT,
    }),
  });
  assert.equal(basicSecret.status, 200, `Basic id:secret was rejected: ${basicSecret.text.slice(0, 300)}`);
  ok("a configured client_secret is enforced via client_secret_post and client_secret_basic");

  // The OAuth client credentials must be as unreadable to shell_exec as the
  // bearer token is.
  await initBridge(alt, TOKEN);
  const envProbe = await rpc(
    alt,
    {
      jsonrpc: "2.0",
      id: 9,
      method: "tools/call",
      params: { name: "shell_exec", arguments: { command: "env | grep -c '^DARWINRELAY_OAUTH' || true" } },
    },
    TOKEN,
  );
  assert.ok(!envProbe.text.includes(CLIENT_SECRET), "the client secret appeared in shell output");
  assert.match(envProbe.text, /"stdout":"0/, `OAuth client credentials still in the child env: ${envProbe.text.slice(0, 400)}`);
  ok("OAuth client credentials are scrubbed from the shell_exec environment");

  // POST /authorize is reachable from the public tunnel by anyone, so a wrong
  // approval must cost the caller time and NOTHING ELSE. Any counter or lockout
  // here is a remote denial of the only path that can approve the connector: it
  // would refuse the operator's correct token too, indefinitely, for the price of
  // a handful of anonymous requests -- and it protects nothing, because the
  // credential it rate-limits is >=24 random bytes compared as a digest.
  const FLOOD = 8; // well past any plausible lockout threshold
  let floodPage = (await consent(alt)).res.text;
  for (let i = 1; i <= FLOOD; i += 1) {
    const started = Date.now();
    const r = await form(alt, "/authorize", { rid: ridOf(floodPage), bearer: "definitely-not-the-token-here" });
    assert.equal(r.status, 403, `wrong approval ${i} must stay a 403 retry page, got ${r.status}`);
    assert.equal(r.headers.get("location"), null, `wrong approval ${i} must not redirect`);
    // The brake that replaced the lockout: delay the failure, keep no state.
    assert.ok(Date.now() - started >= 200, `wrong approval ${i} was not delayed, so guessing is free`);
    floodPage = r.text;
  }
  const afterFlood = await consent(alt);
  assert.equal(afterFlood.res.status, 200, "GET /authorize must still render after a flood of wrong approvals");
  const approvedAfterFlood = await form(alt, "/authorize", { rid: ridOf(afterFlood.res.text), bearer: TOKEN });
  assert.equal(
    approvedAfterFlood.status,
    302,
    `${FLOOD} anonymous wrong approvals denied the operator's correct token (got ${approvedAfterFlood.status})`,
  );
  assert.ok(
    new URL(approvedAfterFlood.headers.get("location")).searchParams.get("code"),
    "the approval after the flood issued no authorization code",
  );
  assert.equal((await req(alt, "/healthz")).status, 200);
  ok(`${FLOOD} wrong approvals are each delayed and still cannot deny the correct token`);
  await stop(alt);

  // A malformed PUBLIC_URL must degrade to the Host header, never refuse to start
  // and never reach a response header.
  const badPublicUrls = ["not a url", "https://ok.example/path", 'https://ok.example"x', "https://ok.example\r\nX-Injected: 1", "ftp:/x"];
  for (const bad of badPublicUrls) {
    const degraded = await startServer({
      dataDir: await freshDataDir("degraded"),
      label: `degraded ${JSON.stringify(bad)}`,
      env: { DARWINRELAY_PUBLIC_URL: bad },
    });
    assert.match(degraded.stderr, /ignoring malformed DARWINRELAY_PUBLIC_URL/, `no warning for ${JSON.stringify(bad)}`);
    const d = await req(degraded, "/.well-known/oauth-authorization-server");
    assert.equal(d.json.issuer, degraded.base, `${JSON.stringify(bad)} did not fall back to the Host header`);
    const ch = (await rpc(degraded, { jsonrpc: "2.0", id: 1, method: "ping" })).headers.get("www-authenticate");
    assert.ok(!/[\r\n]/.test(ch) && !ch.includes("X-Injected"), `challenge header polluted by ${JSON.stringify(bad)}`);
    await stop(degraded);
  }
  ok(`${badPublicUrls.length} malformed DARWINRELAY_PUBLIC_URL values are ignored with a warning, never fatal`);

  console.log(results.join("\n"));
  console.log("oauth test passed");
} catch (e) {
  console.log(results.join("\n"));
  console.log(`\n  FAIL  ${e.stack || e.message}`);
  for (const s of servers) {
    if (!s.stderr) continue;
    console.log(`--- ${s.label} (port ${s.port}) stderr ---\n${s.stderr}`);
  }
  process.exitCode = 1;
} finally {
  // Only handles this file spawned are ever signalled.
  for (const s of servers) await stop(s);
  await fsp.rm(tempRoot, { recursive: true, force: true });
}
