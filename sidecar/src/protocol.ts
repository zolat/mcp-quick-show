// Wire format for the control socket. Mirrored in
// `QuickShow/Sources/Server/ControlProtocol.swift` — changes must touch
// both files in the same commit.
//
// Envelope shape (per PRD § "Wire-protocol envelope"):
//   sidecar → app:  {"id", "kind":"hello|ping|upsert|close|list|inspect|set_session_flag", ...}
//   app → sidecar:  {"id", "kind":"ok|render_error|protocol_error", ...}

export const PROTOCOL_VERSION = "0.1";

// ---------- Requests (sidecar → app) ----------

export type HelloRequest = {
  id?: string;
  kind: "hello";
  session_id: string;
  client?: string;
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
  content_type: "markdown" | "svg" | "image" | "mermaid" | "html";
  form: "inline" | "path";
  body: string;
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

export type ControlRequest =
  | HelloRequest
  | PingRequest
  | UpsertRequest
  | CloseRequest
  | ListRequest
  | InspectRequest
  | SetSessionFlagRequest;

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

export type HelloResult = { version: string; pid: number };
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
