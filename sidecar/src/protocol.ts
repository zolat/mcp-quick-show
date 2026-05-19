// Wire format for the control socket. Mirrored in
// `QuickShow/Sources/Server/ControlProtocol.swift` — changes must touch
// both files in the same commit.
//
// Envelope shape (per PRD § "Wire-protocol envelope"):
//   sidecar → app:  {"id", "kind":"hello|ping|upsert|close|list|inspect|set_session_flag", ...}
//   app → sidecar:  {"id", "kind":"ok|render_error|protocol_error", ...}

export const PROTOCOL_VERSION = "0.2";

// ---------- Requests (sidecar → app) ----------

/// `session_id` is a CLAIM, not authoritative. The app inspects its
/// per-FD session map and either grants the claim (first-ever sidecar
/// from this cwd, or orphan-grace reattach) or mints a fresh UUID if
/// the claim is already bound to a different live FD (parallel
/// sessions from the same cwd). The granted id comes back in
/// `HelloResult.session_id`; sidecar adopts that for every subsequent
/// verb and for derived paths (events log, artifacts dir).
export type HelloRequest = {
  id?: string;
  kind: "hello";
  session_id: string;
  client?: string;
  /** Informational only — app logs it when a contest is resolved. */
  parent_pid?: number;
};

export type PingRequest = {
  id?: string;
  kind: "ping";
};

export type UpsertRequest = {
  id?: string;
  kind: "upsert";
  session: string;
  name: string;
  content_type: "markdown" | "svg" | "image" | "mermaid" | "html" | "url";
  form: "inline" | "path" | "url";
  body: string;
  /**
   * Optional canvas-width hint in points. HTMLRenderer / URLRenderer
   * size the WebView's CSS viewport to this before content loads so
   * responsive designs lay out at the intended width.
   */
  width?: number;
  /**
   * Optional grouping key. Panels sharing a `group` land in the same
   * HUD; each distinct `group` spawns its own HUD with its own cascade
   * origin. Omitted → the session's default (unnamed) HUD. Ignored on
   * same-`name` updates: `name` is sticky to the HUD where it was
   * first created.
   */
  group?: string;
  /**
   * Optional per-panel framing paragraph rendered in the HUD's
   * description banner above the content. Empty string clears.
   */
  description?: string;
  /**
   * Optional HUD-level framing paragraph rendered in the description
   * banner above per-tab `description`. Last-writer-wins across calls
   * that route to the same HUD (same `group`, or default HUD when
   * `group` is omitted). Empty string clears.
   */
  hud_description?: string;
};

export type CloseRequest = {
  id?: string;
  kind: "close";
  session: string;
  name: string;
};

export type ListRequest = {
  id?: string;
  kind: "list";
  session: string;
};

export type InspectRequest = {
  id?: string;
  kind: "inspect";
  session: string;
  name: string;
};

/// `set_session_flag` — set a per-session boolean/value flag on the app
/// side. Generic by design; first use is `markup_events_armed`, which
/// the HUD reads to enable the Send button on markup-capable panels.
export type SetSessionFlagRequest = {
  id?: string;
  kind: "set_session_flag";
  session: string;
  key: string;
  value: boolean | string | number | null;
};

/// `claim_share` — handoff from the sidecar's `get_share` tool. The
/// user opened a HUD from the menu bar, optionally marked it up, hit
/// Send → the app wrote a flattened PNG + JSON sidecar to
/// `<sharesBaseDir>` and put `[quickshow-share:<share_id>]` on the
/// clipboard. The user pastes that token into Claude; Claude calls
/// `get_share(<id>)`; the sidecar forwards here with `session` set to
/// the claimer's granted session id.
///
/// The app migrates the HUDInstance out of the reserved "user-windows"
/// session into `session`, renames the panel to `share-<share_id>`,
/// and moves the share PNG into `session`'s artifacts dir so the
/// sidecar's `get_share` reads it through the same per-session
/// discipline as `get_markup`. First claim wins — a second claim from
/// a different session returns a protocol_error.
export type ClaimShareRequest = {
  id?: string;
  kind: "claim_share";
  session: string;
  share_id: string;
};

export type ControlRequest =
  | HelloRequest
  | PingRequest
  | UpsertRequest
  | CloseRequest
  | ListRequest
  | InspectRequest
  | SetSessionFlagRequest
  | ClaimShareRequest;

// ---------- Responses (app → sidecar) ----------

export type OkResponse<R = unknown> = {
  id?: string;
  kind: "ok";
  result?: R;
};

export type RenderErrorResponse = {
  id?: string;
  kind: "render_error";
  error: string;
  line?: number;
  screenshot_b64?: string;
};

export type ProtocolErrorResponse = {
  id?: string;
  kind: "protocol_error";
  error: string;
};

export type ControlResponse =
  | OkResponse
  | RenderErrorResponse
  | ProtocolErrorResponse;

// ---------- Result payload types ----------

/// `session_id` is the GRANTED id — sidecar adopts this unconditionally
/// for downstream verbs and derived paths.
export type HelloResult = { version: string; pid: number; session_id: string };
export type PingResult = { version: string; pid: number };

export type UpsertResult = {
  width: number;
  height: number;
  screenshot_b64?: string;
};

export type PanelInfo = {
  name: string;
  content_type: string;
  width: number;
  height: number;
};
export type ListResult = PanelInfo[];

/// Result payload returned by a successful `claim_share`. Sidecar
/// forwards `panel_name` back to the model so it can keep updating
/// the migrated HUD with `show_url` / `show_image` / `show_html` /
/// `show_markdown` etc.
export type ClaimShareResult = {
  panel_name: string;
  content_type: string;
};
