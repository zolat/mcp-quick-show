// ContentTypeHandler registry + handler validate() unit tests.

import { test, expect } from "bun:test";
import { allHandlers, findHandler, registerHandler } from "../src/handlers/registry.ts";

// Side-effect imports populate the registry.
import "../src/handlers/markdown.ts";
import "../src/handlers/svg.ts";
import "../src/handlers/mermaid.ts";
import "../src/handlers/image.ts";
import "../src/handlers/html.ts";
import "../src/handlers/url.ts";

test("registry lists all upsert content-type tools", () => {
  const names = allHandlers().map(h => h.toolName).sort();
  expect(names).toEqual(["show_html", "show_image", "show_markdown", "show_mermaid", "show_svg", "show_url"]);
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

test("html.validate: requires non-empty content", async () => {
  const h = findHandler("show_html")!;
  const missing = await h.validate({ name: "x" });
  expect(missing.ok).toBe(false);
  const empty = await h.validate({ name: "x", content: "" });
  expect(empty.ok).toBe(false);
});

test("html.validate: requires name", async () => {
  const h = findHandler("show_html")!;
  const r = await h.validate({ content: "<html></html>" });
  expect(r.ok).toBe(false);
});

test("html.validate: accepts a minimal document", async () => {
  const h = findHandler("show_html")!;
  const r = await h.validate({
    name: "design",
    content: "<!doctype html><html><body><h1>hi</h1></body></html>",
  });
  expect(r.ok).toBe(true);
  if (r.ok) {
    expect(r.payload.contentType).toBe("html");
    expect(r.payload.form).toBe("inline");
  }
});

test("html.validate: enforces 10 MB inline cap", async () => {
  const h = findHandler("show_html")!;
  const big = "<html><body>" + "x".repeat(11 * 1024 * 1024) + "</body></html>";
  const r = await h.validate({ name: "x", content: big });
  expect(r.ok).toBe(false);
  if (!r.ok) expect(r.error).toContain("10 MB");
});

test("url.validate: accepts an https URL", async () => {
  const h = findHandler("show_url")!;
  const r = await h.validate({ name: "spec", url: "https://example.com/docs" });
  expect(r.ok).toBe(true);
  if (r.ok) {
    expect(r.payload.contentType).toBe("url");
    expect(r.payload.form).toBe("url");
    expect(r.payload.body).toBe("https://example.com/docs");
  }
});

test("url.validate: accepts an http URL", async () => {
  const h = findHandler("show_url")!;
  const r = await h.validate({ name: "x", url: "http://localhost:3000/" });
  expect(r.ok).toBe(true);
});

test("url.validate: rejects empty name", async () => {
  const h = findHandler("show_url")!;
  const r = await h.validate({ name: "  ", url: "https://example.com" });
  expect(r.ok).toBe(false);
});

test("url.validate: rejects missing url", async () => {
  const h = findHandler("show_url")!;
  const r = await h.validate({ name: "x" });
  expect(r.ok).toBe(false);
});

test("url.validate: rejects file: URLs", async () => {
  const h = findHandler("show_url")!;
  const r = await h.validate({ name: "x", url: "file:///etc/passwd" });
  expect(r.ok).toBe(false);
  if (!r.ok) expect(r.error).toContain("http");
});

test("url.validate: rejects javascript: URLs", async () => {
  const h = findHandler("show_url")!;
  const r = await h.validate({ name: "x", url: "javascript:alert(1)" });
  expect(r.ok).toBe(false);
});

test("url.validate: rejects data: URLs", async () => {
  const h = findHandler("show_url")!;
  const r = await h.validate({ name: "x", url: "data:text/html,hi" });
  expect(r.ok).toBe(false);
});

test("url.validate: rejects malformed URL", async () => {
  const h = findHandler("show_url")!;
  const r = await h.validate({ name: "x", url: "not a url" });
  expect(r.ok).toBe(false);
});

test("url.validate: rejects scheme-less URL", async () => {
  const h = findHandler("show_url")!;
  const r = await h.validate({ name: "x", url: "example.com" });
  expect(r.ok).toBe(false);
});

test("url.validate: enforces width bounds", async () => {
  const h = findHandler("show_url")!;
  const tooNarrow = await h.validate({ name: "x", url: "https://example.com", width: 99 });
  expect(tooNarrow.ok).toBe(false);
  const tooWide = await h.validate({ name: "x", url: "https://example.com", width: 4097 });
  expect(tooWide.ok).toBe(false);
  const ok = await h.validate({ name: "x", url: "https://example.com", width: 800 });
  expect(ok.ok).toBe(true);
  if (ok.ok) expect(ok.payload.width).toBe(800);
});

test("url.validate: return_screenshot=false flows through", async () => {
  const h = findHandler("show_url")!;
  const r = await h.validate({ name: "x", url: "https://example.com", return_screenshot: false });
  expect(r.ok).toBe(true);
  if (r.ok) expect(r.payload.returnScreenshot).toBe(false);
});

// ---------------------------------------------------------------------
// Grouping fields (group / description / hud_description)
// Each is independently optional on every show_* handler. We assert the
// markdown + html handlers as representative inline-content tools and
// the url handler as the "form=url" path — the parsing is shared via
// `_groupingFields.ts`, so coverage of all six is unnecessary.
// ---------------------------------------------------------------------

test("grouping fields: round-trip through markdown.validate", async () => {
  const h = findHandler("show_markdown")!;
  const r = await h.validate({
    name: "tab",
    content: "hi",
    group: "design-review",
    description: "Bold serif.",
    hud_description: "Hero variants.",
  });
  expect(r.ok).toBe(true);
  if (r.ok) {
    expect(r.payload.group).toBe("design-review");
    expect(r.payload.description).toBe("Bold serif.");
    expect(r.payload.hudDescription).toBe("Hero variants.");
  }
});

test("grouping fields: undefined when absent (distinct from empty)", async () => {
  const h = findHandler("show_markdown")!;
  const r = await h.validate({ name: "tab", content: "hi" });
  expect(r.ok).toBe(true);
  if (r.ok) {
    expect(r.payload.group).toBeUndefined();
    expect(r.payload.description).toBeUndefined();
    expect(r.payload.hudDescription).toBeUndefined();
  }
});

test("grouping fields: empty strings round-trip as empty (clear signal)", async () => {
  const h = findHandler("show_html")!;
  const r = await h.validate({
    name: "x",
    content: "<html></html>",
    description: "",
    hud_description: "",
  });
  expect(r.ok).toBe(true);
  if (r.ok) {
    // Empty strings are preserved — the app side reads "" as "clear".
    expect(r.payload.description).toBe("");
    expect(r.payload.hudDescription).toBe("");
  }
});

test("grouping fields: reject non-string types", async () => {
  const h = findHandler("show_markdown")!;
  const r = await h.validate({ name: "x", content: "hi", group: 42 });
  expect(r.ok).toBe(false);
  if (!r.ok) expect(r.error).toContain("`group`");
});

test("grouping fields: reject oversized `description`", async () => {
  const h = findHandler("show_markdown")!;
  const big = "x".repeat(257); // 257 bytes > 256-byte cap
  const r = await h.validate({ name: "x", content: "hi", description: big });
  expect(r.ok).toBe(false);
  if (!r.ok) expect(r.error).toContain("description");
});

test("grouping fields: reject oversized `hud_description`", async () => {
  const h = findHandler("show_markdown")!;
  const big = "x".repeat(4 * 1024 + 1); // 4 KB + 1
  const r = await h.validate({ name: "x", content: "hi", hud_description: big });
  expect(r.ok).toBe(false);
  if (!r.ok) expect(r.error).toContain("hud_description");
});

test("grouping fields: accept `description` at the 256-byte boundary", async () => {
  const h = findHandler("show_html")!;
  const exact = "x".repeat(256);
  const r = await h.validate({
    name: "x",
    content: "<html></html>",
    description: exact,
  });
  expect(r.ok).toBe(true);
  if (r.ok) expect(r.payload.description?.length).toBe(256);
});

test("grouping fields: round-trip through url.validate", async () => {
  const h = findHandler("show_url")!;
  const r = await h.validate({
    name: "spec",
    url: "https://example.com",
    group: "docs",
    description: "API reference.",
  });
  expect(r.ok).toBe(true);
  if (r.ok) {
    expect(r.payload.group).toBe("docs");
    expect(r.payload.description).toBe("API reference.");
    expect(r.payload.hudDescription).toBeUndefined();
  }
});
