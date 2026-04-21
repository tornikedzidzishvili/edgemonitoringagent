import "dotenv/config";
import { writeFile } from "node:fs/promises";
import { createRequire } from "node:module";
import { getEnv } from "./env.js";
import { collectSnapshot } from "./collect.js";
import { postReport } from "./report.js";

const require = createRequire(import.meta.url);
const pkg = require("../package.json") as { version?: string; name?: string };

const env = getEnv();

const log = {
  info: (msg: string, extra?: Record<string, unknown>) =>
    console.log(JSON.stringify({ t: new Date().toISOString(), level: "info", msg, ...extra })),
  warn: (msg: string, extra?: Record<string, unknown>) =>
    console.warn(JSON.stringify({ t: new Date().toISOString(), level: "warn", msg, ...extra })),
  error: (msg: string, extra?: Record<string, unknown>) =>
    console.error(JSON.stringify({ t: new Date().toISOString(), level: "error", msg, ...extra }))
};

let running = false;
let shuttingDown = false;
let nextTimer: NodeJS.Timeout | undefined;
let consecutiveFailures = 0;

async function writeHeartbeat(): Promise<void> {
  try {
    await writeFile(env.AGENT_HEARTBEAT_PATH, String(Date.now()), { mode: 0o600 });
  } catch {
    // heartbeat is best-effort; docker healthcheck will flag staleness
  }
}

async function tick(): Promise<void> {
  if (running || shuttingDown) return;
  running = true;
  const start = Date.now();
  try {
    const payload = await collectSnapshot(env.DOCKER_SOCKET_PATH);
    await postReport({
      centralApiUrl: env.CENTRAL_API_URL,
      agentApiKey: env.AGENT_API_KEY,
      serverName: env.SERVER_NAME,
      payload,
      timeoutMs: env.REPORT_HTTP_TIMEOUT_MS
    });
    consecutiveFailures = 0;
    await writeHeartbeat();
    log.info("tick.ok", { ms: Date.now() - start, containers: payload.docker.containers.length });
  } catch (e) {
    consecutiveFailures++;
    const message = e instanceof Error ? e.message : String(e);
    log.error("tick.failed", { ms: Date.now() - start, failures: consecutiveFailures, error: message });
  } finally {
    running = false;
    schedule();
  }
}

function schedule(): void {
  if (shuttingDown) return;
  const baseMs = env.REPORT_INTERVAL_SECONDS * 1000;
  // exponential backoff on consecutive failures, capped at 5 min
  const backoff = consecutiveFailures > 0
    ? Math.min(baseMs * Math.pow(2, Math.min(consecutiveFailures - 1, 5)), 5 * 60 * 1000)
    : baseMs;
  nextTimer = setTimeout(() => { void tick(); }, backoff);
}

function shutdown(signal: string): void {
  if (shuttingDown) return;
  shuttingDown = true;
  log.info("shutdown", { signal });
  if (nextTimer) clearTimeout(nextTimer);
  // give an in-flight tick a short grace period
  const deadline = Date.now() + 5000;
  const waiter = setInterval(() => {
    if (!running || Date.now() >= deadline) {
      clearInterval(waiter);
      process.exit(0);
    }
  }, 100);
}

process.on("SIGTERM", () => shutdown("SIGTERM"));
process.on("SIGINT", () => shutdown("SIGINT"));
process.on("unhandledRejection", (reason) => {
  log.error("unhandledRejection", { error: reason instanceof Error ? reason.message : String(reason) });
});
process.on("uncaughtException", (err) => {
  log.error("uncaughtException", { error: err.message, stack: err.stack });
  shutdown("uncaughtException");
});

log.info("agent.start", {
  name: pkg.name,
  version: pkg.version,
  node: process.version,
  serverName: env.SERVER_NAME,
  centralApiUrl: env.CENTRAL_API_URL,
  intervalSeconds: env.REPORT_INTERVAL_SECONDS,
  dockerSocketPath: env.DOCKER_SOCKET_PATH
});

void tick();
