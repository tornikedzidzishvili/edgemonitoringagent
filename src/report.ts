import { request } from "undici";
import type { AgentPayload } from "./collect.js";

function joinUrl(baseUrl: string, path: string): string {
  const base = baseUrl.endsWith("/") ? baseUrl : `${baseUrl}/`;
  const rel = path.startsWith("/") ? path.slice(1) : path;
  return new URL(rel, base).toString();
}

export async function postReport(params: {
  centralApiUrl: string;
  agentApiKey: string;
  serverName: string;
  payload: AgentPayload;
}): Promise<void> {
  const url = joinUrl(params.centralApiUrl, "agents/report");

  const res = await request(url, {
    method: "POST",
    headers: {
      "content-type": "application/json",
      "x-agent-key": params.agentApiKey
    },
    body: JSON.stringify({
      serverName: params.serverName,
      payload: params.payload
    })
  });

  if (res.statusCode < 200 || res.statusCode >= 300) {
    const text = await res.body.text().catch(() => "");
    throw new Error(`Central API responded ${res.statusCode}: ${text}`);
  }
}
