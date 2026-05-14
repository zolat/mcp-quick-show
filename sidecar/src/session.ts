// Resolution of the sidecar's `session_id` CLAIM sent in `hello`.
//
// Primary source: the Claude Code conversation UUID, discovered by
// finding the most recently mtimed JSONL file under
// `~/.claude/projects/<cwd-encoded>/`. This is THE actual identity
// of a Claude session — stable across sidecar respawn and
// `claude --resume`, distinct between parallel Claudes — so every
// load-bearing property we need just falls out for free.
//
// Reference implementation: `~/projects/substant/mcp-plugin/server.ts`
// (`discoverCCSessionId`, lines 54–227). Ported here near-verbatim.
//
// Fallback chain (in order):
//   1. `QUICKSHOW_SESSION_ID` env override (tests, explicit pinning).
//   2. Conversation-UUID discovery, with a 3 s / 200 ms retry loop
//      because Claude writes the JSONL ~2 s AFTER spawning the MCP
//      server — eager lookup at module load always misses.
//   3. Per-cwd persisted UUID (`getOrCreateSessionId`, used by CLI
//      smokes not invoked under Claude).
//
// The app's allocator (`ControlServer.allocateSessionId`) still has
// the live-FD contest check as belt-and-braces, but with
// conversation-UUID claims contest is effectively impossible.

import * as fs from "node:fs";
import * as path from "node:path";
import * as crypto from "node:crypto";
import * as os from "node:os";
import { spawnSync } from "node:child_process";

const SESSIONS_DIR = path.join(
  os.homedir(),
  "Library/Application Support/QuickShow/sessions",
);

/// Mirror of `MarkupPaths` on the Swift side. Both sides derive the
/// same on-disk layout from `sessionId` (and an optional
/// `QUICKSHOW_EVENTS_DIR` override) so we don't have to negotiate paths
/// over the control protocol.
function markupBaseDir(): string {
  const override = process.env.QUICKSHOW_EVENTS_DIR;
  if (override && override.length > 0) return override;
  return path.join(os.homedir(), "Library/Caches/QuickShow/events");
}

export function markupSessionDir(sessionId: string): string {
  return path.join(markupBaseDir(), sessionId);
}

export function markupEventsLog(sessionId: string): string {
  return path.join(markupSessionDir(sessionId), "events.ndjson");
}

export function markupArtifactsDir(sessionId: string): string {
  return path.join(markupSessionDir(sessionId), "artifacts");
}

export function markupArtifactPath(sessionId: string, artifactId: string): string {
  return path.join(markupArtifactsDir(sessionId), `${artifactId}.png`);
}

/** Ensure per-session events + artifacts dirs exist. */
export function ensureMarkupDirs(sessionId: string): void {
  fs.mkdirSync(markupSessionDir(sessionId), { recursive: true, mode: 0o700 });
  fs.mkdirSync(markupArtifactsDir(sessionId), { recursive: true, mode: 0o700 });
}

/// Stable hash of the sidecar's working directory. Used to key the
/// persisted candidate-UUID file so two sidecar runs from the same
/// project propose the same claim. `MCP_CLIENT_ID` and `process.argv0`
/// used to be in this hash too — both were noise (a placeholder env
/// var Claude Code never sets, and a stable executable path) and
/// added zero discrimination, so they're gone.
function cwdHash(): string {
  return crypto.createHash("sha256").update(process.cwd()).digest("hex").slice(0, 16);
}

/**
 * Per-cwd persisted UUID fallback. Stable across runs from the same
 * directory. Used by CLI smokes that aren't invoked under Claude (so
 * conversation-UUID discovery wouldn't apply) and as the final
 * fallback for the main bootstrap when discovery and env override
 * both miss.
 *
 * Persisted at `~/Library/Application Support/QuickShow/sessions/<cwdHash>.uuid`.
 */
export function getOrCreateSessionId(): string {
  const hash = cwdHash();
  const sessionFile = path.join(SESSIONS_DIR, `${hash}.uuid`);
  try {
    const existing = fs.readFileSync(sessionFile, "utf8").trim();
    if (existing) return existing;
  } catch {
    // File doesn't exist — create.
  }
  fs.mkdirSync(SESSIONS_DIR, { recursive: true, mode: 0o700 });
  const id = crypto.randomUUID();
  fs.writeFileSync(sessionFile, id, { mode: 0o600 });
  return id;
}

// ---------- Conversation-UUID discovery (mirrors Substant) ----------

/** Walk the process tree upward (max 10 hops) until we hit a process
 *  whose `ps -o comm=` ends in `claude`. The MCP sidecar's parent
 *  might not be Claude directly (e.g., spawned through a shell wrapper),
 *  so we walk. Returns null if no Claude ancestor is found. */
function findClaudeAncestorPid(): number | null {
  let pid: number | undefined = process.ppid;
  for (let hop = 0; hop < 10; hop++) {
    if (!pid || pid === 1) return null;
    const r = spawnSync("ps", ["-o", "comm=,ppid=", "-p", String(pid)], {
      encoding: "utf8",
    });
    if (r.status !== 0) return null;
    const m = r.stdout.trim().match(/^(\S+)\s+(\d+)$/);
    if (!m) return null;
    const comm = m[1]!;
    const ppid = parseInt(m[2]!, 10);
    // `ps -o comm=` on macOS truncates to argv[0] — `claude` for the
    // binary. Match leaf-component to handle both `/usr/local/bin/claude`
    // and bare `claude` shapes.
    if (/(^|\/)claude$/.test(comm)) return pid;
    pid = ppid;
  }
  return null;
}

/** Return the cwd of `pid` via `lsof`. macOS-friendly; returns null on
 *  any error (process gone, lsof missing, output unparseable). */
function cwdOfPid(pid: number): string | null {
  const r = spawnSync("lsof", ["-a", "-p", String(pid), "-d", "cwd", "-Fn"], {
    encoding: "utf8",
  });
  if (r.status !== 0) return null;
  // `-Fn` outputs lines like `n/Users/zolat/projects/mcp-quick-show`.
  const m = r.stdout.match(/^n(.+)$/m);
  return m ? m[1]! : null;
}

/** Claude encodes cwd `/Users/zolat/projects/mcp-quick-show` into the
 *  project-dir name `-Users-zolat-projects-mcp-quick-show`. */
export function encodeProjectDir(cwd: string): string {
  return "-" + cwd.replace(/^\//, "").replace(/\//g, "-");
}

const UUID_RE =
  /^([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\.jsonl$/;
const DISCOVERY_WINDOW_MS = 5_000;

/** Find the JSONL file in `projectDirs` with mtime closest to `now`,
 *  within `windowMs`. Pure for testability — fixture-friendly. */
export function pickConversationUuid(
  projectDirs: readonly string[],
  now: number,
  windowMs: number = DISCOVERY_WINDOW_MS,
): string | null {
  type Cand = { uuid: string; mtime: number };
  const candidates: Cand[] = [];
  for (const dir of projectDirs) {
    let entries: fs.Dirent[];
    try {
      entries = fs.readdirSync(dir, { withFileTypes: true });
    } catch {
      continue;
    }
    for (const e of entries) {
      if (!e.isFile()) continue;
      const m = e.name.match(UUID_RE);
      if (!m) continue;
      let mtime: number;
      try {
        mtime = fs.statSync(path.join(dir, e.name)).mtimeMs;
      } catch {
        continue;
      }
      if (Math.abs(now - mtime) <= windowMs) {
        candidates.push({ uuid: m[1]!, mtime });
      }
    }
  }
  if (candidates.length === 0) return null;
  candidates.sort((a, b) => Math.abs(now - a.mtime) - Math.abs(now - b.mtime));
  if (candidates.length > 1) {
    console.error(
      `[mcp-quick-show] multiple jsonl candidates within session-discovery window — picked ${candidates[0]!.uuid}; others: ${candidates.slice(1).map((c) => c.uuid).join(",")}`,
    );
  }
  return candidates[0]!.uuid;
}

/** One discovery attempt. Returns the conversation UUID or null.
 *  Anchors to the Claude ancestor's cwd when discoverable; falls back
 *  to scanning every project dir otherwise. */
export function discoverConversationId(): string | null {
  try {
    const claudePid = findClaudeAncestorPid();
    const claudeCwd = claudePid != null ? cwdOfPid(claudePid) : null;
    const projectsRoot = path.join(os.homedir(), ".claude", "projects");
    const projectDirs = claudeCwd
      ? [path.join(projectsRoot, encodeProjectDir(claudeCwd))]
      : (() => {
          try {
            return fs
              .readdirSync(projectsRoot, { withFileTypes: true })
              .filter((e) => e.isDirectory())
              .map((e) => path.join(projectsRoot, e.name));
          } catch {
            return [];
          }
        })();
    if (!claudeCwd) {
      console.error(
        "[mcp-quick-show] session-discovery: parent-cwd lookup failed — scanning all project dirs",
      );
    }
    return pickConversationUuid(projectDirs, Date.now());
  } catch {
    return null;
  }
}

/**
 * Resolve the sidecar's session_id CLAIM with lazy retry. Resolution
 * is async because Claude writes the JSONL ~2 s after spawning the
 * MCP server — eager discovery at module load misses every time.
 *
 * Precedence: env override → JSONL discovery (3 s / 200 ms retry) →
 * `getOrCreateSessionId()` persisted-per-cwd fallback.
 *
 * Returns `{ id, source }` so the caller can log which path fired.
 */
export type SessionIdSource =
  | "env-override"
  | "cc-jsonl-discovery"
  | "cwd-persisted-fallback";

export async function resolveSessionId(): Promise<{
  id: string;
  source: SessionIdSource;
}> {
  const env = process.env.QUICKSHOW_SESSION_ID;
  if (env && env.length > 0) {
    return { id: env, source: "env-override" };
  }
  const startedAt = Date.now();
  while (Date.now() - startedAt < 3_000) {
    const found = discoverConversationId();
    if (found) return { id: found, source: "cc-jsonl-discovery" };
    await new Promise((r) => setTimeout(r, 200));
  }
  return { id: getOrCreateSessionId(), source: "cwd-persisted-fallback" };
}
