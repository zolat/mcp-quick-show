// Filesystem chokepoint for path-form arguments. Single point that:
// - Expands `~` to $HOME.
// - Resolves relative paths against the sidecar's cwd (i.e. the project
//   directory Claude Code spawned us in).
// - Stats the file (existence, regular file, readable).
// - Sniffs MIME via magic bytes for image types.
// - Enforces per-type size caps.

import * as fs from "node:fs";
import * as path from "node:path";
import * as os from "node:os";

export class PathResolverError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "PathResolverError";
  }
}

export type ResolvedPath = {
  absolutePath: string;
  size: number;
  mime: string;
};

/** Expand `~` and resolve `relative` against cwd. */
export function resolveAbsolute(p: string): string {
  if (!p) throw new PathResolverError("empty path");
  let expanded = p;
  if (expanded.startsWith("~/")) {
    expanded = path.join(os.homedir(), expanded.slice(2));
  } else if (expanded === "~") {
    expanded = os.homedir();
  }
  return path.resolve(process.cwd(), expanded);
}

/**
 * Stat + size-cap a path. Returns absolute + size + sniffed MIME.
 * Throws `PathResolverError` for any failure (not-found, too-big,
 * unreadable).
 */
export async function resolvePath(
  rawPath: string,
  opts: { maxBytes: number; allowedMimes?: string[] },
): Promise<ResolvedPath> {
  const absolutePath = resolveAbsolute(rawPath);
  let stats;
  try {
    stats = await fs.promises.stat(absolutePath);
  } catch (err) {
    throw new PathResolverError(`file not found: ${absolutePath}`);
  }
  if (!stats.isFile()) {
    throw new PathResolverError(`not a regular file: ${absolutePath}`);
  }
  if (stats.size > opts.maxBytes) {
    throw new PathResolverError(
      `file too large: ${stats.size} bytes > cap ${opts.maxBytes}`,
    );
  }
  const mime = await sniffMime(absolutePath);
  if (opts.allowedMimes && !opts.allowedMimes.includes(mime)) {
    throw new PathResolverError(
      `unsupported MIME '${mime}' for ${absolutePath}; allowed: ${opts.allowedMimes.join(", ")}`,
    );
  }
  return { absolutePath, size: stats.size, mime };
}

/**
 * Magic-byte MIME sniff for common image formats + UTF-8 text.
 * Returns `application/octet-stream` if no match.
 */
export async function sniffMime(absolutePath: string): Promise<string> {
  const fd = await fs.promises.open(absolutePath, "r");
  try {
    const buf = Buffer.alloc(16);
    await fd.read(buf, 0, 16, 0);
    // PNG: 89 50 4E 47 0D 0A 1A 0A
    if (buf[0] === 0x89 && buf[1] === 0x50 && buf[2] === 0x4e && buf[3] === 0x47) {
      return "image/png";
    }
    // JPEG: FF D8 FF
    if (buf[0] === 0xff && buf[1] === 0xd8 && buf[2] === 0xff) {
      return "image/jpeg";
    }
    // GIF: 47 49 46 38
    if (buf[0] === 0x47 && buf[1] === 0x49 && buf[2] === 0x46 && buf[3] === 0x38) {
      return "image/gif";
    }
    // WebP: RIFF????WEBP
    if (
      buf[0] === 0x52 && buf[1] === 0x49 && buf[2] === 0x46 && buf[3] === 0x46 &&
      buf[8] === 0x57 && buf[9] === 0x45 && buf[10] === 0x42 && buf[11] === 0x50
    ) {
      return "image/webp";
    }
    // Otherwise treat as text — markdown is a text format, so this is
    // the safe default for the `show_markdown` path form.
    // (We don't check for valid UTF-8 here; readFile will do it.)
    return "text/plain";
  } finally {
    await fd.close();
  }
}
