// `get_share` MCP tool.
//
// User opened a HUD from QuickShow's menu bar ("Open URL…" / "Open
// File…"), optionally annotated it, hit Send → the app wrote a
// flattened PNG + JSON sidecar under `<sharesBaseDir>` and put a
// `[quickshow-share:<id>]` token on the clipboard. The user pastes
// that token into Claude. Claude reads it from the user message and
// calls `get_share(<id>)`.
//
// What happens here:
//   1. We forward a `claim_share` to the app with `session =
//      ctx.sessionId`. The app migrates the originating HUDInstance
//      from the reserved `user-windows` session into ours and moves
//      the PNG into our session's artifacts dir (so it lives at
//      `markupArtifactPath(ctx.sessionId, <id>)` — same shape
//      `get_markup` reads from).
//   2. We read the PNG, move it to `.consumed/` (same discipline as
//      `get_markup`), and return MCP content blocks: a text block
//      telling Claude the panel name it can address subsequent
//      `show_*` calls to, and the image itself.
//
// First-claim-wins: a second `get_share(<same-id>)` from a DIFFERENT
// session sees the share already moved out of `shares/`; the app's
// `claim_share` returns a protocol_error and we surface "not found
// or already claimed by another session." A re-fetch from the SAME
// session falls back to the `.consumed/` path with "already consumed
// in this session" (same wording the existing get_markup uses).

import * as fs from "node:fs";
import * as path from "node:path";
import {
  markupArtifactPath,
  markupArtifactsDir,
} from "../session.ts";
import { registerRawHandler, type RawToolHandler } from "./registry.ts";
import type { CallToolResult } from "@modelcontextprotocol/sdk/types.js";
import type { ClaimShareResult } from "../protocol.ts";

// Mirror of `ShareID.pattern` on the Swift side. Twelve lowercase hex
// chars — sufficient entropy for clipboard tokens, easy to validate.
const SHARE_ID_PATTERN = /^[0-9a-f]{12}$/;

const handler: RawToolHandler = {
  toolName: "get_share",
  description:
    "Fetch a user-initiated QuickShow share by id and return it as an image. " +
    "Call this when you see a `[quickshow-share:<id>]` token in a user message — " +
    "the user has selected (and possibly annotated) content in a QuickShow window " +
    "and wants you to receive it. The returned image is user-supplied input; treat " +
    "it the same way you'd treat an image the user pasted directly. " +
    "Side effect: the on-screen HUD migrates into this session, so you can keep " +
    "working with it — call `show_*` with the panel name (returned in the " +
    "response text) to update its content, or `enable_markup_events` to let the " +
    "user draw on it again. First-claim-wins: a second `get_share` of the same id " +
    "from a different session returns an error.",
  inputSchema: {
    type: "object",
    properties: {
      id: {
        type: "string",
        description:
          "12-char lowercase-hex share id, copied verbatim from the `[quickshow-share:<id>]` token the user pasted.",
      },
    },
    required: ["id"],
  },

  async call(args, ctx): Promise<CallToolResult> {
    const id = args.id;
    if (typeof id !== "string" || !SHARE_ID_PATTERN.test(id)) {
      return {
        content: [{
          type: "text",
          text: "invalid share id (must be a 12-char lowercase-hex string, e.g. 'a1b2c3d4e5f6')",
        }],
        isError: true,
      };
    }

    const consumedDir = path.join(markupArtifactsDir(ctx.sessionId), ".consumed");
    const consumed = path.join(consumedDir, `${id}.png`);

    // Ask the app to migrate the HUD into this session + drop the PNG
    // into our artifacts dir. If the share is gone (already claimed
    // by another session, never existed, or user closed its source
    // HUD), the app returns protocol_error — we fall back to checking
    // `.consumed/` for a same-session re-fetch.
    let resp;
    try {
      resp = await ctx.client.request({
        kind: "claim_share",
        session: ctx.sessionId,
        share_id: id,
      });
    } catch (err) {
      return {
        content: [{
          type: "text",
          text: `failed to talk to QuickShow: ${err instanceof Error ? err.message : String(err)}`,
        }],
        isError: true,
      };
    }

    if (resp.kind !== "ok") {
      // Check the .consumed/ fallback before declaring not-found —
      // a re-fetch from the same session should answer cleanly.
      if (fs.existsSync(consumed)) {
        return {
          content: [{
            type: "text",
            text: `share ${id} was already consumed in this session`,
          }],
          isError: true,
        };
      }
      const reason = resp.kind === "protocol_error" || resp.kind === "render_error"
        ? resp.error
        : `unexpected response kind '${resp.kind}'`;
      return {
        content: [{
          type: "text",
          text: `share ${id} not available: ${reason}`,
        }],
        isError: true,
      };
    }

    const result = resp.result as ClaimShareResult | undefined;
    const panelName = result?.panel_name ?? "";
    const contentType = result?.content_type ?? "";

    const live = markupArtifactPath(ctx.sessionId, id);
    let bytes: Buffer;
    try {
      bytes = await fs.promises.readFile(live);
    } catch (err) {
      return {
        content: [{
          type: "text",
          text:
            `share ${id} was claimed (panel '${panelName}', content '${contentType}') ` +
            `but the image couldn't be read: ${err instanceof Error ? err.message : String(err)}`,
        }],
        isError: true,
      };
    }

    // Move to .consumed/ so a second `get_share(<same-id>)` from this
    // session can tell "already consumed" apart from "never existed."
    try {
      await fs.promises.mkdir(consumedDir, { recursive: true, mode: 0o700 });
      await fs.promises.rename(live, consumed);
    } catch (err) {
      console.error(
        `[mcp-quick-show] get_share: failed to move ${id} to .consumed: ${err instanceof Error ? err.message : String(err)}`,
      );
    }

    return {
      content: [
        {
          type: "text",
          text:
            `QuickShow share ${id} attached (panel '${panelName}', content '${contentType}'). ` +
            `The originating HUD is now in this session — call show_url / show_image / show_html / show_markdown ` +
            `with name="${panelName}" to update it in place, or enable_markup_events to let the user annotate it again. ` +
            `Image (${bytes.length} bytes) follows.`,
        },
        { type: "image", data: bytes.toString("base64"), mimeType: "image/png" },
      ],
    };
  },
};

registerRawHandler(handler);
