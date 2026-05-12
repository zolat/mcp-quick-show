// Standalone ping client for Phase 0 verification.
//
// Usage:
//   bun run sidecar/src/cli/ping.ts
//
// Connects to the control socket, sends a `hello` then a `ping`,
// prints both responses, exits.

import { SocketClient, DEFAULT_SOCKET_PATH } from "../socket.ts";
import { getOrCreateSessionId } from "../session.ts";

async function main() {
  const socketPath = process.env.QUICKSHOW_SOCKET_PATH ?? DEFAULT_SOCKET_PATH;
  const client = new SocketClient(socketPath);
  try {
    await client.connect(2000);
  } catch (err) {
    console.error(`ping: cannot connect to ${socketPath} — is QuickShow running?`);
    console.error(err);
    process.exit(2);
  }

  const sessionId = getOrCreateSessionId();
  const hello = await client.request({
    kind: "hello",
    session_id: sessionId,
    client: "ping-cli",
  });
  console.log("hello:", JSON.stringify(hello));

  const ping = await client.request({ kind: "ping" });
  console.log("ping: ", JSON.stringify(ping));

  client.close();
  process.exit(hello.kind === "ok" && ping.kind === "ok" ? 0 : 1);
}

main().catch((err) => {
  console.error("ping failed:", err);
  process.exit(1);
});
