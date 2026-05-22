# Adding a new renderer

QuickShow's renderer abstraction is designed so that adding a new
content type costs **one Swift renderer file**, **one HTML template
file** (if you're using the WebView base), and a tool handler +
two registration lines in the MCP layer.

This doc walks through a concrete example: adding a hypothetical
`show_dot` tool that renders Graphviz DOT diagrams via [Viz.js].

## The three files

### 1. Swift renderer — `QuickShow/Sources/Renderers/DotRenderer.swift`

```swift
import Cocoa
import WebKit

@MainActor
final class DotRenderer: WebViewPanelRenderer {
    override class var typeKey: String { "dot" }
    override var templateName: String { "dot" }
    // Defaults to useTemplate=true (the bundled HTML template
    // is loaded; the agent's body is fed into the page's
    // `window.__quickshow_render(body)` entry point).
}
```

For non-WebView content types, conform to `PanelRenderer` directly
and implement `makeView()`, `update(payload:)`, `snapshot()`.

### 2. HTML template — `QuickShow/Resources/templates/dot.html`

```html
<!doctype html>
<html>
<head>
  <meta charset="utf-8">
  <style>
    html, body { margin: 0; background: transparent; }
    #out { padding: 16px; }
  </style>
  <!-- Bundled libs get inlined here by tools/copy-resources.sh -->
  <!--QS_VIZJS-->
</head>
<body>
  <div id="out"></div>
  <script>
    window.__quickshow_render = function(body) {
      try {
        const svg = Viz(body, { format: "svg" });
        document.getElementById("out").innerHTML = svg;
      } catch (err) {
        document.getElementById("out").textContent =
          "DOT error: " + err.message;
      }
    };
  </script>
</body>
</html>
```

The `<!--QS_*-->` placeholders are processed by
`tools/copy-resources.sh` during the build — drop the library
file under `QuickShow/Resources/libs/` and update the script's
substitution table.

### 3. Tool handler — append to `QuickShow/Sources/MCP/MCPToolHandlers.swift`

```swift
// In the tools array inside register(...):
showDotTool(),

// In the CallTool switch:
case "show_dot":
    return await Self.handleShowDot(args: args, sm: sm, rt: rt, sid: sid)

// New handler — mirrors show_mermaid's shape:
private static func handleShowDot(
    args: [String: Value],
    sm: SessionManager,
    rt: MCPSessionRouter,
    sid: String
) async -> CallTool.Result {
    do {
        let name = try ToolValidation.parseName(args)
        guard let dv = args["definition"], let definition = dv.stringValue,
              !definition.trimmingCharacters(in: .whitespaces).isEmpty
        else {
            throw ToolValidation.Error(message: "`definition` must be a non-empty string")
        }
        let payload = UpsertPayload(
            name: name,
            contentType: "dot",
            form: "inline",
            body: definition,
            width: nil,
            returnScreenshot: ToolValidation.parseReturnScreenshot(args),
            grouping: try ToolValidation.parseGroupingFields(args)
        )
        let (result, snapshot) = try await dispatch(sm: sm, rt: rt, sid: sid, payload: payload)
        return CallTool.Result(content: renderResultContent(payload: payload, result: result, snapshot: snapshot))
    } catch let err as ToolValidation.Error {
        return errorResult("invalid arguments: \(err.message)")
    } catch {
        return errorResult("render error: \(error.localizedDescription)")
    }
}

private static func showDotTool() -> Tool {
    var properties: [String: Value] = [
        "name": .object(["type": .string("string"), …]),
        "definition": .object(["type": .string("string"), …]),
        "return_screenshot": .object(["type": .string("boolean"), …]),
    ]
    for (k, v) in ToolValidation.groupingSchemaProps { properties[k] = v }
    return Tool(
        name: "show_dot",
        description: "Render a Graphviz DOT diagram …",
        inputSchema: .object([
            "type": .string("object"),
            "required": .array([.string("name"), .string("definition")]),
            "properties": .object(properties),
        ])
    )
}
```

## The two registration lines

### `QuickShow/Sources/Renderers/RendererRegistry.swift`

```swift
registry.register(DotRenderer.self) { DotRenderer() }
```

### Add the entry to the `tools` array in `MCPToolHandlers.register(...)`

```swift
let tools: [Tool] = [
    …
    showDotTool(),
]
```

## End-to-end verification

```sh
xcodegen generate
tools/smoke-http-mcp.sh
```

Then drive a real `tools/call`:

```sh
curl -s http://127.0.0.1:7890/mcp -X POST \
  -H "Content-Type: application/json" \
  -H "Accept: application/json, text/event-stream" \
  -H "Mcp-Session-Id: $SID" \
  -d '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{
    "name":"show_dot",
    "arguments":{"name":"smoke","definition":"digraph { A -> B }"}
  }}'
```

Use the existing `enable_markup_events(group=…)` + `get_markup` to
verify the markup loop works for the new content type — it should
work uniformly because the WebView base owns the markup canvas.

## Shared validation chokepoint

`QuickShow/Sources/MCP/MCPToolValidation.swift` is the single
source for grouping-field parsing, name validation, width clamping,
and the file-path resolver. New tools should funnel through these
helpers rather than reimplementing the caps.

[Viz.js]: https://github.com/mdaines/viz-js
