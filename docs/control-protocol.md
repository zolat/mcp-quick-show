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

- Sidecar → app: `hello`, `ping`, `upsert`, `close`, `list`, `inspect`.
- App → sidecar: `ok`, `render_error`, `protocol_error`.

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
 "content_type": "markdown|svg|image|mermaid",
 "form": "inline|path",
 "body": "<text or path>"}
```

Same `name` updates the existing panel in place. Different `name`
opens a new tab. Closed panels reopen on a subsequent `upsert`.

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

## Implementation status

| Verb | Phase | Status |
|---|---|---|
| `hello` | 0 | ✅ implemented |
| `ping` | 0 | ✅ implemented |
| `upsert` | 1 | ✅ markdown — svg/mermaid/image pending |
| `close` | 1 | ✅ implemented |
| `list` | 1 | ✅ implemented |
| `inspect` | 1 | ✅ implemented |
