// Verifies the `withReconnect()` helper used by index.ts to keep MCP
// tool dispatch alive across a QuickShow app restart. The helper
// runs the operation, and on a dead-socket error reconnects (via a
// caller-supplied closure) and retries exactly once. Other errors
// propagate unchanged; the helper never loops.
//
// Some tests use a fake Unix-socket server to drive a real
// SocketClient through close/reconnect; others test the helper's
// behaviour in pure isolation by feeding it synthetic errors.

import { test, expect, beforeEach, afterEach } from "bun:test";
import * as net from "node:net";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import { SocketClient } from "../src/socket.ts";
import { withReconnect, isSocketDeadError } from "../src/reconnect.ts";

let server: net.Server | null = null;
let socketPath: string;

beforeEach(() => {
  socketPath = path.join(os.tmpdir(), `qs-reconnect-${process.pid}-${Date.now()}.sock`);
});

afterEach(() => {
  if (server) {
    server.close();
    server = null;
  }
  try { fs.unlinkSync(socketPath); } catch {}
});

/// Server that replies `ok` to ping and ALSO drops the socket after
/// the first reply. The second connect will be served by a freshly
/// accepted socket on the same listener — exactly the shape of a
/// QuickShow app restart (control.sock relisten).
function startKickAfterPingServer(): Promise<void> {
  return new Promise((resolve, reject) => {
    let connections = 0;
    server = net.createServer((sock) => {
      connections += 1;
      const isFirst = connections === 1;
      let buf = "";
      sock.on("data", (chunk) => {
        buf += chunk.toString();
        let nl;
        while ((nl = buf.indexOf("\n")) >= 0) {
          const line = buf.slice(0, nl);
          buf = buf.slice(nl + 1);
          if (!line) continue;
          const req = JSON.parse(line);
          sock.write(JSON.stringify({ id: req.id, kind: "ok", result: { conn: connections } }) + "\n");
          if (isFirst) {
            // Drop the FD straight after replying — simulates the app
            // being killed mid-session right after handling a call.
            setTimeout(() => sock.destroy(), 5);
          }
        }
      });
    });
    server.once("error", reject);
    server.listen(socketPath, () => resolve());
  });
}

test("isSocketDeadError matches the two SocketClient lifecycle errors", () => {
  expect(isSocketDeadError(new Error("socket not connected"))).toBe(true);
  expect(isSocketDeadError(new Error("socket closed"))).toBe(true);
  expect(isSocketDeadError(new Error("render error: timeout"))).toBe(false);
  expect(isSocketDeadError(new Error("hello rejected: broken handshake"))).toBe(false);
  expect(isSocketDeadError("not an error object")).toBe(false);
  expect(isSocketDeadError(undefined)).toBe(false);
});

test("withReconnect returns the value without retrying when fn succeeds", async () => {
  let reconnectCalls = 0;
  let fnCalls = 0;
  const result = await withReconnect(
    async () => {
      fnCalls += 1;
      return 42;
    },
    async () => {
      reconnectCalls += 1;
    },
  );
  expect(result).toBe(42);
  expect(fnCalls).toBe(1);
  expect(reconnectCalls).toBe(0);
});

test("withReconnect rethrows non-socket errors without reconnecting", async () => {
  let reconnectCalls = 0;
  let fnCalls = 0;
  let threw = false;
  try {
    await withReconnect(
      async () => {
        fnCalls += 1;
        throw new Error("render error: something blew up");
      },
      async () => {
        reconnectCalls += 1;
      },
    );
  } catch (err) {
    threw = true;
    expect(err instanceof Error && /render error/.test(err.message)).toBe(true);
  }
  expect(threw).toBe(true);
  expect(fnCalls).toBe(1);
  expect(reconnectCalls).toBe(0);
});

test("withReconnect calls onReconnect and retries fn exactly once on socket-dead error", async () => {
  let reconnectCalls = 0;
  let fnCalls = 0;
  const result = await withReconnect(
    async () => {
      fnCalls += 1;
      if (fnCalls === 1) throw new Error("socket closed");
      return "ok-on-retry";
    },
    async () => {
      reconnectCalls += 1;
    },
  );
  expect(result).toBe("ok-on-retry");
  expect(fnCalls).toBe(2);
  expect(reconnectCalls).toBe(1);
});

test("withReconnect does not loop — second failure propagates as-is", async () => {
  let reconnectCalls = 0;
  let fnCalls = 0;
  let caught = "";
  try {
    await withReconnect(
      async () => {
        fnCalls += 1;
        throw new Error("socket not connected");
      },
      async () => {
        reconnectCalls += 1;
      },
    );
  } catch (err) {
    caught = err instanceof Error ? err.message : "";
  }
  expect(caught).toBe("socket not connected");
  // fn called once, retried once → 2 total. No third attempt.
  expect(fnCalls).toBe(2);
  expect(reconnectCalls).toBe(1);
});

test("withReconnect surfaces onReconnect errors verbatim (e.g. handshake mismatch)", async () => {
  let fnCalls = 0;
  let caught = "";
  try {
    await withReconnect(
      async () => {
        fnCalls += 1;
        throw new Error("socket closed");
      },
      async () => {
        throw new Error(
          'wire-protocol mismatch — app reports version "0.1" but sidecar expects "0.2".',
        );
      },
    );
  } catch (err) {
    caught = err instanceof Error ? err.message : "";
  }
  expect(/version "0\.1"/.test(caught)).toBe(true);
  expect(/expects "0\.2"/.test(caught)).toBe(true);
  // fn only got the first try; reconnect threw before retry could happen.
  expect(fnCalls).toBe(1);
});

test("withReconnect drives a real SocketClient through a fake app restart", async () => {
  // End-to-end: real SocketClient + a server that drops the FD after
  // the first reply. The wrapped operation should observe "socket closed"
  // on its second call, the reconnect closure makes a fresh connection,
  // and the retry succeeds against the new accepted socket.
  await startKickAfterPingServer();

  const client = new SocketClient(socketPath);
  await client.connect(2000);

  // First call: succeeds normally. Server then drops the FD.
  const r1 = await client.request({ kind: "ping" });
  expect(r1.kind).toBe("ok");

  // Wait one tick for the close to propagate so the next call sees
  // a dead socket — deterministic for this test.
  await new Promise((r) => setTimeout(r, 30));
  expect(client.isConnected()).toBe(false);

  let reconnectCalls = 0;
  const reconnect = async () => {
    reconnectCalls += 1;
    await client.connect(2000);
  };

  // Second call goes through the wrapper. The first attempt should
  // throw "socket not connected" (or "socket closed" if already in
  // flight), reconnect, and retry against the freshly accepted socket.
  const r2 = await withReconnect(
    () => client.request({ kind: "ping" }),
    reconnect,
  );

  expect(r2.kind).toBe("ok");
  expect(reconnectCalls).toBe(1);
  expect(client.isConnected()).toBe(true);

  client.close();
});
