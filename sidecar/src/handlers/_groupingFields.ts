// Shared input-schema fragment + validator for the three tab-grouping
// fields that every content-type handler accepts:
//
//   - `group`            — string, ≤256 bytes; HUD identity.
//   - `description`      — string, ≤256 bytes; per-tab banner line.
//   - `hud_description`  — string, ≤4 KB;     HUD-level banner line.
//
// Caps are byte-length (UTF-8) so multibyte content doesn't blow
// through them. Empty string is a valid value and means "clear" on
// the receiving side — distinct from `undefined` which means "leave
// untouched". The validator preserves that distinction.

const GROUP_MAX_BYTES = 256;
const DESCRIPTION_MAX_BYTES = 256;
const HUD_DESCRIPTION_MAX_BYTES = 4 * 1024;

/// JSON-schema fragment to spread into a handler's `inputSchema.properties`.
export const groupingSchemaProps = {
  group: {
    type: "string",
    description:
      "Optional grouping key. Panels sharing a `group` are rendered as tabs in the same floating HUD; each distinct group spawns its own HUD. Without `group`, the panel goes into the session's default HUD. Updates to an existing `name` ignore `group` (panels are sticky to the HUD where they were first created).",
  },
  description: {
    type: "string",
    description:
      "Optional short framing line for THIS tab, shown in the panel's description banner above the rendered content. Plain text, ≤256 bytes. Pass an empty string to clear a previously-set description.",
  },
  hud_description: {
    type: "string",
    description:
      "Optional framing paragraph for the whole HUD, shown above the per-tab description. Useful when presenting multiple related tabs (e.g. \"Three hero variants ranked best-to-worst\"). Last writer wins among calls that share a `group`. Plain text, ≤4 KB. Pass an empty string to clear.",
  },
} as const;

export type ParsedGroupingFields = {
  group?: string;
  description?: string;
  hudDescription?: string;
};

export type GroupingParseResult =
  | { ok: true; fields: ParsedGroupingFields }
  | { ok: false; error: string };

function parseString(
  args: Record<string, unknown>,
  key: string,
  cap: number,
): { present: false } | { present: true; value: string } | { present: "error"; error: string } {
  const raw = args[key];
  if (raw === undefined) return { present: false };
  if (typeof raw !== "string") {
    return { present: "error", error: `\`${key}\` must be a string when present` };
  }
  const bytes = Buffer.byteLength(raw, "utf8");
  if (bytes > cap) {
    return {
      present: "error",
      error: `\`${key}\` too large: ${bytes} bytes > ${cap} byte cap`,
    };
  }
  return { present: true, value: raw };
}

/// Pull the three grouping fields off a tool-call args bag, validating
/// types and size caps. Returns `{ ok: true, fields }` with each field
/// present iff it appeared on the input (so callers can preserve
/// `undefined` vs empty-string semantics on the wire). Returns
/// `{ ok: false, error }` on any malformed value — handlers surface
/// the error string verbatim.
export function parseGroupingFields(
  args: Record<string, unknown>,
): GroupingParseResult {
  const out: ParsedGroupingFields = {};

  const g = parseString(args, "group", GROUP_MAX_BYTES);
  if (g.present === "error") return { ok: false, error: g.error };
  if (g.present === true) out.group = g.value;

  const d = parseString(args, "description", DESCRIPTION_MAX_BYTES);
  if (d.present === "error") return { ok: false, error: d.error };
  if (d.present === true) out.description = d.value;

  const hd = parseString(args, "hud_description", HUD_DESCRIPTION_MAX_BYTES);
  if (hd.present === "error") return { ok: false, error: hd.error };
  if (hd.present === true) out.hudDescription = hd.value;

  return { ok: true, fields: out };
}
