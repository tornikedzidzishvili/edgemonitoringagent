import { request } from "undici";
import type { AgentPayload } from "./collect.js";

function joinUrl(baseUrl: string, path: string): string {
  const base = baseUrl.endsWith("/") ? baseUrl : `${baseUrl}/`;
  const rel = path.startsWith("/") ? path.slice(1) : path;
  return new URL(rel, base).toString();
}

function redactError(text: string): string {
  // Keep response bodies small and strip anything vaguely secret-looking.
  const truncated = text.length > 500 ? `${text.slice(0, 500)}…` : text;
  return truncated.replace(/([A-Za-z0-9_-]{24,})/g, (m) => `${m.slice(0, 4)}…${m.slice(-4)}`);
}

export async function postReport(params: {
  centralApiUrl: string;
  agentApiKey: string;
  serverName: string;
  payload: AgentPayload;
  timeoutMs?: number;
}): Promise<void> {
  const url = joinUrl(params.centralApiUrl, "agents/report");
  const timeoutMs = params.timeoutMs ?? 15_000;

  const body = JSON.stringify({
    serverName: params.serverName,
    payload: params.payload
  });

  const ac = new AbortController();
  const timer = setTimeout(() => ac.abort(), timeoutMs);

  try {
    const res = await request(url, {
      method: "POST",
      headers: {
        "content-type": "application/json",
        "content-length": String(Buffer.byteLength(body)),
        "x-agent-key": params.agentApiKey,
        "user-agent": "edgemonitoringagent"
      },
      body,
      signal: ac.signal,
      headersTimeout: timeoutMs,
      bodyTimeout: timeoutMs
    });

    const text = await res.body.text().catch(() => "");
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw new Error(`Central API ${res.statusCode}: ${redactError(text)}`);
    }
  } finally {
    clearTimeout(timer);
  }
}
