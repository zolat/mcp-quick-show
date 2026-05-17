// Single chokepoint for the `hello` handshake. Sends the cwd-derived
// (or test-supplied) UUID as a CLAIM and returns the app's GRANTED
// session_id — which may differ from the claim when the app's
// allocator detects a parallel session contesting the same cwd id.
// Every caller — main sidecar + CLI smoke scripts — uses this so the
// "always adopt the granted id" contract stays uniform.
//
// Also validates the app's reported wire-protocol version and the
// presence of session_id. A version mismatch is a hard failure with a
// rebuild-and-relaunch instruction — silently adopting `undefined`
// from a too-old app led to confusing downstream errors before this
// guard existed.

import type { SocketClient } from "./socket.ts";
import { PROTOCOL_VERSION, type HelloResult } from "./protocol.ts";

const REBUILD_HINT =
  "Rebuild + relaunch QuickShow:\n" +
  "  xcodebuild -scheme QuickShow -configuration Debug clean build\n" +
  "then quit + reopen the app.";

export async function helloHandshake(
  client: SocketClient,
  candidate: string,
  clientName: string,
): Promise<string> {
  const resp = await client.request({
    kind: "hello",
    session_id: candidate,
    client: clientName,
    parent_pid: process.ppid,
  });
  if (resp.kind !== "ok") {
    const err = "error" in resp ? resp.error : resp.kind;
    throw new Error(`hello rejected: ${err}`);
  }
  const result = (resp.result ?? {}) as Partial<HelloResult>;
  const appVersion = typeof result.version === "string" ? result.version : "<missing>";
  if (appVersion !== PROTOCOL_VERSION) {
    throw new Error(
      `wire-protocol mismatch — app reports version "${appVersion}" but ` +
        `sidecar expects "${PROTOCOL_VERSION}". The QuickShow.app binary is ` +
        `older than the sidecar. ${REBUILD_HINT}`,
    );
  }
  if (typeof result.session_id !== "string" || result.session_id.length === 0) {
    throw new Error(
      `hello response missing session_id (app reports version "${appVersion}"). ` +
        `The app binary predates the session_id allocator. ${REBUILD_HINT}`,
    );
  }
  return result.session_id;
}
