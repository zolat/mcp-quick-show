// Auto-launch QuickShow.app if the control socket isn't reachable.
//
// Resolution strategy: walk up from `process.execPath` looking for the
// enclosing `.app` bundle (when the sidecar is bundled inside
// `QuickShow.app/Contents/Resources/`). If not running from a bundle,
// fall back to checking `/Applications/QuickShow.app` and the
// `QUICKSHOW_APP_PATH` env override.
//
// Phase 0: minimal — if QUICKSHOW_NO_AUTOLAUNCH=1, do nothing. The
// caller can launch the app manually from the dev directory.

import * as fs from "node:fs";
import * as path from "node:path";
import { spawn } from "node:child_process";

/**
 * Walk up `start` looking for a directory ending in `.app`. Returns
 * the bundle path, or null if none found within `maxDepth` levels.
 */
function findEnclosingAppBundle(start: string, maxDepth = 6): string | null {
  let cur = start;
  for (let i = 0; i < maxDepth; i++) {
    cur = path.dirname(cur);
    if (cur === "/" || cur === "") return null;
    if (cur.endsWith(".app")) return cur;
  }
  return null;
}

/** Locate a QuickShow.app bundle to launch. Returns null if not found. */
export function locateAppBundle(): string | null {
  const envOverride = process.env.QUICKSHOW_APP_PATH;
  if (envOverride && fs.existsSync(envOverride)) return envOverride;

  // Bundled-sidecar case: walk up from our own executable.
  const fromExec = findEnclosingAppBundle(process.execPath);
  if (fromExec && fs.existsSync(fromExec)) return fromExec;

  const candidates = [
    "/Applications/QuickShow.app",
    path.join(process.env.HOME ?? "", "Applications/QuickShow.app"),
  ];
  for (const c of candidates) {
    if (fs.existsSync(c)) return c;
  }
  return null;
}

/**
 * `open -g` the bundled .app, then poll for `predicate()` becoming
 * true. Resolves when reachable, rejects on timeout or launch failure.
 */
export async function launchAndWaitFor(
  appPath: string,
  predicate: () => Promise<boolean>,
  opts: { timeoutMs?: number; pollMs?: number } = {},
): Promise<void> {
  const timeoutMs = opts.timeoutMs ?? 5000;
  const pollMs = opts.pollMs ?? 100;

  console.error(`[mcp-quick-show] launching ${appPath}`);
  const child = spawn("open", ["-g", appPath], { stdio: "ignore", detached: true });
  child.unref();

  const start = Date.now();
  while (Date.now() - start < timeoutMs) {
    if (await predicate()) return;
    await new Promise((r) => setTimeout(r, pollMs));
  }
  throw new Error(`QuickShow launched but control socket did not become reachable within ${timeoutMs}ms`);
}
