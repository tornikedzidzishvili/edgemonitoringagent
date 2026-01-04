import "dotenv/config";
import { getEnv } from "./env.js";
import { collectSnapshot } from "./collect.js";
import { postReport } from "./report.js";

const env = getEnv();

async function tick() {
  try {
    const payload = await collectSnapshot(env.DOCKER_SOCKET_PATH);
    await postReport({
      centralApiUrl: env.CENTRAL_API_URL,
      agentApiKey: env.AGENT_API_KEY,
      serverName: env.SERVER_NAME,
      payload
    });
  } catch (e) {
    // eslint-disable-next-line no-console
    console.error("tick failed", e);
  }
}

const intervalMs = env.REPORT_INTERVAL_SECONDS * 1000;

// fire immediately, then interval
void tick();
setInterval(() => {
  void tick();
}, intervalMs);
