// Sidecar unit tests — NDJSON framing + request/response correlation.
// Run with: bun test
//
// Strategy: spin up a local Unix-socket listener that mimics the
// QuickShow control server (echoes back fixed responses), exercise
// SocketClient against it.

import { test, expect, beforeEach, afterEach } from "bun:test";
import * as net from "node:net";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import { SocketClient } from "../src/socket.ts";

let server: net.Server | null = null;
let socketPath: string;

beforeEach(() => {
  socketPath = path.join(os.tmpdir(), `qs-test-${process.pid}-${Date.now()}.sock`);
});

afterEach(() => {
  if (server) {
    server.close();
    server = null;
  }
  try { fs.unlinkSync(socketPath); } catch {}
});

function startServer(handler: (line: string, sock: net.Socket) => void): Promise<void> {
  return new Promise((resolve, reject) => {
    server = net.createServer((sock) => {
      let buf = "";
      sock.on("data", (chunk) => {
        buf += chunk.toString();
        let nl;
        while ((nl = buf.indexOf("\n")) >= 0) {
          const line = buf.slice(0, nl);
          buf = buf.slice(nl + 1);
          if (line) handler(line, sock);
        }
      });
    });
    server.once("error", reject);
    server.listen(socketPath, () => resolve());
  });
}

test("request/response correlation by id", async () => {
  await startServer((line, sock) => {
    const req = JSON.parse(line);
    const resp = { id: req.id, kind: "ok", result: { received: req.kind } };
    sock.write(JSON.stringify(resp) + "\n");
  });

  const client = new SocketClient(socketPath);
  await client.connect(2000);
  const r1 = await client.request({ kind: "ping" });
  expect(r1.kind).toBe("ok");
  expect((r1 as { result: { received: string } }).result.received).toBe("ping");
  client.close();
});

test("NDJSON framing handles split-across-reads buffers", async () => {
  // Server writes back the response one byte at a time to simulate
  // split reads on the client side.
  await startServer((line, sock) => {
    const req = JSON.parse(line);
    const resp = JSON.stringify({ id: req.id, kind: "ok", result: 1 }) + "\n";
    for (const byte of resp) {
      sock.write(byte);
    }
  });

  const client = new SocketClient(socketPath);
  await client.connect(2000);
  const r = await client.request({ kind: "ping" });
  expect(r.kind).toBe("ok");
  client.close();
});

test("multiple in-flight requests resolve correctly", async () => {
  // Server holds the first request, answers the second immediately,
  // then answers the first — verifies out-of-order responses still
  // correlate by id.
  const heldRequests: { line: string; sock: net.Socket }[] = [];
  await startServer((line, sock) => {
    const req = JSON.parse(line);
    if (req.kind === "slow") {
      heldRequests.push({ line, sock });
      return;
    }
    sock.write(JSON.stringify({ id: req.id, kind: "ok", result: "fast" }) + "\n");
    // Now release the held one.
    setTimeout(() => {
      for (const { line: held, sock: s } of heldRequests) {
        const r = JSON.parse(held);
        s.write(JSON.stringify({ id: r.id, kind: "ok", result: "slow" }) + "\n");
      }
      heldRequests.length = 0;
    }, 30);
  });

  const client = new SocketClient(socketPath);
  await client.connect(2000);
  const slow = client.request({ kind: "slow" } as never);
  const fast = await client.request({ kind: "ping" });
  const slowResp = await slow;
  expect((fast as { result: string }).result).toBe("fast");
  expect((slowResp as { result: string }).result).toBe("slow");
  client.close();
});

test("connect timeout fires when socket doesn't exist", async () => {
  const client = new SocketClient("/tmp/qs-this-doesnt-exist.sock");
  let threw = false;
  try {
    await client.connect(200);
  } catch {
    threw = true;
  }
  expect(threw).toBe(true);
});

test("pending requests reject on close", async () => {
  // Server accepts but never responds.
  await startServer(() => { /* no-op */ });
  const client = new SocketClient(socketPath);
  await client.connect(2000);
  const p = client.request({ kind: "ping" });
  client.close();
  let rejected = false;
  try { await p; } catch { rejected = true; }
  expect(rejected).toBe(true);
});
