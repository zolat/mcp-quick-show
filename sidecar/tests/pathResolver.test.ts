// PathResolver unit tests — magic-byte MIME sniffing + size caps +
// tilde expansion.

import { test, expect } from "bun:test";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import { resolveAbsolute, resolvePath, sniffMime, PathResolverError } from "../src/pathResolver.ts";

function tmpfile(name: string, bytes: Buffer): string {
  const p = path.join(os.tmpdir(), `qs-test-${process.pid}-${name}`);
  fs.writeFileSync(p, bytes);
  return p;
}

test("resolveAbsolute expands ~ to $HOME", () => {
  const out = resolveAbsolute("~/foo.txt");
  expect(out).toBe(path.join(os.homedir(), "foo.txt"));
});

test("resolveAbsolute resolves relative against cwd", () => {
  const out = resolveAbsolute("foo.txt");
  expect(path.isAbsolute(out)).toBe(true);
});

test("sniffMime detects PNG magic bytes", async () => {
  const png = tmpfile("test.png", Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0,0,0,0,0,0,0,0]));
  expect(await sniffMime(png)).toBe("image/png");
  fs.unlinkSync(png);
});

test("sniffMime detects JPEG magic bytes", async () => {
  const jpg = tmpfile("test.jpg", Buffer.from([0xff, 0xd8, 0xff, 0xe0, 0,0,0,0,0,0,0,0,0,0,0,0]));
  expect(await sniffMime(jpg)).toBe("image/jpeg");
  fs.unlinkSync(jpg);
});

test("sniffMime detects GIF magic bytes", async () => {
  const gif = tmpfile("test.gif", Buffer.from([0x47, 0x49, 0x46, 0x38, 0,0,0,0,0,0,0,0,0,0,0,0]));
  expect(await sniffMime(gif)).toBe("image/gif");
  fs.unlinkSync(gif);
});

test("sniffMime falls back to text/plain for unknown content", async () => {
  const txt = tmpfile("test.txt", Buffer.from("hello world this is text\n"));
  expect(await sniffMime(txt)).toBe("text/plain");
  fs.unlinkSync(txt);
});

test("resolvePath enforces size cap", async () => {
  const big = tmpfile("test-big.txt", Buffer.alloc(1024));
  let err: PathResolverError | null = null;
  try {
    await resolvePath(big, { maxBytes: 100 });
  } catch (e) {
    err = e as PathResolverError;
  }
  expect(err).not.toBeNull();
  expect(err!.message).toContain("too large");
  fs.unlinkSync(big);
});

test("resolvePath errors on missing file", async () => {
  let err: Error | null = null;
  try {
    await resolvePath("/tmp/qs-this-does-not-exist.txt", { maxBytes: 1024 });
  } catch (e) {
    err = e as Error;
  }
  expect(err).not.toBeNull();
  expect(err!.message).toContain("not found");
});

test("resolvePath enforces allowedMimes", async () => {
  // A text file passed to an image-only handler should reject.
  const txt = tmpfile("test.txt", Buffer.from("hello"));
  let err: Error | null = null;
  try {
    await resolvePath(txt, { maxBytes: 1024, allowedMimes: ["image/png", "image/jpeg"] });
  } catch (e) {
    err = e as Error;
  }
  expect(err).not.toBeNull();
  expect(err!.message).toContain("unsupported MIME");
  fs.unlinkSync(txt);
});
