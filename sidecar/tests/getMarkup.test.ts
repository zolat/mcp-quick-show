// Round-trip unit test for the `get_markup` raw MCP tool.
//
// Mirrors what Claude does at runtime: the app drops a PNG into
// `<events>/<sessionId>/artifacts/<id>.png`, sets the events log, and
// the tool returns it as an MCP image content block + moves it into
// `.consumed/`. We bypass the socket here — the tool's `call()` only
// touches the filesystem and a `SocketClient` it doesn't use, so we
// can hand it a sentinel context.

import { test, expect, beforeAll, afterAll } from "bun:test";
import * as fs from "node:fs";
import * as path from "node:path";
import * as os from "node:os";

import { findRawHandler } from "../src/handlers/registry.ts";
import "../src/handlers/getMarkup.ts";
import { markupArtifactsDir, ensureMarkupDirs, markupArtifactPath } from "../src/session.ts";
import type { SocketClient } from "../src/socket.ts";

// 1x1 transparent PNG — same constant used by the app smoke.
const TINY_PNG = Buffer.from([
  0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a,
  0x00, 0x00, 0x00, 0x0d, 0x49, 0x48, 0x44, 0x52,
  0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1f, 0x15, 0xc4,
  0x89, 0x00, 0x00, 0x00, 0x0d, 0x49, 0x44, 0x41,
  0x54, 0x78, 0x9c, 0x62, 0x00, 0x01, 0x00, 0x00,
  0x05, 0x00, 0x01, 0x0d, 0x0a, 0x2d, 0xb4, 0x00,
  0x00, 0x00, 0x00, 0x49, 0x45, 0x4e, 0x44, 0xae,
  0x42, 0x60, 0x82,
]);

const SESSION_ID = "get-markup-test";
const VALID_UUID = "550e8400-e29b-41d4-a716-446655440000";

let tmpEventsRoot: string;
let savedEventsDir: string | undefined;

beforeAll(() => {
  tmpEventsRoot = fs.mkdtempSync(path.join(os.tmpdir(), "qs-getmarkup-"));
  savedEventsDir = process.env.QUICKSHOW_EVENTS_DIR;
  process.env.QUICKSHOW_EVENTS_DIR = tmpEventsRoot;
  ensureMarkupDirs(SESSION_ID);
  fs.writeFileSync(markupArtifactPath(SESSION_ID, VALID_UUID), TINY_PNG);
});

afterAll(() => {
  if (savedEventsDir === undefined) delete process.env.QUICKSHOW_EVENTS_DIR;
  else process.env.QUICKSHOW_EVENTS_DIR = savedEventsDir;
  fs.rmSync(tmpEventsRoot, { recursive: true, force: true });
});

// Tool's call() type expects a SocketClient — we don't use it. Cast a
// sentinel so the type system is happy.
const fakeClient = {} as unknown as SocketClient;

test("get_markup: rejects malformed artifact_id", async () => {
  const h = findRawHandler("get_markup")!;
  const r = await h.call({ artifact_id: "../etc/passwd" },
                         { client: fakeClient, sessionId: SESSION_ID });
  expect(r.isError).toBe(true);
});

test("get_markup: returns image content block + moves artifact to .consumed", async () => {
  const h = findRawHandler("get_markup")!;
  const r = await h.call({ artifact_id: VALID_UUID },
                         { client: fakeClient, sessionId: SESSION_ID });
  expect(r.isError).toBeFalsy();
  const image = (r.content as Array<{ type: string; data?: string; mimeType?: string }>)
    .find(c => c.type === "image");
  expect(image).toBeDefined();
  expect(image!.mimeType).toBe("image/png");
  // Decode base64, sanity-check the PNG magic.
  const decoded = Buffer.from(image!.data!, "base64");
  expect(decoded[0]).toBe(0x89);
  expect(decoded[1]).toBe(0x50);
  expect(decoded[2]).toBe(0x4e);
  expect(decoded[3]).toBe(0x47);
  // Live path is gone; .consumed has it.
  expect(fs.existsSync(markupArtifactPath(SESSION_ID, VALID_UUID))).toBe(false);
  const consumed = path.join(markupArtifactsDir(SESSION_ID), ".consumed", `${VALID_UUID}.png`);
  expect(fs.existsSync(consumed)).toBe(true);
});

test("get_markup: second read of the same id reports already-consumed", async () => {
  const h = findRawHandler("get_markup")!;
  const r = await h.call({ artifact_id: VALID_UUID },
                         { client: fakeClient, sessionId: SESSION_ID });
  expect(r.isError).toBe(true);
});

test("get_markup: unknown id returns an error", async () => {
  const h = findRawHandler("get_markup")!;
  const r = await h.call({ artifact_id: "00000000-0000-0000-0000-000000000000" },
                         { client: fakeClient, sessionId: SESSION_ID });
  expect(r.isError).toBe(true);
});
