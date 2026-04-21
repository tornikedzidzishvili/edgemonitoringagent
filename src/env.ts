import { z } from "zod";

const envSchema = z.object({
  CENTRAL_API_URL: z.string().trim().url(),
  SERVER_NAME: z.string().trim().min(1).max(200),
  AGENT_API_KEY: z.string().trim().min(16, "AGENT_API_KEY must be at least 16 characters"),
  REPORT_INTERVAL_SECONDS: z.coerce.number().int().min(5).max(3600).default(30),
  REPORT_HTTP_TIMEOUT_MS: z.coerce.number().int().min(1000).max(60_000).default(15_000),
  DOCKER_SOCKET_PATH: z.string().trim().min(1).default("/var/run/docker.sock"),
  AGENT_HEARTBEAT_PATH: z.string().trim().min(1).default("/tmp/agent-heartbeat")
});

export type AgentEnv = z.infer<typeof envSchema>;

export function getEnv(): AgentEnv {
  const parsed = envSchema.safeParse(process.env);
  if (!parsed.success) {
    const issues = parsed.error.flatten().fieldErrors;
    const keys = Object.keys(issues).join(", ");
    console.error(JSON.stringify({ level: "error", msg: "env.invalid", fields: issues }));
    throw new Error(`Invalid environment variables for agent: ${keys}`);
  }
  if (!/^https?:\/\//i.test(parsed.data.CENTRAL_API_URL)) {
    throw new Error("CENTRAL_API_URL must use http or https");
  }
  return parsed.data;
}
