// NDJSON Unix-socket client. Connects to the QuickShow control socket,
// frames messages with newline delimiters, correlates responses to
// requests by `id`.
//
// Design notes:
// - Pending requests are tracked in a Map<id, {resolve, reject}>. The
//   app preserves the `id` on every response.
// - Partial reads are buffered and split on \n.
// - On unexpected disconnect, all pending requests reject with a
//   "socket closed" error.

import * as net from "node:net";
import { randomUUID } from "node:crypto";
import * as os from "node:os";
import * as path from "node:path";
import type { ControlRequest, ControlResponse } from "./protocol.ts";

export const DEFAULT_SOCKET_PATH = path.join(
  os.homedir(),
  "Library/Application Support/QuickShow/control.sock",
);

type Pending = {
  resolve: (response: ControlResponse) => void;
  reject: (err: Error) => void;
};

export class SocketClient {
  private socket: net.Socket | null = null;
  private buffer = "";
  private pending = new Map<string, Pending>();
  private connected = false;
  private connectingPromise: Promise<void> | null = null;

  constructor(private readonly socketPath: string = DEFAULT_SOCKET_PATH) {}

  async connect(timeoutMs = 5000): Promise<void> {
    if (this.connected) return;
    if (this.connectingPromise) return this.connectingPromise;

    this.connectingPromise = new Promise<void>((resolve, reject) => {
      const sock = net.createConnection(this.socketPath);
      const timer = setTimeout(() => {
        sock.destroy();
        reject(new Error(`socket connect timeout after ${timeoutMs}ms: ${this.socketPath}`));
      }, timeoutMs);

      sock.once("connect", () => {
        clearTimeout(timer);
        this.socket = sock;
        this.connected = true;
        sock.on("data", (chunk) => this.onData(chunk));
        sock.on("close", () => this.onClose());
        sock.on("error", (err) => this.onError(err));
        resolve();
      });

      sock.once("error", (err) => {
        clearTimeout(timer);
        reject(err);
      });
    });

    try {
      await this.connectingPromise;
    } finally {
      this.connectingPromise = null;
    }
  }

  isConnected(): boolean {
    return this.connected;
  }

  /** Send a request and await its correlated response. */
  async request(req: Omit<ControlRequest, "id"> & { id?: string }): Promise<ControlResponse> {
    if (!this.connected || !this.socket) {
      throw new Error("socket not connected");
    }
    const id = req.id ?? randomUUID();
    const message = { ...req, id } as ControlRequest;
    const line = JSON.stringify(message) + "\n";

    return new Promise<ControlResponse>((resolve, reject) => {
      this.pending.set(id, { resolve, reject });
      this.socket!.write(line, (err) => {
        if (err) {
          this.pending.delete(id);
          reject(err);
        }
      });
    });
  }

  close(): void {
    if (this.socket) {
      this.socket.end();
      this.socket = null;
    }
    this.connected = false;
    for (const { reject } of this.pending.values()) {
      reject(new Error("socket closed"));
    }
    this.pending.clear();
  }

  private onData(chunk: Buffer): void {
    this.buffer += chunk.toString("utf8");
    let nlIdx;
    while ((nlIdx = this.buffer.indexOf("\n")) >= 0) {
      const line = this.buffer.slice(0, nlIdx);
      this.buffer = this.buffer.slice(nlIdx + 1);
      if (!line) continue;
      this.handleLine(line);
    }
  }

  private handleLine(line: string): void {
    let parsed: ControlResponse;
    try {
      parsed = JSON.parse(line) as ControlResponse;
    } catch (err) {
      console.error(`[mcp-quick-show] failed to parse response: ${line}`);
      return;
    }
    const id = parsed.id;
    if (!id) {
      console.error(`[mcp-quick-show] response without id: ${line}`);
      return;
    }
    const waiter = this.pending.get(id);
    if (!waiter) {
      console.error(`[mcp-quick-show] response for unknown id ${id}`);
      return;
    }
    this.pending.delete(id);
    waiter.resolve(parsed);
  }

  private onClose(): void {
    this.connected = false;
    this.socket = null;
    for (const { reject } of this.pending.values()) {
      reject(new Error("socket closed"));
    }
    this.pending.clear();
  }

  private onError(err: Error): void {
    console.error(`[mcp-quick-show] socket error: ${err.message}`);
  }
}
