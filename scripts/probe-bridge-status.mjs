#!/usr/bin/env node

import { spawn } from "node:child_process";
import fs from "node:fs/promises";
import path from "node:path";
import readline from "node:readline";

const TIMEOUT_MS = 10_000;
const CLIENT_INFO = { name: "darwinrelay-doctor", version: "1" };

function usage(message = null) {
  if (message) console.error(`probe-bridge-status: ${message}`);
  console.error("Usage:");
  console.error("  node scripts/probe-bridge-status.mjs --http-port PORT --token-file PATH [--tool bridge_status|ui_status]");
  console.error("  node scripts/probe-bridge-status.mjs --stdio PATH_TO_BRIDGE [--tool bridge_status|ui_status]");
  process.exit(64);
}

function parseArgs(argv) {
  const out = {};
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === "--http-port") out.httpPort = argv[++i];
    else if (arg === "--token-file") out.tokenFile = argv[++i];
    else if (arg === "--stdio") out.stdio = argv[++i];
    else if (arg === "--tool") out.tool = argv[++i];
    else usage(`unknown argument ${arg}`);
  }
  const tool = out.tool || "bridge_status";
  if (!new Set(["bridge_status", "ui_status"]).has(tool)) usage("--tool must be bridge_status or ui_status");
  if (out.stdio && (out.httpPort || out.tokenFile)) usage("choose either --stdio or --http-port/--token-file");
  if (out.stdio) return { mode: "stdio", bridge: out.stdio, tool };
  if (!out.httpPort || !out.tokenFile) usage("HTTP mode requires --http-port and --token-file");
  const port = Number(out.httpPort);
  if (!Number.isInteger(port) || port < 1 || port > 65535) usage("HTTP port must be 1-65535");
  return { mode: "http", port, tokenFile: out.tokenFile, tool };
}

function statusFromToolReply(reply, tool) {
  if (!reply || typeof reply !== "object") throw new Error(`empty ${tool} reply`);
  if (reply.error) throw new Error(`JSON-RPC ${reply.error.code ?? "error"}: ${reply.error.message || "bridge error"}`);
  const result = reply.result;
  if (!result || result.isError) {
    const text = result?.content?.find?.((item) => item?.type === "text")?.text;
    throw new Error(text || `${tool} returned an MCP error`);
  }
  if (result.structuredContent && typeof result.structuredContent === "object") return result.structuredContent;
  const text = result.content?.find?.((item) => item?.type === "text")?.text;
  if (typeof text === "string") {
    const parsed = JSON.parse(text);
    if (parsed && typeof parsed === "object") return parsed;
  }
  throw new Error(`${tool} reply had no structured status object`);
}

async function probeHttp({ port, tokenFile, tool }) {
  const raw = await fs.readFile(tokenFile, "utf8");
  const token = raw.trim();
  if (!token) throw new Error("token file is empty");
  const endpoint = `http://127.0.0.1:${port}/mcp`;

  const rpc = async (body) => {
    const response = await fetch(endpoint, {
      method: "POST",
      headers: {
        "content-type": "application/json",
        accept: "application/json",
        authorization: `Bearer ${token}`,
      },
      body: JSON.stringify(body),
      signal: AbortSignal.timeout(TIMEOUT_MS),
    });
    if (body.id === undefined || body.id === null) {
      if (response.status !== 202 && !response.ok) throw new Error(`HTTP ${response.status} for MCP notification`);
      await response.arrayBuffer();
      return null;
    }
    const text = await response.text();
    if (!response.ok) throw new Error(`HTTP ${response.status}: ${text.slice(0, 300)}`);
    try {
      return JSON.parse(text);
    } catch {
      throw new Error(`HTTP MCP returned non-JSON content (${response.headers.get("content-type") || "unknown"})`);
    }
  };

  const init = await rpc({
    jsonrpc: "2.0",
    id: "doctor-init",
    method: "initialize",
    params: { protocolVersion: "2025-06-18", capabilities: {}, clientInfo: CLIENT_INFO },
  });
  if (!init?.result?.serverInfo?.name) throw new Error("MCP initialize did not return serverInfo");
  await rpc({ jsonrpc: "2.0", method: "notifications/initialized" });
  return statusFromToolReply(await rpc({
    jsonrpc: "2.0",
    id: "doctor-status",
    method: "tools/call",
    params: { name: tool, arguments: {} },
  }), tool);
}

function stdioProbeEnv() {
  const allowed = [
    "PATH", "HOME", "TMPDIR", "USER", "LOGNAME", "LANG", "LC_ALL", "LC_CTYPE", "TERM",
    "DARWINRELAY_DATA_DIR", "DARWINRELAY_LOG_DIR", "DARWINRELAY_UNLOCK_FILE",
    "DARWINRELAY_FULL_ACCESS_ACK", "DARWINRELAY_SHELL",
  ];
  const env = {};
  for (const key of allowed) {
    if (process.env[key] !== undefined) env[key] = process.env[key];
  }
  // A doctor probe must not start configured federated providers or add ordinary
  // tool noise to the operator's audit log. It performs initialize + one
  // bridge_status call and then tears the temporary bridge down.
  env.DARWINRELAY_AUDIT_MODE = "off";
  delete env.DARWINRELAY_MCP_SERVERS;
  delete env.DARWINRELAY_MCP_SERVERS_JSON;
  return env;
}

async function probeStdio({ bridge, tool }) {
  const bridgePath = path.resolve(bridge);
  await fs.access(bridgePath);
  const child = spawn(process.execPath, [bridgePath], {
    stdio: ["pipe", "pipe", "pipe"],
    env: stdioProbeEnv(),
  });
  const rl = readline.createInterface({ input: child.stdout });
  const pending = new Map();
  let stderr = "";
  child.stderr.on("data", (chunk) => { stderr += chunk.toString("utf8"); });

  const failPending = (error) => {
    for (const item of pending.values()) {
      clearTimeout(item.timer);
      item.reject(error);
    }
    pending.clear();
  };
  child.once("error", failPending);
  child.once("exit", (code, signal) => {
    if (pending.size) failPending(new Error(`bridge exited before replying (code=${code}, signal=${signal}): ${stderr.slice(-500)}`));
  });
  rl.on("line", (line) => {
    let message;
    try { message = JSON.parse(line); } catch { return; }
    const item = pending.get(message.id);
    if (!item) return;
    pending.delete(message.id);
    clearTimeout(item.timer);
    item.resolve(message);
  });

  const request = (id, method, params = {}) => new Promise((resolve, reject) => {
    const timer = setTimeout(() => {
      pending.delete(id);
      reject(new Error(`stdio request ${id} timed out: ${stderr.slice(-500)}`));
    }, TIMEOUT_MS);
    pending.set(id, { resolve, reject, timer });
    child.stdin.write(`${JSON.stringify({ jsonrpc: "2.0", id, method, params })}\n`);
  });

  try {
    const init = await request("doctor-init", "initialize", {
      protocolVersion: "2025-06-18",
      capabilities: {},
      clientInfo: CLIENT_INFO,
    });
    if (!init?.result?.serverInfo?.name) throw new Error("MCP initialize did not return serverInfo");
    child.stdin.write(`${JSON.stringify({ jsonrpc: "2.0", method: "notifications/initialized" })}\n`);
    return statusFromToolReply(await request("doctor-status", "tools/call", { name: tool, arguments: {} }), tool);
  } finally {
    rl.close();
    try { child.stdin.end(); } catch {}
    if (child.exitCode === null && child.signalCode === null) child.kill("SIGTERM");
    const force = setTimeout(() => {
      if (child.exitCode === null && child.signalCode === null) child.kill("SIGKILL");
    }, 1500);
    force.unref();
  }
}

const args = parseArgs(process.argv.slice(2));
try {
  const status = args.mode === "http" ? await probeHttp(args) : await probeStdio(args);
  process.stdout.write(`${JSON.stringify(status)}\n`);
} catch (error) {
  // Do not echo credentials or environment. Error strings are constrained to
  // transport/status details produced above or by the local bridge itself.
  console.error(`probe-bridge-status: ${error?.message || error}`);
  process.exitCode = 1;
}
