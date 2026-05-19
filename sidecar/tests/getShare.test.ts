// Round-trip unit test for the `get_share` raw MCP tool.
//
// The tool talks to the app over the control socket to claim the
// share, then reads the PNG out of the session's artifacts dir.
// Both halves are stubbed here: a fake `SocketClient` returns canned
// `claim_share` responses, and the PNG is pre-staged on disk to
// simulate what `claim_share` would have done after a successful
// migration.

import { test, expect, beforeAll, afterAll, beforeEach } from "bun:test";
import * as fs from "node:fs";
import * as path from "node:path";
import * as os from "node:os";

import { findRawHandler } from "../src/handlers/registry.ts";
import "../src/handlers/getShare.ts";
import { markupArtifactsDir, ensureMarkupDirs, markupArtifactPath } from "../src/session.ts";
import type { SocketClient } from "../src/socket.ts";
import type { ControlRequest, ControlResponse, ClaimShareResult } from "../src/protocol.ts";

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

const SESSION_ID = "get-share-test";
const VALID_SHARE_ID = "abcdef012345";

let tmpEventsRoot: string;
let savedEventsDir: string | undefined;

beforeAll(() => {
  tmpEventsRoot = fs.mkdtempSync(path.join(os.tmpdir(), "qs-getshare-"));
  savedEventsDir = process.env.QUICKSHOW_EVENTS_DIR;
  process.env.QUICKSHOW_EVENTS_DIR = tmpEventsRoot;
  ensureMarkupDirs(SESSION_ID);
});

afterAll(() => {
  if (savedEventsDir === undefined) delete process.env.QUICKSHOW_EVENTS_DIR;
  else process.env.QUICKSHOW_EVENTS_DIR = savedEventsDir;
  fs.rmSync(tmpEventsRoot, { recursive: true, force: true });
});

beforeEach(() => {
  // Fresh artifacts dir + no .consumed/ between tests.
  fs.rmSync(markupArtifactsDir(SESSION_ID), { recursive: true, force: true });
  ensureMarkupDirs(SESSION_ID);
});

type RequestSpy = (req: Omit<ControlRequest, "id"> & { id?: string }) => Promise<ControlResponse>;

function fakeClient(handler: RequestSpy): SocketClient {
  return { request: handler } as unknown as SocketClient;
}

test("get_share: rejects malformed share id", async () => {
  const h = findRawHandler("get_share")!;
  const client = fakeClient(async () => {
    throw new Error("should not have hit the socket");
  });
  const r = await h.call({ id: "../etc/passwd" },
                         { client, sessionId: SESSION_ID });
  expect(r.isError).toBe(true);
});

test("get_share: rejects wrong-length share id", async () => {
  const h = findRawHandler("get_share")!;
  const client = fakeClient(async () => {
    throw new Error("should not have hit the socket");
  });
  const r = await h.call({ id: "abc" },
                         { client, sessionId: SESSION_ID });
  expect(r.isError).toBe(true);
});

test("get_share: happy path — claims share + returns PNG + moves to .consumed", async () => {
  // Pre-stage the PNG where `claim_share` would have left it.
  fs.writeFileSync(markupArtifactPath(SESSION_ID, VALID_SHARE_ID), TINY_PNG);

  const okResp: ControlResponse = {
    kind: "ok",
    result: {
      panel_name: "user-url-zzzzzz",
      content_type: "url",
    } as ClaimShareResult,
  };
  let claimRequests = 0;
  const client = fakeClient(async (req) => {
    expect(req.kind).toBe("claim_share");
    if (req.kind === "claim_share") {
      expect(req.share_id).toBe(VALID_SHARE_ID);
      expect(req.session).toBe(SESSION_ID);
    }
    claimRequests += 1;
    return okResp;
  });

  const h = findRawHandler("get_share")!;
  const r = await h.call({ id: VALID_SHARE_ID },
                         { client, sessionId: SESSION_ID });
  expect(r.isError).toBeFalsy();
  expect(claimRequests).toBe(1);
  const image = (r.content as Array<{ type: string; data?: string; mimeType?: string; text?: string }>)
    .find(c => c.type === "image");
  expect(image).toBeDefined();
  expect(image!.mimeType).toBe("image/png");
  const text = (r.content as Array<{ type: string; text?: string }>)
    .find(c => c.type === "text")?.text ?? "";
  expect(text).toContain("user-url-zzzzzz");
  expect(text).toContain("url");
  // Live path gone, .consumed has it.
  expect(fs.existsSync(markupArtifactPath(SESSION_ID, VALID_SHARE_ID))).toBe(false);
  const consumed = path.join(markupArtifactsDir(SESSION_ID), ".consumed", `${VALID_SHARE_ID}.png`);
  expect(fs.existsSync(consumed)).toBe(true);
});

test("get_share: second fetch from same session falls back to .consumed wording", async () => {
  // Pre-stage as if a previous successful claim had moved the PNG to
  // .consumed/.
  const consumedDir = path.join(markupArtifactsDir(SESSION_ID), ".consumed");
  fs.mkdirSync(consumedDir, { recursive: true });
  fs.writeFileSync(path.join(consumedDir, `${VALID_SHARE_ID}.png`), TINY_PNG);

  const client = fakeClient(async () => ({
    kind: "protocol_error",
    error: "share 'abcdef012345' not found (already claimed or never existed)",
  }) as ControlResponse);

  const h = findRawHandler("get_share")!;
  const r = await h.call({ id: VALID_SHARE_ID },
                         { client, sessionId: SESSION_ID });
  expect(r.isError).toBe(true);
  const text = (r.content as Array<{ type: string; text?: string }>)
    .find(c => c.type === "text")?.text ?? "";
  expect(text).toContain("already consumed");
});

test("get_share: share unknown to the app + no .consumed/ → not found", async () => {
  const client = fakeClient(async () => ({
    kind: "protocol_error",
    error: "share 'abcdef012345' not found",
  }) as ControlResponse);

  const h = findRawHandler("get_share")!;
  const r = await h.call({ id: VALID_SHARE_ID },
                         { client, sessionId: SESSION_ID });
  expect(r.isError).toBe(true);
  const text = (r.content as Array<{ type: string; text?: string }>)
    .find(c => c.type === "text")?.text ?? "";
  expect(text).toContain("not available");
});
