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
