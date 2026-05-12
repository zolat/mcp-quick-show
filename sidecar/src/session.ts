// Persistent session UUID per MCP-server-config-hash.
//
// Why hash the config: different Claude Code projects launch the
// sidecar with different cwds / env, and we want each to look like a
// different "session" to the app. Same project across restarts maps to
// the same UUID — that's what powers the reconnect-within-window
// behavior in Phase 4.

import * as fs from "node:fs";
import * as path from "node:path";
import * as crypto from "node:crypto";
import * as os from "node:os";

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

/** Compute a stable hash from the sidecar's invocation context. */
function configHash(): string {
  const parts = [process.cwd(), process.env.MCP_CLIENT_ID ?? "", process.argv0 ?? ""];
  return crypto.createHash("sha256").update(parts.join("|")).digest("hex").slice(0, 16);
}

/**
 * Returns a stable UUID for this sidecar invocation context. Persists
 * to `~/Library/Application Support/QuickShow/sessions/<hash>.uuid`
 * so reconnects within the same cwd reattach to the same HUD.
 */
export function getOrCreateSessionId(): string {
  const hash = configHash();
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
