// Reads the signed-in ChatGPT account's Codex plan quota through the official
// `codex app-server` JSON-RPC interface (`account/rateLimits/read`), the same call
// Codex makes for its own /status view. Codex owns and refreshes its credentials;
// this helper never reads them and prints one whitelisted JSON object on stdout.
//
// Usage: node codex-rate-limits.mjs <absolute path to codex.cmd or codex.exe>
import { spawn, spawnSync } from "node:child_process";
import { existsSync, statSync } from "node:fs";
import { isAbsolute, join } from "node:path";

const DEFAULT_TIMEOUT_MS = 20000;
const MAX_LINE_BYTES = 1024 * 1024;
const MAX_TOTAL_BYTES = 4 * 1024 * 1024;
const SYSTEM_ROOT = process.env.SystemRoot || "C:\\Windows";

const requested = Number(process.env.AI_USAGE_CODEX_TIMEOUT_MS);
const timeoutMs = Number.isInteger(requested) && requested >= 100 && requested <= 60000
  ? requested
  : DEFAULT_TIMEOUT_MS;
const command = process.argv[2] || "";

let child = null;
let settled = false;
let initialized = false;
let timer = null;

function childExited() {
  return !child || child.exitCode !== null || child.signalCode !== null;
}

function stopChildTree() {
  if (childExited()) return;
  // The npm shim puts cmd.exe and node.exe above the native binary, so killing the
  // direct child alone would leave app-server running until the caller's Job closes.
  try {
    spawnSync(join(SYSTEM_ROOT, "System32", "taskkill.exe"), ["/T", "/F", "/PID", String(child.pid)],
      { windowsHide: true, stdio: "ignore", timeout: 5000 });
  } catch {}
}

function finish(result) {
  if (settled) return;
  settled = true;
  if (timer) clearTimeout(timer);
  process.stdout.write(JSON.stringify(result) + "\n", () => {
    if (childExited()) process.exit(0);
    // app-server exits on stdin EOF; a wedged one is stopped explicitly.
    try { child.stdin.end(); } catch {}
    const grace = setTimeout(() => { stopChildTree(); process.exit(0); }, 1500);
    child.once("exit", () => { clearTimeout(grace); process.exit(0); });
  });
}

function integerOrNull(value) {
  return Number.isSafeInteger(value) ? value : null;
}

function windowOf(value) {
  if (!value || typeof value !== "object" || Array.isArray(value)) return null;
  if (typeof value.usedPercent !== "number" || !Number.isFinite(value.usedPercent)) return null;
  return {
    usedPercent: value.usedPercent,
    windowDurationMins: integerOrNull(value.windowDurationMins),
    resetsAt: integerOrNull(value.resetsAt),
  };
}

function snapshotOf(value) {
  if (!value || typeof value !== "object" || Array.isArray(value)) return null;
  const limitId = typeof value.limitId === "string" ? value.limitId : null;
  if (limitId !== null && limitId !== "codex") return null;
  const primary = windowOf(value.primary);
  const secondary = windowOf(value.secondary);
  if (!primary && !secondary) return null;
  const planType = typeof value.planType === "string" && /^[A-Za-z0-9_]{1,64}$/.test(value.planType)
    ? value.planType.toLowerCase()
    : null;
  return { limitId, planType, primary, secondary };
}

// Only an explicit missing-login message counts as signed out; an HTTP 401 while
// refreshing, a network fault, or anything unrecognized is an unavailable account.
function classifyError(error) {
  const message = String((error && error.message) || "").toLowerCase();
  if (/not (logged|signed) in|login required|log in to|sign in to|authentication required|no (chatgpt )?account|requires? (a )?(chatgpt )?(login|sign-in|account)/.test(message)) {
    return "not_logged_in";
  }
  return "account_unavailable";
}

function send(message) {
  try {
    child.stdin.write(JSON.stringify(message) + "\n");
  } catch {
    finish({ ok: false, reason: "failed_local" });
  }
}

function handle(message) {
  // Server notifications and server-to-client requests carry `method`; only
  // responses to this helper's own ids are interpreted.
  if (!message || typeof message !== "object" || "method" in message || !("id" in message)) return;
  if (message.id === 1) {
    if (message.error || !message.result || typeof message.result !== "object") {
      finish({ ok: false, reason: "app_server_unavailable" });
      return;
    }
    initialized = true;
    send({ method: "initialized" });
    send({ id: 2, method: "account/rateLimits/read" });
    return;
  }
  if (message.id !== 2) return;
  if (message.error) {
    finish({ ok: false, reason: classifyError(message.error) });
    return;
  }
  const result = message.result;
  if (!result || typeof result !== "object") {
    finish({ ok: false, reason: "malformed_response" });
    return;
  }
  const byId = result.rateLimitsByLimitId && typeof result.rateLimitsByLimitId === "object"
    ? result.rateLimitsByLimitId
    : null;
  const snapshot = snapshotOf(byId && byId.codex) || snapshotOf(result.rateLimits);
  if (!snapshot) {
    finish({ ok: false, reason: "no_rate_limits" });
    return;
  }
  finish({ ok: true, fetchedAt: new Date().toISOString(), snapshot });
}

function validCommand(path) {
  if (!path || !isAbsolute(path) || /["\r\n]/.test(path) || !/\.(cmd|bat|exe)$/i.test(path)) return false;
  try {
    return existsSync(path) && statSync(path).isFile();
  } catch {
    return false;
  }
}

function start() {
  if (!command) {
    finish({ ok: false, reason: "codex_cli_missing" });
    return;
  }
  if (!validCommand(command)) {
    finish({ ok: false, reason: "failed_local" });
    return;
  }
  const options = { windowsHide: true, stdio: ["pipe", "pipe", "ignore"] };
  try {
    if (/\.(cmd|bat)$/i.test(command)) {
      // npm installs Codex as a .cmd shim. The path travels in the environment so
      // cmd.exe cannot expand a literal percent pair inside it.
      child = spawn(join(SYSTEM_ROOT, "System32", "cmd.exe"),
        ["/d", "/v:off", "/s", "/c", '""%AI_USAGE_CODEX_COMMAND%" app-server"'],
        { ...options, windowsVerbatimArguments: true, env: { ...process.env, AI_USAGE_CODEX_COMMAND: command } });
    } else {
      child = spawn(command, ["app-server"], options);
    }
  } catch {
    finish({ ok: false, reason: "failed_local" });
    return;
  }

  child.on("error", () => finish({ ok: false, reason: "failed_local" }));
  // `close` follows the last stdout chunk, so a reply written just before exit wins.
  // Exiting before `initialize` is answered means this CLI cannot serve app-server.
  child.on("close", () => finish({ ok: false, reason: initialized ? "failed_local" : "app_server_unavailable" }));
  child.stdin.on("error", () => {});

  let pending = Buffer.alloc(0);
  let total = 0;
  child.stdout.on("data", (chunk) => {
    total += chunk.length;
    if (total > MAX_TOTAL_BYTES) {
      finish({ ok: false, reason: "response_too_large" });
      return;
    }
    pending = Buffer.concat([pending, chunk]);
    let newline;
    while ((newline = pending.indexOf(10)) >= 0) {
      const line = pending.subarray(0, newline).toString("utf8").trim();
      pending = pending.subarray(newline + 1);
      if (!line) continue;
      let message;
      try { message = JSON.parse(line); } catch { continue; }
      handle(message);
      if (settled) return;
    }
    if (pending.length > MAX_LINE_BYTES) finish({ ok: false, reason: "response_too_large" });
  });

  timer = setTimeout(() => finish({ ok: false, reason: "request_timed_out" }), timeoutMs);
  send({ id: 1, method: "initialize", params: { clientInfo: { name: "ai_usage", title: "AI Usage", version: "1.0.0" } } });
}

start();
