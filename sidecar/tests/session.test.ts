// Session UUID store tests.

import { test, expect } from "bun:test";
import * as fs from "node:fs";
import * as path from "node:path";
import * as os from "node:os";
import { getOrCreateSessionId } from "../src/session.ts";

test("getOrCreateSessionId returns a stable UUID for the same config hash", () => {
  // Same invocation context (cwd, env) — should return the same UUID.
  const id1 = getOrCreateSessionId();
  const id2 = getOrCreateSessionId();
  expect(id1).toBe(id2);
});

test("returned value is a UUID", () => {
  const id = getOrCreateSessionId();
  expect(id).toMatch(/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/);
});

test("session file lands under Application Support/QuickShow/sessions", () => {
  const id = getOrCreateSessionId();
  const sessionsDir = path.join(os.homedir(), "Library/Application Support/QuickShow/sessions");
  expect(fs.existsSync(sessionsDir)).toBe(true);
  // At least one .uuid file should exist
  const files = fs.readdirSync(sessionsDir);
  expect(files.some(f => f.endsWith(".uuid"))).toBe(true);
  // The UUID we got should be inside one of them
  const allContents = files.map(f => fs.readFileSync(path.join(sessionsDir, f), "utf8").trim());
  expect(allContents).toContain(id);
});
