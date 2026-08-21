import crypto from "node:crypto";

// Private field used only on the stdio hop from mcp-http.mjs to bridge.mjs.
// It is deliberately not part of MCP's public _meta contract: clients do not
// need to know it, and bridge.mjs independently creates the authoritative
// correlationId for every request it receives.
export const TRANSPORT_CORRELATION_FIELD = "_darwinrelayTransportCorrelation";

const PREFIX_RE = /^[a-z][a-z0-9]{1,15}$/;
const CORRELATION_RE = /^([a-z][a-z0-9]{1,15})_([A-Za-z0-9_-]{16,96})$/;
const SESSION_SOURCES = new Set(["mcp-session-header", "oauth-grant"]);
const AUTH_MODES = new Set(["bearer", "oauth"]);

export function newCorrelationId(prefix, bytes = 12) {
  if (!PREFIX_RE.test(prefix)) throw new Error(`Invalid correlation id prefix: ${prefix}`);
  if (!Number.isInteger(bytes) || bytes < 12 || bytes > 48) throw new Error("Correlation id entropy must be 12-48 bytes");
  return `${prefix}_${crypto.randomBytes(bytes).toString("base64url")}`;
}

export function isCorrelationId(value, prefix = null) {
  if (typeof value !== "string") return false;
  const match = CORRELATION_RE.exec(value);
  if (!match) return false;
  return prefix === null || match[1] === prefix;
}

// A client-supplied MCP session id may be identifying or low entropy. Never put
// it in a log, even hashed with a public digest. A process-local HMAC converts it
// into an opaque value that is stable for this HTTP-front-end lifetime but is
// useless for recovering the raw header from audit.jsonl.
export function deriveSessionCorrelationId(key, rawSessionId) {
  if (!Buffer.isBuffer(key) || key.length < 32) throw new Error("Session correlation key must be at least 32 bytes");
  if (typeof rawSessionId !== "string" || rawSessionId.length < 1 || rawSessionId.length > 1024) return null;
  if (!/^[\x21-\x7e]+$/.test(rawSessionId)) return null;
  const digest = crypto.createHmac("sha256", key).update(rawSessionId, "utf8").digest("base64url").slice(0, 24);
  return `sess_${digest}`;
}

export function normalizeTransportCorrelation(value) {
  if (!value || typeof value !== "object" || Array.isArray(value)) return null;
  if (value.v !== 1 || !isCorrelationId(value.requestId, "http")) return null;
  const sessionId = value.sessionId === null || value.sessionId === undefined
    ? null
    : isCorrelationId(value.sessionId, "sess")
      ? value.sessionId
      : null;
  const sessionSource = sessionId && SESSION_SOURCES.has(value.sessionSource) ? value.sessionSource : null;
  const authMode = AUTH_MODES.has(value.authMode) ? value.authMode : null;
  return {
    v: 1,
    requestId: value.requestId,
    sessionId,
    sessionSource,
    authMode,
  };
}

export function attachTransportCorrelation(message, value) {
  const normalized = normalizeTransportCorrelation(value);
  if (!normalized || !message || typeof message !== "object" || Array.isArray(message)) return message;
  return { ...message, [TRANSPORT_CORRELATION_FIELD]: normalized };
}

export function readTransportCorrelation(message) {
  if (!message || typeof message !== "object" || Array.isArray(message)) return null;
  return normalizeTransportCorrelation(message[TRANSPORT_CORRELATION_FIELD]);
}
