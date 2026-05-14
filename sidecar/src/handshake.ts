// Single chokepoint for the `hello` handshake. Sends the cwd-derived
// (or test-supplied) UUID as a CLAIM and returns the app's GRANTED
// session_id — which may differ from the claim when the app's
// allocator detects a parallel session contesting the same cwd id.
// Every caller — main sidecar + CLI smoke scripts — uses this so the
// "always adopt the granted id" contract stays uniform.

import type { SocketClient } from "./socket.ts";
import type { HelloResult } from "./protocol.ts";

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
  return (resp.result as HelloResult).session_id;
}
