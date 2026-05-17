// Tiny retry helper used by index.ts to make MCP tool dispatch
// transparent to a QuickShow app restart mid-session.
//
// Before this existed, a `pkill QuickShow && open QuickShow.app` left
// the sidecar holding a dead FD; every MCP call returned
// "socket not connected" until Claude itself was restarted.
//
// Extracted from `main()` so the dead-socket detection + single-retry
// boundary can be unit-tested without standing up the full MCP server.

/// True iff `err` looks like a control-socket lifecycle failure that a
/// reconnect would address. Matches the two strings SocketClient throws:
/// `socket not connected` (no live FD when request() ran) and
/// `socket closed` (FD was closed mid-flight). Kept narrow — other
/// errors (parse failures, render errors, protocol errors) are upstream
/// problems that retrying wouldn't fix.
export function isSocketDeadError(err: unknown): boolean {
  if (!(err instanceof Error)) return false;
  return /socket (not connected|closed)/.test(err.message);
}

/// Run `fn()`; if it rejects with a dead-socket error, run
/// `onReconnect()` (re-establish connection + re-handshake) and then
/// run `fn()` exactly once more. All other errors propagate unchanged.
/// Bounded to one retry on purpose — never loops.
///
/// If `onReconnect()` itself throws, that error propagates (the
/// rebuild-and-relaunch case from `helloHandshake` lands here, which
/// is what we want — the user must see it).
export async function withReconnect<T>(
  fn: () => Promise<T>,
  onReconnect: () => Promise<void>,
): Promise<T> {
  try {
    return await fn();
  } catch (err) {
    if (!isSocketDeadError(err)) throw err;
    await onReconnect();
    return await fn();
  }
}
