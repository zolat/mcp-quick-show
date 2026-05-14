// Persistent per-cwd UUID used as the sidecar's CLAIM in `hello`.
//
// The app is the authority on the granted `session_id` (it inspects
// its per-FD session map at hello time). What this file produces is
// the *candidate* id the sidecar offers: the same one across sidecar
// restarts from the same cwd, which powers single-session reconnect
// in `SessionManager`. The app grants it when no other live FD owns
// it; otherwise the app returns a fresh UUID and the sidecar adopts
// that — see `index.ts` for the adoption flow.

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
 * Returns the candidate `session_id` for this sidecar invocation. The
 * sidecar sends this in `hello`; the app's allocator may grant it as
 * the authoritative id (single-session case) or override it with a
 * fresh UUID (parallel-session contest). Persisted at
 * `~/Library/Application Support/QuickShow/sessions/<cwdHash>.uuid` so
 * the claim stays stable across sidecar restarts from the same cwd.
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
