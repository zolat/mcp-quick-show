// `enable_markup_events` MCP tool.
//
// Arms the per-session push channel that lets a user's markup on a HUD
// panel land in Claude's context.
//
// What this does:
//  1. Ensures the on-disk events log + artifacts dir exist for this
//     session (so the app can write into them without racing the first
//     event).
//  2. Sends `set_session_flag {key: "markup_events_armed", value: true}`
//     over the control socket — the HUD reads this flag to enable the
//     Send button on markup-capable panels.
//  3. Returns the exact Monitor incantation Claude should run to start
//     receiving notifications.
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
  toolName: "enable_markup_events",
  description:
    "Arm the markup push channel for this session. After calling this, " +
    "the HUD's Send button is enabled on markup-capable panels, and a " +
    "user pressing Send (or closing without sending) emits a one-line " +
    "NDJSON event to a per-session log file. Call this ONCE per session " +
    "before rendering markup-capable panels. The tool response tells you " +
    "the exact `Monitor` command to start watching the events log — when " +
    "you see a `markup_sent` line, call `get_markup(artifact_id)` to " +
    "fetch the image. When you see `markup_dismissed`, the user closed " +
    "the panel without marking up. Idempotent.",
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
          text: `failed to prepare markup dirs: ${err instanceof Error ? err.message : String(err)}`,
        }],
        isError: true,
      };
    }

    const resp = await ctx.client.request({
      kind: "set_session_flag",
      session: ctx.sessionId,
      key: "markup_events_armed",
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
      "Markup events armed for this session.",
      "",
      "To receive notifications when the user presses Send (or closes without sending), start a Monitor:",
      "",
      "  command: `tail -n 0 -F " + logPath + "`",
      "  persistent: true",
      "  description: \"QuickShow markup events\"",
      "",
      "Each notification will be one NDJSON line.",
      "  - `{\"type\":\"markup_sent\",\"panel\":\"<name>\",\"artifact\":\"<id>\",...}` → call `get_markup(artifact_id: \"<id>\")` to fetch the PNG.",
      "  - `{\"type\":\"markup_dismissed\",\"panel\":\"<name>\",...}` → the user closed the panel without sending. No artifact.",
      "",
      "This call is idempotent — calling again returns the same instructions and leaves the flag armed.",
    ].join("\n");

    return {
      content: [{ type: "text", text }],
    };
  },
};

registerRawHandler(handler);
