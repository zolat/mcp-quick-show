# Phase 2.7 — End-to-End Test Plan

Execute these scenarios against a real Claude session before merging
to main. Each scenario has explicit steps, expected outcomes, and a
diagnostic recipe if it fails.

Save state notes as you go — at the end, scroll to "Sign-off" and
record pass/fail per scenario.

## 0. Prerequisites & one-time setup

### 0a. Make sure the worktree's app is the one running

The worktree-built app and any installed (DMG) QuickShow both want
port 7890. Only one can run at a time.

```sh
# Kill any installed/Dock-launched QuickShow:
pkill -f "QuickShow.app/Contents/MacOS/QuickShow" 2>/dev/null
sleep 1

# Build + launch the worktree's app:
cd /Users/zolat/projects/mcp-quick-show/.claude/worktrees/feature+http-mcp-poc
xcodebuild -scheme QuickShow -configuration Debug build 2>&1 | tail -3
APP=$(xcodebuild -showBuildSettings -scheme QuickShow 2>/dev/null \
  | awk -F' = ' '/^[[:space:]]+BUILT_PRODUCTS_DIR = / {print $2}')
"$APP/QuickShow.app/Contents/MacOS/QuickShow" > /tmp/qs-e2e.log 2>&1 &
sleep 3

# Sanity check — port should be alive and tools should list:
curl -sf http://127.0.0.1:7890/mcp -X POST \
  -H "Content-Type: application/json" \
  -H "Accept: application/json, text/event-stream" \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"prep","version":"1"}}}' \
  -D /tmp/prep-headers.txt > /dev/null && \
  echo "OK: app responding at 127.0.0.1:7890"
```

Expected: `OK: app responding at 127.0.0.1:7890`. The menu-bar
QuickShow icon should be visible.

### 0b. Point Claude Code at the worktree's plugin

The worktree's `plugin/.mcp.json` is the only one with the new
HTTP transport + group-aware skill prose. Two ways to make Claude
use it:

**Option A — `/plugin` reinstall (clean):**

In a Claude session, run:
```
/plugin marketplace remove mcp-quick-show
/plugin marketplace add /Users/zolat/projects/mcp-quick-show/.claude/worktrees/feature+http-mcp-poc
/plugin install quickshow@mcp-quick-show
/restart
```

**Option B — direct `.claude.json` edit (faster but messier):**

Edit `~/.claude.json` and set the `quickshow` MCP server entry to:
```json
{
  "quickshow": {
    "type": "http",
    "url": "http://127.0.0.1:7890/mcp"
  }
}
```
Then `/restart` in Claude.

### 0c. Verify the right `.mcp.json` is active

In a Claude session in any project, run:
```
/mcp
```
Look for `quickshow` listed as an HTTP transport. If it shows as
`stdio` with a launcher path, you're still pointing at the old
plugin — re-do 0b.

### 0d. Wipe artifacts so each scenario starts clean

```sh
rm -rf ~/Library/Caches/QuickShow/events/* 2>/dev/null
rm -rf ~/Library/Caches/QuickShow/shares/* 2>/dev/null
```

(These regenerate as needed; nothing important lives here.)

### 0e. Tail the app log so you can see what's happening server-side

In a side terminal:
```sh
tail -F /tmp/qs-e2e.log | grep -E "QuickShow:"
```

Keep this open across all scenarios.

---

## 1. Load-bearing: `claude --resume` recall (the gate)

**What we're proving:** the skill prose mandates a memory-save
pattern. We need Claude to actually save a `group` slug to memory
on first use AND read it back on `--resume`, so the panel updates
in place rather than spawning a new HUD.

If this fails, the merge is blocked — the skill prose needs
tightening.

### Steps

1. Open a fresh terminal. Run `claude` (no `--resume`).

2. Prompt:
   > Render me a simple frontend-design mockup — a dark editorial
   > hero for a coffee co-op. Use the frontend-design skill.

3. **Observe**: Claude should
   - Pick a `group` slug (e.g. `coffee-coop-a3f`).
   - Save it to memory (look in `/memory` or via `/Read` of memory
     files — should see a new entry with the group value).
   - Render via `show_html(name=..., group=<slug>, width=...)`.
   - A floating HUD appears with the design.

4. **Capture the group slug** Claude chose. Write it down:

   `___________________________________`

5. **Exit** Claude with `/exit`. **Note the conversation id** (it's
   in the corner of the Claude prompt; also recoverable from
   `~/.claude/projects/<cwd-encoded>/`).

6. **`claude --resume`** — pick the same conversation from the list.

7. Prompt:
   > Update the mockup — make the accent color bright red instead.

8. **Observe**:
   - Claude should read the group back from memory **before**
     calling `show_html`.
   - The same HUD updates in place (no new tab, no second HUD).
   - The previous design's panel name is reused.

### Pass criteria

- ✅ Same HUD updates in place after resume.
- ✅ Server log shows the `show_html` from session 2 lands in the
  same group as session 1:
  ```sh
  grep "group .* flag\|markup-events subscribed group=" /tmp/qs-e2e.log | head
  ```
  Both sessions should reference the same group slug.

### Fail signatures

- ❌ A second HUD opens (group not recalled).
- ❌ Claude renders without `group=` (defaults to mcpSessionId,
  which differs between session 1 and session 2 → orphans the
  panel).

### Recovery if it fails

The skill prose probably needs to be more directive. Specifically:
- Check `plugin/skills/frontend-design/SKILL.md` step 1.
- Check `plugin/skills/quickshow/SKILL.md` "memory-save pattern"
  section.
- If Claude didn't save: tighten the prose to mention `memory.save`
  as a literal first-action item.

If the failure is intermittent (Claude saves sometimes, not
always), the prose isn't load-bearing enough — escalate to me and
we'll iterate before merge.

**Result:** ✅ pass  ⬜ fail  ⬜ partial  — group used: `coffee-coop-7a3f9c`

Follow-up: on `--resume` show_html into existing group, a fresh SpaceResolver
placement fires (`moved HUD … (was 1, parent_pid=14075)` at 21:01:32). Same HUD
updates in place, so the gate clears, but the doc claim that placement is
"first HUD create only" doesn't match the implementation — `ensurePrimaryHud`
seems to re-run placement on every show. Worth checking whether that's
deliberate (re-front + re-place) or a leak.

---

## 2. Markup loop via Monitor on `/markup-events`

**What we're proving:** the off-MCP `/markup-events` NDJSON endpoint
delivers `markup_sent` events to a Claude Monitor, and Claude can
fetch the resulting artifact.

### Steps

1. Fresh `claude` (or continuing from #1).

2. Prompt:
   > Render a simple HTML mockup with a big "click me" headline.
   > Enable the markup channel so I can draw on it. Use group
   > "markup-test".

3. **Observe**:
   - `show_html(group="markup-test", ...)` renders a HUD.
   - `enable_markup_events(group="markup-test")` is called.
   - Claude starts a Monitor with the `curl -sN -H "Mcp-Session-Id: markup-test"
     http://127.0.0.1:7890/markup-events ...` command.
   - The tool response includes the Monitor recipe; if Claude shows
     a "✓" indicating no warning, the Monitor IS already running.

4. In the HUD, click the markup ✏︎ button to enter draw mode.

5. Draw a circle around the headline. Click Send.

6. **Observe**:
   - The Monitor should pick up a JSON line like:
     ```
     {"type":"markup_sent","panel":"...","artifact":"<UUID>","group":"markup-test","ts":...}
     ```
   - Claude reads the line and calls
     `get_markup(artifact_id="<UUID>", group="markup-test")`.
   - Claude inspects the image (says something like "I see a red
     circle around the headline" or similar).

### Pass criteria

- ✅ The Monitor receives the `markup_sent` line within ~1s of
  pressing Send.
- ✅ `get_markup` returns the PNG; Claude describes the annotation.
- ✅ The artifact file moves to `.consumed/`:
  ```sh
  ls ~/Library/Caches/QuickShow/events/markup-test/artifacts/.consumed/ | head
  ```
  Should show the artifact UUID.

### Fail signatures

- ❌ Monitor sees nothing after Send → check armed flag:
  ```sh
  grep "markup_events_armed" /tmp/qs-e2e.log | tail -5
  ```
  Should show `flag markup_events_armed = bool(true)` for the
  group.
- ❌ Monitor sees the line but Claude doesn't react → Monitor isn't
  marked as `persistent: true` or is filtered too tightly.
- ❌ `get_markup` returns "no artifact named..." → group mismatch
  between `enable_markup_events` and `get_markup`.

**Result:** ✅ pass  ⬜ fail  ⬜ partial — group `markup-test`,
artifact `937c564a-3392-4ee1-be28-ffa12d5e9bf4` consumed at 21:11:52.

---

## 3. User-share migration

**What we're proving:** the user can open a HUD via the menu bar,
mark it up, hit Send, paste the resulting token into Claude, and
Claude's `get_share` migrates the HUD into the Claude session's
chosen group.

### Steps

1. From the QuickShow menu-bar icon, choose **Open URL…**. Enter
   `https://example.com`. A HUD opens with the page.

2. Click the markup ✏︎ button. Draw something. Click Send.

3. **Observe**: the title bar shows a `[quickshow-share:<id>]` token
   confirmation. The token is now on the clipboard.

4. In a Claude session, paste the token into a prompt:
   > [quickshow-share:abc123def456] What's in this?

5. **Observe**:
   - Claude calls `get_share(id="abc123def456", group="...")` with
     a sensible group slug (e.g. `claimed-share-<random>` or
     similar).
   - The HUD migrates: same window, but it's now a Claude-owned
     HUD (Send button gating changes from "always show" to
     "armed + draw mode").
   - Claude describes the marked-up content.

6. Prompt:
   > Update this panel — replace the content with the markdown
   > version of the same site.

7. **Observe**:
   - Claude calls `show_markdown(name="<panel-name>",
     group="<same-group>", content=...)`.
   - The same HUD updates in place to show markdown.

### Pass criteria

- ✅ The HUD migrates (was a user-share HUD; becomes a Claude HUD).
- ✅ Subsequent `show_*` calls update the same HUD when Claude
  passes the same `(name, group)`.
- ✅ A second `get_share` with the same id from a different terminal
  returns "share not available."

### Fail signatures

- ❌ `get_share` succeeds but Claude can't update the panel (group
  / name mismatch in subsequent calls).
- ❌ Source HUD doesn't migrate — server log:
  ```sh
  grep "claimed share\|claimShare" /tmp/qs-e2e.log
  ```
  Should show `claimed share <id> → group <targetGroup> panel '...'`.

### Optional add-on: simultaneous shares

Open TWO menu-bar shares (one URL, one Image), Send both, paste
both tokens into a Claude prompt. Claude should fetch each
independently. Tests the `claimShare` walk over multiple
`user-share-*` groups.

**Result:** ⬜ pass  ⬜ fail  ✅ partial — migration + in-place
update mechanics work end-to-end. Visual regression on the URL →
markdown swap leaves the panel blank until the user nudges zoom;
filed as P2 in `TECH_DEBT.md` ("Renderer-swap leaves panel blank
until user zooms"). Non-blocking for Phase 2.7 merge per user
call.

---

## 4. Parallel-Claude isolation (different groups)

**What we're proving:** two Claude sessions writing to different
groups land in distinct HUDs with independent placement (e.g.
each on the Space hosting its own terminal).

### Steps

1. Open Terminal A. Move it to **Space 1** (or wherever).
2. Run `claude` in Terminal A. Prompt:
   > Render a simple status panel with the text "Terminal A" in
   > group "team-a".

3. Open Terminal B. Move it to **Space 2**.
4. Run `claude` in Terminal B. Prompt:
   > Render a simple status panel with the text "Terminal B" in
   > group "team-b".

5. **Observe**:
   - Terminal A's HUD appears on Space 1 (next to Terminal A).
   - Terminal B's HUD appears on Space 2 (next to Terminal B).
   - Switching Spaces shows only the respective HUD; the other
     stays on its own Space.

### Pass criteria

- ✅ Two distinct HUDs.
- ✅ Each lands on its terminal's Space:
  ```sh
  grep "SpaceResolver" /tmp/qs-e2e.log | tail -5
  ```
  Should show two distinct moved-to-Space lines with different
  parent_pids.

### Fail signatures

- ❌ Both HUDs on the same Space — SpaceResolver may not be
  resolving the terminal correctly. Check:
  ```sh
  grep "PeerPidResolver\|SpaceResolver" /tmp/qs-e2e.log | tail -10
  ```

**Result:** ✅ pass  ⬜ fail  ⬜ partial — team-a HUD placed on
Space 1953 (parent_pid=19438), team-b HUD on Space 1
(parent_pid=20038). Distinct parent PIDs, distinct Spaces.

---

## 5. Parallel-Claude collaboration (same group)

**What we're proving:** two Claude sessions writing to the SAME
group share one HUD; second writer finds the existing HUD and
updates in place (no second placement).

### Steps

1. Terminal A (`claude`). Prompt:
   > Render a markdown doc titled "shared-doc" with intro content,
   > in group "design-review".

2. Terminal B (`claude` in a different conversation). Prompt:
   > Render an HTML mockup titled "shared-mock" with a hero
   > design, in group "design-review".

3. **Observe**:
   - Only ONE HUD opens (Terminal A's first call spawned it).
   - The HUD has TWO tabs: "shared-doc" and "shared-mock".
   - Terminal B's call did NOT spawn a new HUD or re-place the
     existing one.

### Pass criteria

- ✅ Single HUD with two tabs.
- ✅ Server log shows one SpaceResolver placement for the group
  (the first writer wins):
  ```sh
  grep "SpaceResolver.*design-review\|group design-review" /tmp/qs-e2e.log
  ```
  Only one `moved HUD` line.

### Fail signatures

- ❌ Two distinct HUDs spawn (group routing broken).
- ❌ HUD jumps Spaces after Terminal B's call (re-placement
  happened, plan says it shouldn't).

**Result:** ✅ pass  ⬜ fail  ⬜ partial — one HUD with two tabs.
First writer (pid 15692) triggered one SpaceResolver placement on
Space 1953; second writer (pid 20038, +8803 bytes show_html) joined
the same HUD without firing a new placement. First-writer-wins
holds.

---

## 6. Subagent PID resolution (fun/chess)

**What we're proving:** when a Claude session delegates to a
subagent (the `Agent` tool), the subagent's PID is what the HTTP
server sees on its MCP connection. PeerPidResolver must walk that
PID's ancestor tree and still find the parent terminal so
SpaceResolver places the HUD correctly.

### Steps

1. Fresh `claude`. Prompt:
   > Let's play chess. Use the fun/chess skill, in group
   > "chess-test".

2. Or: if chess.md is set up to delegate part of its work to a
   subagent (it doesn't out of the box, but the rendering itself
   goes through a fresh MCP call from the main Claude), use any
   skill that delegates via `Agent`. Example:
   > Spawn an Agent to render a status report on this repo. Have
   > the agent use show_markdown with group "subagent-test".

3. **Observe**:
   - The subagent's `show_*` call lands in the right group.
   - The HUD appears on the SAME Space as the parent terminal
     (not on a random Space — because PeerPidResolver walks up
     from the subagent's PID through Claude → terminal).

### Pass criteria

- ✅ HUD appears in the expected Space.
- ✅ Server log:
  ```sh
  grep "PeerPidResolver\|SpaceResolver" /tmp/qs-e2e.log | tail -10
  ```
  PeerPidResolver should resolve a PID, and SpaceResolver should
  find a non-nil Space.

### Fail signatures

- ❌ HUD spawns on the current Space (not the terminal's) — the
  ancestor walk didn't reach the terminal.
- ❌ `PeerPidResolver resolved_pid=nil` in the log.

**Result:** ✅ pass  ⬜ fail  ⬜ partial — HUD placed on the parent
terminal's Space (Space 1953). Note: `resolved_pid=15692` is the
parent Claude session's PID, suggesting the Agent tool runs
in-process rather than as a separate OS process. The terminal-walk
still works because Claude itself is in the ancestor chain of its
own MCP socket. If subagents ever move to separate processes (e.g.
a future Claude Code change), the walk would need to traverse one
extra level — current code already handles that via the multi-hop
sysctl walk, but worth re-verifying then.

---

## 7. Liveness sanity (DELETE + idle sweep)

**What we're proving:** ending a Claude session triggers the
orphan-grace badge after the grace window.

### Steps

1. Fresh `claude`. Render any panel.

2. Note the time. Exit Claude (`/exit` — sends DELETE).

3. Wait the orphan-grace window (default 60s; or set
   `QUICKSHOW_RECONNECT_GRACE_SECONDS=10` on app launch and wait
   10s).

4. **Observe**:
   - The HUD's title bar shows a `● session ended` badge after the
     window expires.

### Pass criteria

- ✅ Badge appears after the grace window.
- ✅ Server log:
  ```sh
  grep "orphan grace\|dropped" /tmp/qs-e2e.log | tail -5
  ```
  Should show `MCP session ... dropped — starting orphan grace`
  followed by `group ... orphan grace expired`.

### Idle sweep (optional)

If the user closes the terminal without `/exit`, the DELETE never
fires. The 60s cleanup loop should still sweep the session after
the idle timeout (default 5 min, or set
`QUICKSHOW_MCP_IDLE_SECONDS=15` on launch and wait ~75s):

```sh
grep "idle sweep" /tmp/qs-e2e.log
```

Should show `mcp http session idle sweep id=... idle_for=...s`
followed by the same orphan-grace cascade.

**Result:** ⬜ pass  ⬜ fail  ✅ partial — orphan-grace timer
cascade fires correctly on the server side. `group subagent-test
orphan grace expired — badge on 1 HUD(s)` logged at 21:42:19,
exactly 60s after the idle-sweep at 21:41:19. **However the
user-visible badge does NOT render on the HUD's title bar** —
verified via screenshot of the affected HUD post-expiry. Filed
as P2 in `TECH_DEBT.md` ("Orphan-grace badge doesn't render on
the HUD's title bar"). The orphan-state plumbing is correct;
only the title-bar paint is broken.

**Upstream finding (not a QuickShow bug):** Claude Code's `/exit`
does NOT send a `DELETE /mcp` on session teardown. Zero DELETE
requests appeared in the log across the entire E2E run. The
fallback path (idle-sweep after `QUICKSHOW_MCP_IDLE_SECONDS`,
default 300s) is what actually triggers the orphan-grace
cascade. End-to-end delay from `/exit` to badge is therefore
**~6 minutes (300s idle + 60s grace)**, not the ~60s the test
plan implies. Worth filing as tech debt — either lobby for
Claude Code to issue DELETE on `/exit`, or shrink the default
idle window. See `TECH_DEBT.md`.

---

## Sign-off

| # | Scenario                              | Result |
|---|---------------------------------------|--------|
| 1 | `claude --resume` recall (LOAD-BEARING) | ✅ pass |
| 2 | Markup loop via Monitor               | ✅ pass |
| 3 | User-share migration                  | ⚠ partial — see TECH_DEBT |
| 4 | Parallel-Claude isolation             | ✅ pass |
| 5 | Parallel-Claude collaboration         | ✅ pass |
| 6 | Subagent PID resolution               | ✅ pass |
| 7 | Liveness (DELETE + idle sweep)        | ⚠ partial — badge doesn't render |

**Run date:** 2026-05-22  
**Overall:** 5/7 pass + 2 partial. Gate (#1) clears.
Three follow-ups filed in `TECH_DEBT.md`:
- P2 — Renderer-swap blank panel (Scenario 3 visual regression)
- P2 — Orphan-grace badge doesn't render (Scenario 7 visual regression)
- P3 — Claude Code `/exit` skips DELETE → 6-min badge delay
  (Scenario 7 upstream finding)

Phase 2.7 is **ready to merge** per the test plan's "Overall gate"
criterion. All three follow-ups are non-blocking per user call.
Notable cluster: both P2s look like the same family of layout
race (view state mutation without forcing a synchronous layout
pass) — worth investigating together when picked up.

**Overall gate:** #1 must pass before merging. Others can pass
with caveats (each documented as a known follow-up rather than a
blocker, unless egregious).

If any scenario fails, capture the relevant `/tmp/qs-e2e.log`
section and the in-app behaviour, and we'll iterate.

## Cleanup after testing

```sh
pkill -f "QuickShow.app/Contents/MacOS/QuickShow"
# Optionally restore the production plugin path:
/plugin marketplace remove mcp-quick-show
/plugin marketplace add zolat/mcp-quick-show
/plugin install quickshow@mcp-quick-show
/restart
```
