// ContentTypeHandler registry + handler validate() unit tests.

import { test, expect } from "bun:test";
import { allHandlers, findHandler, registerHandler } from "../src/handlers/registry.ts";

// Side-effect imports populate the registry.
import "../src/handlers/markdown.ts";
import "../src/handlers/svg.ts";
import "../src/handlers/mermaid.ts";
import "../src/handlers/image.ts";

test("registry lists all four v0.1 tools", () => {
  const names = allHandlers().map(h => h.toolName).sort();
  expect(names).toEqual(["show_image", "show_markdown", "show_mermaid", "show_svg"]);
});

test("registry findHandler returns the right tool", () => {
  const h = findHandler("show_markdown");
  expect(h?.toolName).toBe("show_markdown");
});

test("registerHandler is idempotent on toolName", () => {
  const before = allHandlers().length;
  const dup = findHandler("show_markdown")!;
  registerHandler(dup);
  const after = allHandlers().length;
  expect(after).toBe(before);
});

test("markdown.validate: requires content xor path", async () => {
  const h = findHandler("show_markdown")!;

  // Neither provided → error.
  const neither = await h.validate({ name: "x" });
  expect(neither.ok).toBe(false);

  // Both provided → error.
  const both = await h.validate({ name: "x", content: "a", path: "/tmp/foo" });
  expect(both.ok).toBe(false);

  // content alone → ok.
  const contentOnly = await h.validate({ name: "x", content: "hello" });
  expect(contentOnly.ok).toBe(true);
});

test("markdown.validate: enforces 10 MB inline cap", async () => {
  const h = findHandler("show_markdown")!;
  const big = "x".repeat(11 * 1024 * 1024); // 11 MB
  const r = await h.validate({ name: "x", content: big });
  expect(r.ok).toBe(false);
  if (!r.ok) expect(r.error).toContain("10 MB");
});

test("svg.validate: rejects strings without <svg>", async () => {
  const h = findHandler("show_svg")!;
  const r = await h.validate({ name: "x", content: "not an svg" });
  expect(r.ok).toBe(false);
});

test("svg.validate: accepts an inline <svg>", async () => {
  const h = findHandler("show_svg")!;
  const r = await h.validate({ name: "x", content: "<svg></svg>" });
  expect(r.ok).toBe(true);
});

test("mermaid.validate: rejects empty", async () => {
  const h = findHandler("show_mermaid")!;
  const r = await h.validate({ name: "x", definition: "" });
  expect(r.ok).toBe(false);
});

test("mermaid.validate: passes valid-looking diagram", async () => {
  const h = findHandler("show_mermaid")!;
  const r = await h.validate({ name: "x", definition: "flowchart LR\nA-->B" });
  expect(r.ok).toBe(true);
});

test("return_screenshot=false flows through", async () => {
  const h = findHandler("show_markdown")!;
  const r = await h.validate({ name: "x", content: "hi", return_screenshot: false });
  expect(r.ok).toBe(true);
  if (r.ok) expect(r.payload.returnScreenshot).toBe(false);
});

test("return_screenshot defaults to true", async () => {
  const h = findHandler("show_markdown")!;
  const r = await h.validate({ name: "x", content: "hi" });
  if (r.ok) expect(r.payload.returnScreenshot).toBe(true);
});
