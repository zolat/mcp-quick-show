// Unit tests for the markup push-channel: path helpers, the
// enable_markup_events handler, and the get_markup handler.
//
// Uses a $TMPDIR-rooted QUICKSHOW_EVENTS_DIR so the test never touches
// the user's real ~/Library/Caches/QuickShow tree.

import { test, expect, beforeEach, afterEach } from "bun:test";
import * as fs from "node:fs";
import * as path from "node:path";
import * as os from "node:os";

let tmpRoot = "";

beforeEach(() => {
  tmpRoot = fs.mkdtempSync(path.join(os.tmpdir(), "quickshow-markup-test-"));
  process.env.QUICKSHOW_EVENTS_DIR = tmpRoot;
});

afterEach(() => {
  delete process.env.QUICKSHOW_EVENTS_DIR;
  fs.rmSync(tmpRoot, { recursive: true, force: true });
});

test("markup paths derive from sessionId under QUICKSHOW_EVENTS_DIR", async () => {
  const {
    markupEventsLog,
    markupArtifactPath,
    markupArtifactsDir,
    markupSessionDir,
  } = await import("../src/session.ts");
  const session = "test-sess-A";
  expect(markupSessionDir(session)).toBe(path.join(tmpRoot, session));
  expect(markupEventsLog(session)).toBe(path.join(tmpRoot, session, "events.ndjson"));
  expect(markupArtifactsDir(session)).toBe(path.join(tmpRoot, session, "artifacts"));
  expect(markupArtifactPath(session, "abc")).toBe(path.join(tmpRoot, session, "artifacts", "abc.png"));
});

test("ensureMarkupDirs creates session + artifacts dirs", async () => {
  const { ensureMarkupDirs, markupArtifactsDir, markupSessionDir } = await import("../src/session.ts");
  const session = "test-sess-B";
  ensureMarkupDirs(session);
  expect(fs.existsSync(markupSessionDir(session))).toBe(true);
  expect(fs.existsSync(markupArtifactsDir(session))).toBe(true);
});

test("enable_markup_events: issues set_session_flag, returns Monitor instructions", async () => {
  // Stub SocketClient — captures the request, returns ok.
  await import("../src/handlers/enableMarkupEvents.ts");
  const { findRawHandler } = await import("../src/handlers/registry.ts");
  const h = findRawHandler("enable_markup_events")!;
  expect(h).toBeDefined();

  let captured: unknown = null;
  const stubClient = {
    request: async (req: unknown) => {
      captured = req;
      return { kind: "ok", id: "x", result: {} };
    },
  } as any;

  const result = await h.call({}, { client: stubClient, sessionId: "test-sess-C" });
  expect(result.isError).toBeUndefined();
  const text = (result.content[0] as { text: string }).text;
  expect(text).toContain("Markup events armed");
  expect(text).toContain("tail -n 0 -F");
  expect(text).toContain("test-sess-C/events.ndjson");
  expect(text).toContain("get_markup");
  expect(captured).toMatchObject({
    kind: "set_session_flag",
    session: "test-sess-C",
    key: "markup_events_armed",
    value: true,
  });
});

test("enable_markup_events: surfaces set_session_flag rejection as isError", async () => {
  await import("../src/handlers/enableMarkupEvents.ts");
  const { findRawHandler } = await import("../src/handlers/registry.ts");
  const h = findRawHandler("enable_markup_events")!;
  const stubClient = {
    request: async () => ({ kind: "protocol_error", id: "x", error: "boom" }),
  } as any;
  const result = await h.call({}, { client: stubClient, sessionId: "test-sess-D" });
  expect(result.isError).toBe(true);
  const text = (result.content[0] as { text: string }).text;
  expect(text).toContain("boom");
});

test("get_markup: rejects ids that aren't UUID-shaped", async () => {
  await import("../src/handlers/getMarkup.ts");
  const { findRawHandler } = await import("../src/handlers/registry.ts");
  const h = findRawHandler("get_markup")!;
  const result = await h.call(
    { artifact_id: "../../etc/passwd" },
    { client: {} as any, sessionId: "x" },
  );
  expect(result.isError).toBe(true);
  expect((result.content[0] as { text: string }).text).toContain("invalid artifact_id");
});

test("get_markup: returns the PNG and moves the file to .consumed", async () => {
  await import("../src/handlers/getMarkup.ts");
  const { findRawHandler } = await import("../src/handlers/registry.ts");
  const { ensureMarkupDirs, markupArtifactPath, markupArtifactsDir } = await import("../src/session.ts");
  const h = findRawHandler("get_markup")!;

  const session = "test-sess-E";
  const artifactId = "550e8400-e29b-41d4-a716-446655440000";
  ensureMarkupDirs(session);
  const pngBytes = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]); // PNG magic
  fs.writeFileSync(markupArtifactPath(session, artifactId), pngBytes);

  const result = await h.call(
    { artifact_id: artifactId },
    { client: {} as any, sessionId: session },
  );
  expect(result.isError).toBeUndefined();
  expect(result.content.length).toBe(2);
  expect((result.content[0] as { type: string }).type).toBe("text");
  const img = result.content[1] as { type: string; data: string; mimeType: string };
  expect(img.type).toBe("image");
  expect(img.mimeType).toBe("image/png");
  expect(Buffer.from(img.data, "base64").equals(pngBytes)).toBe(true);

  // Original gone, consumed copy present.
  expect(fs.existsSync(markupArtifactPath(session, artifactId))).toBe(false);
  expect(fs.existsSync(path.join(markupArtifactsDir(session), ".consumed", `${artifactId}.png`))).toBe(true);
});

test("get_markup: returns 'already consumed' on second call", async () => {
  await import("../src/handlers/getMarkup.ts");
  const { findRawHandler } = await import("../src/handlers/registry.ts");
  const { ensureMarkupDirs, markupArtifactPath } = await import("../src/session.ts");
  const h = findRawHandler("get_markup")!;

  const session = "test-sess-F";
  const artifactId = "ffffffff-ffff-ffff-ffff-ffffffffffff";
  ensureMarkupDirs(session);
  fs.writeFileSync(markupArtifactPath(session, artifactId), Buffer.from([0x89]));

  const ctx = { client: {} as any, sessionId: session };
  await h.call({ artifact_id: artifactId }, ctx);
  const second = await h.call({ artifact_id: artifactId }, ctx);
  expect(second.isError).toBe(true);
  expect((second.content[0] as { text: string }).text).toContain("already consumed");
});

test("get_markup: 404 when artifact never existed", async () => {
  await import("../src/handlers/getMarkup.ts");
  const { findRawHandler } = await import("../src/handlers/registry.ts");
  const h = findRawHandler("get_markup")!;
  const result = await h.call(
    { artifact_id: "deadbeef-dead-beef-dead-beefdeadbeef" },
    { client: {} as any, sessionId: "test-sess-G" },
  );
  expect(result.isError).toBe(true);
  expect((result.content[0] as { text: string }).text).toContain("no artifact");
});
