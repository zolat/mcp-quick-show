// `get_markup` MCP tool.
//
// Fetches the PNG of a marked-up panel by artifact id and returns it as
// an MCP `image` content block (so the model gets it as a proper
// visual, not a base64 blob embedded in stdout).
//
// On successful read, the artifact is moved to `<artifacts>/.consumed/`
// — keeping the directory tidy without destroying evidence. A second
// `get_markup` for the same id returns "already consumed."

import * as fs from "node:fs";
import * as path from "node:path";
import {
  markupArtifactPath,
  markupArtifactsDir,
} from "../session.ts";
import { registerRawHandler, type RawToolHandler } from "./registry.ts";
import type { CallToolResult } from "@modelcontextprotocol/sdk/types.js";

// Loose UUID guard — sidecar should never feed arbitrary strings into a
// filesystem path. Accepts the 8-4-4-4-12 hex shape we emit on the app
// side.
const ARTIFACT_ID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

const handler: RawToolHandler = {
  toolName: "get_markup",
  description:
    "Fetch a marked-up panel artifact by id and return it as an image. " +
    "Call this after the Monitor (armed via `enable_markup_events`) " +
    "emits a `markup_sent` line — the `artifact` field on that line is " +
    "the id to pass here. The artifact is moved to a `.consumed/` " +
    "subfolder on success so it's clear which markups have been " +
    "processed. Returns an MCP image (PNG) the model can inspect.",
  inputSchema: {
    type: "object",
    properties: {
      artifact_id: {
        type: "string",
        description:
          "UUID of the artifact, copied verbatim from the `artifact` field of a `markup_sent` event line.",
      },
    },
    required: ["artifact_id"],
  },

  async call(args, ctx): Promise<CallToolResult> {
    const artifactId = args.artifact_id;
    if (typeof artifactId !== "string" || !ARTIFACT_ID_PATTERN.test(artifactId)) {
      return {
        content: [{
          type: "text",
          text: "invalid artifact_id (must be a UUID like '550e8400-e29b-41d4-a716-446655440000')",
        }],
        isError: true,
      };
    }

    const live = markupArtifactPath(ctx.sessionId, artifactId);
    const consumedDir = path.join(markupArtifactsDir(ctx.sessionId), ".consumed");
    const consumed = path.join(consumedDir, `${artifactId}.png`);

    let source: string;
    if (fs.existsSync(live)) {
      source = live;
    } else if (fs.existsSync(consumed)) {
      return {
        content: [{
          type: "text",
          text: `artifact ${artifactId} was already consumed in this session`,
        }],
        isError: true,
      };
    } else {
      return {
        content: [{
          type: "text",
          text: `no artifact named '${artifactId}' for this session`,
        }],
        isError: true,
      };
    }

    let bytes: Buffer;
    try {
      bytes = await fs.promises.readFile(source);
    } catch (err) {
      return {
        content: [{
          type: "text",
          text: `failed to read artifact: ${err instanceof Error ? err.message : String(err)}`,
        }],
        isError: true,
      };
    }

    // Move to .consumed so a future call returns "already consumed."
    // Best-effort — failure here is non-fatal for the caller; we still
    // return the image.
    try {
      await fs.promises.mkdir(consumedDir, { recursive: true, mode: 0o700 });
      await fs.promises.rename(source, consumed);
    } catch (err) {
      console.error(
        `[mcp-quick-show] get_markup: failed to move ${artifactId} to .consumed: ${err instanceof Error ? err.message : String(err)}`,
      );
    }

    return {
      content: [
        { type: "text", text: `markup artifact ${artifactId} (${bytes.length} bytes)` },
        { type: "image", data: bytes.toString("base64"), mimeType: "image/png" },
      ],
    };
  },
};

registerRawHandler(handler);
