# Pictionary

A drawing-guessing demo of the QuickShow **markup feedback loop**.
The user draws on the panel's markup overlay. Each time they hit
**Send**, the app flattens the strokes onto a PNG and Claude reads
it back to guess what they drew. No engine, no clever vision
pipeline — Claude just looks at the PNG and reasons about it the
same way it would about any image.

This is the markup-loop cousin of `tic-tac-toe.md` and `chess.md`
(which use `panel_event`). Those games carry structured payloads;
pictionary carries a *picture*. Pick this game when the user wants
to draw something freeform, not click cells.

## Setup (do this once at the start of a round)

1. **Confirm the rules briefly.** Default: user picks a word
   secretly and draws it; Claude guesses. Optional flavours the
   user can volunteer:
   - **Category constraint** — "it's an animal" / "it's a movie"
     narrows Claude's guesses.
   - **Letter count** — "5 letters" is a classic hint.
   - **Hot/cold rounds** — user signals after each guess; Claude
     iterates.
   Don't push for a structure they didn't ask for. If they just
   say "let's play pictionary", default rules are fine.
2. **Render the blank canvas:**

   ```
   show_html(name: "pictionary-canvas", content: <HTML below>, width: 800)
   ```

3. **Arm the markup channel:**

   ```
   enable_markup_events()
   ```

   The response includes a `Monitor` command pointed at the
   session's `events.ndjson`. **Start that Monitor as
   `persistent: true`** so each Send fires a notification.

4. **Tell the user to draw.** One short line: "Draw it and hit
   Send — I'll guess." Then wait. They'll click the ✏︎ in the
   title bar to enter draw mode, sketch their word, and click
   Send.

## The round loop

On every `markup_sent` line whose `panel === "pictionary-canvas"`:

1. **Fetch the PNG.** The line carries an `artifact` (or
   `artifact_id`) field — pass it straight to:

   ```
   get_markup(artifact_id: "<id>")
   ```

   The response is an image content block. Look at it.

2. **Guess.** One to three candidates, ranked by confidence,
   on one line. Keep it tight:
   - "A cat? Maybe a fox."
   - "Lighthouse."
   - "Plane, kite, or paper airplane?"

   If a category was set, constrain to it. If the user gave a
   letter count, prefer words that match.

3. **If you're stuck**, ask for one specific addition instead of
   guessing wildly: "More detail on the head?" / "Is that water
   underneath?" Don't drag this out — one ask, then they draw
   more and Send again.

4. **Wait for the next `markup_sent`.** If they add strokes and
   re-Send, the next PNG carries the *cumulative* drawing (strokes
   accumulate on the canvas until the panel is re-rendered).
   Re-guess with the new evidence.

5. **On a correct guess** the user will say so. Celebrate
   briefly ("Got it!"), offer another round, and on yes:
   - Re-render the same panel (`name: "pictionary-canvas"`) with
     the blank HTML — this clears the markup overlay and resets
     the canvas.
   - Wait for the next `markup_sent`. No need to re-arm markup
     events; the flag persists for the session.

## Important: do not peek

If the user reveals the word mid-round ("it's actually a duck"),
that's fine — but **don't try to derive the word from anything but
the picture**. Don't ask them to tell you. Don't infer from chat
clues they didn't intend as clues. The game is "guess from the
drawing", not "guess from context."

## HTML starter

A clean, generous canvas. The user draws on the markup overlay
that sits *above* the WebView, so the WebView content is just a
visual backdrop — keep it minimal.

```html
<!doctype html>
<html><head><meta charset="utf-8"><style>
  :root { color-scheme: light; }
  html, body { margin: 0; padding: 0; height: 100%; background: #fafaf7; }
  body {
    display: flex; flex-direction: column;
    min-height: 600px;
    font: 14px -apple-system, system-ui, sans-serif;
    color: #5b5b54;
  }
  .hint {
    padding: 8px 14px;
    border-bottom: 1px solid #e6e4dc;
    background: #f1efe7;
    color: #7a7770;
    letter-spacing: 0.02em;
  }
  .hint b { color: #2a2620; font-weight: 600; }
  .stage { flex: 1; }
</style></head>
<body>
  <div class="hint">
    <b>Pictionary</b> — tap the ✏︎ in the title bar to draw, then
    hit <b>Send</b>. I'll guess.
  </div>
  <div class="stage"></div>
</body></html>
```

That's it. The markup overlay handles strokes; the WebView is
basically a tinted backdrop with a one-line instruction. Don't
clutter it — the more the page draws, the more visual noise ends
up baked into the flattened PNG you'll be guessing from.

## Notes the agent should know

- **No `enable_panel_events`.** This skill is pure markup — Send
  is the only signal. No click bridge in the page.
- **One Monitor handles everything.** The events log carries
  `markup_sent` (the snapshot signal), `markup_dismissed` (user
  hit Close — round abandoned), and any `panel_event` from other
  skills if they're running. Filter on
  `type === "markup_sent" && panel === "pictionary-canvas"`.
- **The PNG includes the backdrop**, not just the strokes. The
  flattened image is the WebView visual + markup overlay. That's
  fine — the strokes dominate visually if the backdrop is plain.
- **Strokes accumulate until you re-render.** If you want a
  clean canvas mid-round (rare — usually you don't), re-render
  the panel. Otherwise each Send carries everything drawn so
  far.
- **Guess from the picture only.** It's tempting to use chat
  context. Don't.

## Etiquette

- **Keep guesses short.** One line, 1–3 candidates. No paragraphs
  of reasoning.
- **Don't lecture about the drawing.** "That's clearly a duck"
  reads as smug; "Duck?" reads as a game.
- **Acknowledge a good drawing** ("Nice — got it on the first
  try.") without sandbagging or gushing.
- **Concede when you're stuck.** After two or three failed
  guesses with no new strokes coming, ask for a hint or say "I
  give up — what was it?" Don't grind.
- **On a new round** re-render the panel to clear, then wait.
  Don't pre-guess.

## Limitations

- **No timer.** Casual play, no time pressure.
- **No scorekeeping** built in. If the user wants score tracking,
  keep it in your head and announce running totals occasionally.
- **Vision varies.** A clear sketch is easy; a cryptic squiggle
  is hard. That's the game — don't blame the user for ambiguous
  art, and don't pretend a wild guess was deduction.
- **Draw mode is exclusive.** While the user is in markup draw
  mode the in-DOM canvas captures pointer events, so the page
  itself can't be interactive. That's fine — this skill doesn't
  need page interactivity, only the snapshot.
