// Unit tests for the pure parts of conversation-UUID discovery —
// `encodeProjectDir` and `pickConversationUuid`. The full
// discoverConversationId() / resolveSessionId() pipeline depends on
// real `ps` + `lsof` against a real Claude process tree; that's
// exercised by the integration smokes (see verify-* scripts and the
// real-Claude tests).

import { test, expect, beforeEach, afterEach } from "bun:test";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import { encodeProjectDir, pickConversationUuid } from "../src/session.ts";

test("encodeProjectDir mirrors Claude's '-Users-...' naming", () => {
  expect(encodeProjectDir("/Users/zolat/projects/mcp-quick-show")).toBe(
    "-Users-zolat-projects-mcp-quick-show",
  );
  expect(encodeProjectDir("/")).toBe("-");
  expect(encodeProjectDir("/var/folders/hz/x/T/tmp")).toBe(
    "-var-folders-hz-x-T-tmp",
  );
});

let tmpDir: string;
let projectDir: string;

beforeEach(() => {
  tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "qs-discover-"));
  projectDir = path.join(tmpDir, "-fake-project");
  fs.mkdirSync(projectDir, { recursive: true });
});

afterEach(() => {
  fs.rmSync(tmpDir, { recursive: true, force: true });
});

function writeJsonl(name: string, mtimeMs: number): void {
  const p = path.join(projectDir, name);
  fs.writeFileSync(p, "");
  const sec = mtimeMs / 1000;
  fs.utimesSync(p, sec, sec);
}

test("pickConversationUuid returns null when project dir is empty", () => {
  const id = pickConversationUuid([projectDir], Date.now());
  expect(id).toBeNull();
});

test("pickConversationUuid returns null when no jsonl is within the window", () => {
  // Mtime 1 hour ago, well outside the 5 s default window.
  writeJsonl("aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee.jsonl", Date.now() - 3_600_000);
  const id = pickConversationUuid([projectDir], Date.now());
  expect(id).toBeNull();
});

test("pickConversationUuid skips non-UUID filenames", () => {
  writeJsonl("not-a-uuid.jsonl", Date.now() - 500);
  writeJsonl("README.txt", Date.now() - 200);
  const id = pickConversationUuid([projectDir], Date.now());
  expect(id).toBeNull();
});

test("pickConversationUuid returns the only candidate inside the window", () => {
  const uuid = "11111111-2222-3333-4444-555555555555";
  writeJsonl(`${uuid}.jsonl`, Date.now() - 1_500);
  const id = pickConversationUuid([projectDir], Date.now());
  expect(id).toBe(uuid);
});

test("pickConversationUuid picks the closest-mtime candidate when several are in the window", () => {
  // Three candidates within the 5 s window; the middle one is closest
  // to `now`.
  const now = Date.now();
  const oldUuid = "11111111-1111-1111-1111-111111111111";
  const closestUuid = "22222222-2222-2222-2222-222222222222";
  const recentUuid = "33333333-3333-3333-3333-333333333333";
  writeJsonl(`${oldUuid}.jsonl`, now - 4_000);
  writeJsonl(`${closestUuid}.jsonl`, now - 300);
  writeJsonl(`${recentUuid}.jsonl`, now - 2_000);
  const id = pickConversationUuid([projectDir], now);
  expect(id).toBe(closestUuid);
});

test("pickConversationUuid scans multiple project dirs", () => {
  const dirA = path.join(tmpDir, "-A");
  const dirB = path.join(tmpDir, "-B");
  fs.mkdirSync(dirA);
  fs.mkdirSync(dirB);
  const uuidA = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa";
  const uuidB = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb";
  const now = Date.now();
  fs.writeFileSync(path.join(dirA, `${uuidA}.jsonl`), "");
  fs.utimesSync(path.join(dirA, `${uuidA}.jsonl`), (now - 3_000) / 1000, (now - 3_000) / 1000);
  fs.writeFileSync(path.join(dirB, `${uuidB}.jsonl`), "");
  fs.utimesSync(path.join(dirB, `${uuidB}.jsonl`), (now - 500) / 1000, (now - 500) / 1000);
  // uuidB has the closer mtime.
  const id = pickConversationUuid([dirA, dirB], now);
  expect(id).toBe(uuidB);
});

test("pickConversationUuid honours a custom windowMs", () => {
  const uuid = "44444444-5555-6666-7777-888888888888";
  writeJsonl(`${uuid}.jsonl`, Date.now() - 10_000);
  // Default 5 s window excludes it.
  expect(pickConversationUuid([projectDir], Date.now())).toBeNull();
  // Widen to 30 s and it's picked up.
  expect(pickConversationUuid([projectDir], Date.now(), 30_000)).toBe(uuid);
});

test("pickConversationUuid gracefully skips a non-existent dir", () => {
  const missing = path.join(tmpDir, "does-not-exist");
  const uuid = "99999999-aaaa-bbbb-cccc-dddddddddddd";
  writeJsonl(`${uuid}.jsonl`, Date.now() - 500);
  const id = pickConversationUuid([missing, projectDir], Date.now());
  expect(id).toBe(uuid);
});
