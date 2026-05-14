// `enable_panel_events` MCP tool.
//
// Arms the per-session push channel for **panel events** — JS-side
// `window.quickshow.emit(payload)` calls inside `show_html` (or any
// WebView-backed) panels land as `panel_event` NDJSON lines in the
// session's events log. The agent tails the log with `Monitor` and
// reacts to events (clicks, form submissions, custom signals).
//
// Separate from `enable_markup_events`: a session can arm one, the
// other, or both. The events all share `events.ndjson`; the `type`
// field disambiguates.
//
// What this does:
//  1. Ensures the on-disk events dir exists for this session.
//  2. Sends `set_session_flag {key: "panel_events_armed", value: true}`
//     over the control socket — the HUD's `panelEvent` bridge consults
//     this flag before persisting any incoming event.
//  3. Returns the exact Monitor incantation Claude should run.
//
// Idempotent. Calling it twice is fine — both calls return the same
// instructions; the flag stays true.

import { registerRawHandler, type RawToolHandler } from "./registry.ts";
import {
  ensureMarkupDirs,
  markupEventsLog,
} from "../session.ts";
import type { CallToolResult } from "@modelcontextprotocol/sdk/types.js";

const handler: RawToolHandler = {
  toolName: "enable_panel_events",
  description:
    "Arm the panel-event push channel for this session. After calling " +
    "this, agent HTML rendered via `show_html` (or any WebView panel) " +
    "can call `window.quickshow.emit(payload)` and the payload lands as " +
    "a one-line NDJSON event in a per-session log file. Call this ONCE " +
    "per session before rendering interactive panels. The tool response " +
    "tells you the exact `Monitor` command to start watching the events " +
    "log — react to `panel_event` lines (your free-form payload, " +
    "agent-defined semantics) and `panel_event_dropped` lines (throttle " +
    "warning, ≥1 event/sec was discarded). Independent of " +
    "`enable_markup_events`; arm either, both, or neither. Idempotent.",
  inputSchema: {
    type: "object",
    properties: {},
  },

  async call(_args, ctx): Promise<CallToolResult> {
    try {
      ensureMarkupDirs(ctx.sessionId);
    } catch (err) {
      return {
        content: [{
          type: "text",
          text: `failed to prepare events dir: ${err instanceof Error ? err.message : String(err)}`,
        }],
        isError: true,
      };
    }

    const resp = await ctx.client.request({
      kind: "set_session_flag",
      session: ctx.sessionId,
      key: "panel_events_armed",
      value: true,
    });

    if (resp.kind !== "ok") {
      const err = "error" in resp ? resp.error : resp.kind;
      return {
        content: [{ type: "text", text: `set_session_flag rejected: ${err}` }],
        isError: true,
      };
    }

    const logPath = markupEventsLog(ctx.sessionId);
    const text = [
      "Panel events armed for this session.",
      "",
      "To receive notifications when a `show_html` (or other WebView) panel calls `window.quickshow.emit(...)`, start a Monitor:",
      "",
      "  command: `tail -n 0 -F " + logPath + "`",
      "  persistent: true",
      "  description: \"QuickShow panel events\"",
      "",
      "Each notification will be one NDJSON line.",
      "  - `{\"type\":\"panel_event\",\"panel\":\"<name>\",\"payload\":<json>,\"ts\":<ms>}` → the agent-defined payload your HTML emitted.",
      "  - `{\"type\":\"panel_event_dropped\",\"panel\":\"<name>\",\"dropped\":<n>,\"ts\":<ms>}` → the throttle (20 events/sec/panel) discarded `n` emits in the last second. Throttle the page if you see this.",
      "",
      "JS surface inside your panel HTML:",
      "  `window.quickshow.emit(payload)`  — payload is any JSON-serializable value (typically `{type, ...}`).",
      "",
      "If you also want markup feedback (user drawing on the panel + Send), call `enable_markup_events` too — the channels are independent and share this same log.",
      "",
      "This call is idempotent — calling again returns the same instructions and leaves the flag armed.",
    ].join("\n");

    return {
      content: [{ type: "text", text }],
    };
  },
};

registerRawHandler(handler);
