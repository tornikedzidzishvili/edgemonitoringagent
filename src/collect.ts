import Docker, { type ContainerInfo } from "dockerode";
import * as si from "systeminformation";

export type AgentPayload = {
  collectedAt: string;
  system: {
    hostname: string;
    os: {
      platform: string;
      distro?: string;
      release?: string;
      arch: string;
    };
    processesTop?: Array<{
      pid: number;
      name: string;
      cpuPercent?: number;
      memPercent?: number;
    }>;
    cpu: {
      load: number;
    };
    mem: {
      total: number;
      used: number;
      free: number;
    };
    disk: Array<{ fs: string; size: number; used: number; available: number; mount: string }>;
  };
  docker: {
    containers: Array<{
      id: string;
      name: string;
      image: string;
      state?: string;
      status?: string;
      created?: number;
      ports?: string[];
    }>;
    stats?: Array<{
      id: string;
      name: string;
      cpuPercent?: number;
      memUsageBytes?: number;
      memLimitBytes?: number;
      memPercent?: number;
      netRxBytes?: number;
      netTxBytes?: number;
      blockReadBytes?: number;
      blockWriteBytes?: number;
    }>;
    error?: string;
  };
};

type DockerStats = any;

function safeNumber(v: unknown): number | undefined {
  return typeof v === "number" && Number.isFinite(v) ? v : undefined;
}

function safeInt(v: unknown): number | undefined {
  const n = safeNumber(v);
  if (n === undefined) return undefined;
  const i = Math.trunc(n);
  return Number.isFinite(i) ? i : undefined;
}

function computeCpuPercent(stats: DockerStats): number | undefined {
  const cpuTotal = safeNumber(stats?.cpu_stats?.cpu_usage?.total_usage);
  const preCpuTotal = safeNumber(stats?.precpu_stats?.cpu_usage?.total_usage);
  const sys = safeNumber(stats?.cpu_stats?.system_cpu_usage);
  const preSys = safeNumber(stats?.precpu_stats?.system_cpu_usage);
  if (cpuTotal === undefined || preCpuTotal === undefined || sys === undefined || preSys === undefined) return undefined;

  const cpuDelta = cpuTotal - preCpuTotal;
  const sysDelta = sys - preSys;
  if (cpuDelta <= 0 || sysDelta <= 0) return 0;

  const onlineCpus =
    safeNumber(stats?.cpu_stats?.online_cpus) ??
    (Array.isArray(stats?.cpu_stats?.cpu_usage?.percpu_usage) ? stats.cpu_stats.cpu_usage.percpu_usage.length : undefined) ??
    1;

  const pct = (cpuDelta / sysDelta) * onlineCpus * 100;
  return Number.isFinite(pct) ? pct : undefined;
}

function computeMem(stats: DockerStats): { usage?: number; limit?: number; percent?: number } {
  const usage = safeNumber(stats?.memory_stats?.usage);
  const limit = safeNumber(stats?.memory_stats?.limit);
  if (usage === undefined || limit === undefined || limit <= 0) return { usage, limit };
  const percent = (usage / limit) * 100;
  return { usage, limit, percent: Number.isFinite(percent) ? percent : undefined };
}

function computeNet(stats: DockerStats): { rx?: number; tx?: number } {
  const networks = stats?.networks;
  if (!networks || typeof networks !== "object") return {};
  let rx = 0;
  let tx = 0;
  for (const v of Object.values(networks)) {
    const r = safeNumber((v as any)?.rx_bytes);
    const t = safeNumber((v as any)?.tx_bytes);
    if (r !== undefined) rx += r;
    if (t !== undefined) tx += t;
  }
  return { rx, tx };
}

function computeBlock(stats: DockerStats): { read?: number; write?: number } {
  const rows = stats?.blkio_stats?.io_service_bytes_recursive;
  if (!Array.isArray(rows)) return {};
  let read = 0;
  let write = 0;
  for (const r of rows) {
    const op = typeof r?.op === "string" ? r.op.toLowerCase() : "";
    const value = safeNumber(r?.value);
    if (value === undefined) continue;
    if (op === "read") read += value;
    if (op === "write") write += value;
  }
  return { read, write };
}

export async function collectSnapshot(dockerSocketPath: string): Promise<AgentPayload> {
  const [osInfo, currentLoad, mem, fsSize] = await Promise.all([
    si.osInfo(),
    si.currentLoad(),
    si.mem(),
    si.fsSize()
  ]);

  let processesTop: AgentPayload["system"]["processesTop"] = undefined;
  try {
    const procs = await si.processes();
    const list = Array.isArray((procs as any)?.list) ? ((procs as any).list as any[]) : [];
    processesTop = list
      .map((p) => {
        const pid = safeInt(p?.pid);
        const name = typeof p?.name === "string" ? p.name : "";
        if (pid === undefined || name.length === 0) return undefined;
        return {
          pid,
          name,
          cpuPercent: safeNumber(p?.cpu),
          memPercent: safeNumber(p?.mem)
        };
      })
      .filter((v): v is NonNullable<typeof v> => Boolean(v))
      .sort((a, b) => {
        const cpuA = a.cpuPercent ?? 0;
        const cpuB = b.cpuPercent ?? 0;
        if (cpuB !== cpuA) return cpuB - cpuA;
        const memA = a.memPercent ?? 0;
        const memB = b.memPercent ?? 0;
        return memB - memA;
      })
      .slice(0, 5);
  } catch {
    processesTop = undefined;
  }

  const docker = new Docker({ socketPath: dockerSocketPath });
  let containers: AgentPayload["docker"]["containers"] = [];
  let dockerError: string | undefined;

  try {
    const dockerContainers = (await docker.listContainers({ all: true })) as ContainerInfo[];
    containers = dockerContainers.map((c) => ({
      id: c.Id,
      name: Array.isArray(c.Names) && c.Names.length ? c.Names[0].replace(/^\//, "") : c.Id.slice(0, 12),
      image: c.Image,
      state: c.State,
      status: c.Status,
      created: c.Created,
      ports: (c.Ports ?? []).map((p) => {
        const hp = p.PublicPort ? `${p.IP ?? "0.0.0.0"}:${p.PublicPort}` : "";
        const cp = `${p.PrivatePort}/${p.Type}`;
        return hp ? `${hp} -> ${cp}` : cp;
      })
    }));
  } catch (e) {
    dockerError = e instanceof Error ? e.message : "docker-list-failed";
  }

  let dockerStats: AgentPayload["docker"]["stats"] = undefined;
  if (containers.length > 0) {
    try {
      dockerStats = await Promise.all(
        containers.map(async (c) => {
          try {
            const s = await docker.getContainer(c.id).stats({ stream: false });
            const cpuPercent = computeCpuPercent(s);
            const mem = computeMem(s);
            const net = computeNet(s);
            const blk = computeBlock(s);
            return {
              id: c.id,
              name: c.name,
              cpuPercent,
              memUsageBytes: mem.usage,
              memLimitBytes: mem.limit,
              memPercent: mem.percent,
              netRxBytes: net.rx,
              netTxBytes: net.tx,
              blockReadBytes: blk.read,
              blockWriteBytes: blk.write
            };
          } catch (e) {
            return { id: c.id, name: c.name };
          }
        })
      );
    } catch (e) {
      const statsError = e instanceof Error ? e.message : "docker-stats-failed";
      dockerError = dockerError ? `${dockerError}; ${statsError}` : statsError;
    }
  }

  return {
    collectedAt: new Date().toISOString(),
    system: {
      hostname: osInfo.hostname ?? "",
      os: {
        platform: osInfo.platform,
        distro: osInfo.distro,
        release: osInfo.release,
        arch: osInfo.arch
      },
      processesTop,
      cpu: {
        load: currentLoad.currentLoad
      },
      mem: {
        total: mem.total,
        used: mem.used,
        free: mem.free
      },
      disk: fsSize.map((d: si.Systeminformation.FsSizeData) => ({
        fs: d.fs,
        size: d.size,
        used: d.used,
        available: d.available,
        mount: d.mount
      }))
    },
    docker: {
      containers,
      stats: dockerStats,
      error: dockerError
    }
  };
}
