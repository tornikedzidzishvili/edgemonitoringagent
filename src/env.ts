import { z } from "zod";

const envSchema = z.object({
  CENTRAL_API_URL: z.string().trim().url(),
  SERVER_NAME: z.string().trim().min(1),
  AGENT_API_KEY: z.string().trim().min(1),
  REPORT_INTERVAL_SECONDS: z.coerce.number().int().positive().default(30),
  DOCKER_SOCKET_PATH: z.string().trim().min(1).default("/var/run/docker.sock")
});

export type AgentEnv = z.infer<typeof envSchema>;

export function getEnv(): AgentEnv {
  const parsed = envSchema.safeParse(process.env);
  if (!parsed.success) {
    // eslint-disable-next-line no-console
    console.error(parsed.error.flatten().fieldErrors);
    throw new Error("Invalid environment variables for agent");
  }
  return parsed.data;
}
