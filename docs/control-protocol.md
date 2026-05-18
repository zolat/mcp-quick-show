# QuickShow Control Protocol

Wire format between the `mcp-quick-show` sidecar and `QuickShow.app`.

**Transport:** Unix domain socket (SOCK_STREAM), NDJSON framing
(one JSON object per line, terminated by `\n`).

**Default socket path:**
`~/Library/Application Support/QuickShow/control.sock`
(overridable via `QUICKSHOW_SOCKET_PATH`).

**Mirror discipline:** the wire types live in two paired files —
`QuickShow/Sources/Server/ControlProtocol.swift` and
`sidecar/src/protocol.ts`. Changes must touch both files in the same
commit.

## Envelope

Every line is a JSON object. Direction is implicit by `kind`:

- Sidecar → app: `hello`, `ping`, `upsert`, `close`, `list`, `inspect`,
  `set_session_flag`.
- App → sidecar: `ok`, `render_error`, `protocol_error`.

Side channel (app → Claude, **not** sidecar→app): the app appends
NDJSON events to a per-session log on disk that the sidecar exposes
via `Monitor`. See [Events log](#events-log) below.

Every request carries an optional `id` (string). The matching response
echoes the same `id` so concurrent requests are correlated.

## Sidecar → app

### `hello` — handshake

```json
{"id": "<msg-id>", "kind": "hello", "session_id": "<uuid>", "client": "claude-code"}
```

Identifies the sidecar to the app. `session_id` is stable per
sidecar-invocation context (see `sidecar/src/session.ts`).

Response: `{"id": "...", "kind": "ok", "result": {"version": "0.1", "pid": N}}`

### `ping` — round-trip liveness

```json
{"id": "<msg-id>", "kind": "ping"}
```

Response: `{"id": "...", "kind": "ok", "result": {"version": "0.1", "pid": N}}`

### `upsert` — render content into a panel *(Phase 1+)*

```json
{"id": "<msg-id>", "kind": "upsert", "session": "<uuid>", "name": "<slot>",
 "content_type": "markdown|svg|image|mermaid|html|url",
 "form": "inline|path|url",
 "body": "<text, path, or absolute http(s) URL>",
 "width": <optional points>}
```

Same `name` updates the existing panel in place. Different `name`
opens a new tab. Closed panels reopen on a subsequent `upsert`.

`form` semantics by content type:
- `markdown` / `svg` / `mermaid` — `inline` (body is the source) or
  `path` (body is an absolute filesystem path).
- `image` — `path` only.
- `html` — `inline` only.
- `url` — `url` only (body is an absolute http(s) URL; the page is
  fetched live; same-origin nav stays in-panel, cross-origin opens
  externally).

`width` (points, 100–4096) is an optional viewport hint used by
HTMLRenderer and URLRenderer to size the WebView's CSS viewport
before content loads.

Response (success): `{"id": "...", "kind": "ok", "result": {"width": N, "height": N, "screenshot_b64": "..."}}`.

### `close` — remove a panel by name *(Phase 1+)*

```json
{"id": "<msg-id>", "kind": "close", "session": "<uuid>", "name": "<slot>"}
```

### `list` — enumerate panels in a session *(Phase 3+)*

```json
{"id": "<msg-id>", "kind": "list", "session": "<uuid>"}
```

Response: `{"id": "...", "kind": "ok", "result": [{"name": "...", "content_type": "...", "width": N, "height": N}, ...]}`.

### `inspect` — re-snapshot a panel without re-sending content *(Phase 3+)*

```json
{"id": "<msg-id>", "kind": "inspect", "session": "<uuid>", "name": "<slot>"}
```

Response: same shape as `upsert`'s success response.

### `set_session_flag` — set a per-session flag on the app

```json
{"id": "<msg-id>", "kind": "set_session_flag", "session": "<uuid>",
 "key": "<flag-name>", "value": <bool|number|string|null>}
```

Generic key/value pair. The app stores flags in a per-session dict
and consumers (UI bits, message-handler gates) read them by name.
Adding a new flag is a string-key addition — no envelope change.

Current flag keys:

| Key                   | Value | Set by                  | Effect |
|-----------------------|-------|-------------------------|--------|
| `markup_events_armed` | `true`| `enable_markup_events`  | HUD's Send button enabled on markup-capable panels; `markup_sent` / `markup_dismissed` lines append to the events log. |
| `panel_events_armed`  | `true`| `enable_panel_events`   | The `panelEvent` JS bridge persists `panel_event` lines to the events log (gated; otherwise emits are dropped silently). |

Response: `{"id": "...", "kind": "ok", "result": {}}`.

## App → sidecar

### `ok` — success

```json
{"id": "<msg-id>", "kind": "ok", "result": <verb-specific>}
```

### `render_error` — request was valid but the renderer failed

```json
{"id": "<msg-id>", "kind": "render_error",
 "error": "<human-readable>",
 "line": <optional, e.g. mermaid parse error>,
 "screenshot_b64": "<screenshot of the in-DOM error UI>"}
```

The panel itself displays the styled error UI; the screenshot lets the
agent fix and retry without asking the user.

### `protocol_error` — malformed request, unknown kind, etc.

```json
{"id": "<msg-id>", "kind": "protocol_error", "error": "<details>"}
```

## Events log

Out-of-band channel for app → Claude notifications. The app appends
one JSON object per line (NDJSON) to a per-session file; the sidecar
hands Claude a `Monitor` command (`tail -n 0 -F <path>`) that streams
new lines as notifications.

**Path:**
`~/Library/Caches/QuickShow/events/<sessionId>/events.ndjson`
(overridable via `QUICKSHOW_EVENTS_DIR`).

**Mirror discipline:** the path-derivation pair —
`QuickShow/Sources/Events/MarkupPaths.swift` and
`sidecar/src/session.ts` — must change together. The line shapes
below are append-only (no removals, no renames; new kinds are fine).

### Line shapes

All lines carry `type` (kind discriminator), `panel` (panel name so
multi-panel sessions disambiguate), and `ts` (milliseconds since
Unix epoch). Other fields vary by `type`.

**`markup_sent`** — user pressed **Send** on a markup-capable panel.
Gated by `markup_events_armed`.

```json
{"type":"markup_sent","panel":"<name>","artifact":"<uuid>","ts":<ms>}
```

The PNG artifact lives at
`~/Library/Caches/QuickShow/events/<sessionId>/artifacts/<uuid>.png`.
Fetch via the `get_markup` MCP tool.

**`markup_dismissed`** — user closed a markup-capable panel without
sending. Gated by `markup_events_armed`. No artifact.

```json
{"type":"markup_dismissed","panel":"<name>","ts":<ms>}
```

**`panel_event`** — agent-supplied HTML called
`window.quickshow.emit(payload)`. Gated by `panel_events_armed`.
`payload` is a free-form JSON value (object, array, scalar, null) —
agent-defined semantics.

```json
{"type":"panel_event","panel":"<name>","payload":<json>,"ts":<ms>}
```

**`panel_event_dropped`** — token-bucket throttle (capacity 20
events/sec/panel) discarded `dropped` emits in the last second.
Emitted at most 1Hz/panel and only when drops occurred — a
well-behaved page never produces this line. Gated by
`panel_events_armed`.

```json
{"type":"panel_event_dropped","panel":"<name>","dropped":<n>,"ts":<ms>}
```

### Independence of channels

`enable_markup_events` and `enable_panel_events` are independent.
A session may arm one, the other, both, or neither. All four event
kinds share the same `events.ndjson` file; Claude filters by `type`.

## Implementation status

| Verb | Phase | Status |
|---|---|---|
| `hello` | 0 | ✅ implemented |
| `ping` | 0 | ✅ implemented |
| `upsert` | 1 | ✅ markdown / svg / mermaid / image / html / url |
| `close` | 1 | ✅ implemented |
| `list` | 1 | ✅ implemented |
| `inspect` | 1 | ✅ implemented |
| `set_session_flag` | post-v0.1 | ✅ implemented |
