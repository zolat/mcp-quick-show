// Verifies the sidecar adopts the GRANTED session_id from the app's
// hello response, even when the granted id differs from the claim
// (the parallel-session disambiguation case). Mock socket server
// stands in for the real app and returns whatever session_id we tell
// it to.

import { test, expect, beforeEach, afterEach } from "bun:test";
import * as net from "node:net";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import { SocketClient } from "../src/socket.ts";
import { helloHandshake } from "../src/handshake.ts";

let server: net.Server | null = null;
let socketPath: string;

beforeEach(() => {
  socketPath = path.join(os.tmpdir(), `qs-hello-test-${process.pid}-${Date.now()}.sock`);
});

afterEach(() => {
  if (server) {
    server.close();
    server = null;
  }
  try { fs.unlinkSync(socketPath); } catch {}
});

type HelloHandler = (req: { id: string; session_id: string; client?: string; parent_pid?: number }) => {
  kind: "ok";
  result: { version: string; pid: number; session_id: string };
} | {
  kind: "protocol_error";
  error: string;
};

function startMockServer(handler: HelloHandler): Promise<void> {
  return new Promise((resolve, reject) => {
    server = net.createServer((sock) => {
      let buf = "";
      sock.on("data", (chunk) => {
        buf += chunk.toString();
        let nl;
        while ((nl = buf.indexOf("\n")) >= 0) {
          const line = buf.slice(0, nl);
          buf = buf.slice(nl + 1);
          if (!line) continue;
          const req = JSON.parse(line);
          if (req.kind !== "hello") continue;
          const resp = handler(req);
          sock.write(JSON.stringify({ id: req.id, ...resp }) + "\n");
        }
      });
    });
    server.once("error", reject);
    server.listen(socketPath, () => resolve());
  });
}

test("helloHandshake returns the claim when uncontested", async () => {
  await startMockServer((req) => ({
    kind: "ok",
    result: { version: "0.2", pid: 12345, session_id: req.session_id },
  }));

  const client = new SocketClient(socketPath);
  await client.connect(2000);
  const granted = await helloHandshake(client, "claim-abc", "test-uncontested");
  expect(granted).toBe("claim-abc");
  client.close();
});

test("helloHandshake adopts the granted id when the app overrides the claim", async () => {
  // Simulates the parallel-session case — app returns a fresh UUID
  // instead of the claim because another live FD already holds it.
  const fresh = "fresh-granted-uuid-xyz";
  await startMockServer((_req) => ({
    kind: "ok",
    result: { version: "0.2", pid: 9999, session_id: fresh },
  }));

  const client = new SocketClient(socketPath);
  await client.connect(2000);
  const granted = await helloHandshake(client, "claim-abc", "test-contested");
  expect(granted).toBe(fresh);
  expect(granted).not.toBe("claim-abc");
  client.close();
});

test("helloHandshake forwards parent_pid in the request", async () => {
  let observedPpid: number | undefined;
  await startMockServer((req) => {
    observedPpid = req.parent_pid;
    return {
      kind: "ok",
      result: { version: "0.2", pid: 1, session_id: req.session_id },
    };
  });

  const client = new SocketClient(socketPath);
  await client.connect(2000);
  await helloHandshake(client, "claim-x", "test-ppid");
  expect(observedPpid).toBe(process.ppid);
  client.close();
});

test("helloHandshake throws on protocol_error", async () => {
  await startMockServer(() => ({
    kind: "protocol_error",
    error: "broken handshake",
  }));

  const client = new SocketClient(socketPath);
  await client.connect(2000);
  let threw = false;
  try {
    await helloHandshake(client, "claim-y", "test-err");
  } catch (err) {
    threw = true;
    expect(err instanceof Error && /broken handshake/.test(err.message)).toBe(true);
  }
  expect(threw).toBe(true);
  client.close();
});
