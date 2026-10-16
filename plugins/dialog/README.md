# Dialog

A plugin of Replay's editor (`plugins/dialog`): `.dialog` files, what a
character says and what the player answers. A first take on mario's
`sample.dialog`: the format below is how it reads that sample; the open
questions are at the end.

- `files.lua`: which extensions open here (`dialog`)
- `config.lua`: its settings (`width`: a box's width)
- `editor.lua`: the chart (runs in Lite, on the canvas)
- `templates/dialog.dialog`: what *+ dialog* in the tree's `/assets` starts from
- the format, and how a game runs one: `runtime/dialog.lua` (one file for both)

## Using it

- A `.dialog` opens as a **chart**: the character's lines on the left, the
  player's answers beside the line that asks (blue wires), what comes next
  (grey arrows), the `#topic` lines below. Double-click a box: its line in
  the text. The tab's icon (or *Edit as text*) flips to the text, which Lite
  colours (`data/languages/language_dialog.lua`); the chart follows the text
  as you type.
- **Edit in the chart**: drag a box to move it (written as `//@dx,dy` at
  the end of its line; games ignore it). Drag from a box's right edge onto
  another line to link them (a line with choices gets one more, else its
  `-> N`); drop on nothing: a new line there, linked. RMB on a box: *Add
  answer*, *Add next line*, *Unlink*, *Delete line*, *Reset position*; on
  the background: *New line*, *New #topic*. Every edit is a text edit:
  Ctrl+Z / Ctrl+Y undo and redo, Ctrl+S saves, Delete removes the selected
  box. New lines say `...`: double-click to write them.
- A game reads one with `w:dialog("fairy.dialog")` (from its `assets/`) and
  runs it: `d:begin(st)`, `d:update(st, dt, cps)` (typed out), `d:typed(st)`,
  `d:choices(st)`, `st.pick`, `d:advance(st)`. `st` is plain data: keep it in
  the world (it saves and rewinds). `games/fairyland/` is the demo.

## The format

```
0 Hi! Is this your first visit? [1,2]   line 0, said; the player picks line 1 or 2
1 Yes, I just arrived -> 3              a line, then line 3 (an answer: picking it goes there)
3 Awesome! Have fun!                    no arrow: the conversation ends after it
--                                      the end of a conversation (--- too)
4 Hey, welcome back -> 5                5 is past a `--`: this talk ends, the next one starts at 5
12 Please! -> 5                         back up: this talk ends, the next one starts at 5
13 Oh hi -> 13                          leads to itself: every talk from now on is this line
#monster It is said... {...} Scary!     the answer to "Tell me more about monster"
```

In a line: `#word` a topic (hearing it, the player learns it; a game can
teach one too, e.g. an item carried), `:grin:` an emote (the character shows
it), `{...}` three dots, slowly, `{wait 2}` a 2 s pause, `// ...` a comment.

When a conversation ends and the player knows topics, they can ask *Tell me
more about <topic>* (its `#topic` line answers), as many as they like, or
say *Bye* (`M.ASK` and `M.BYE` in runtime/dialog.lua: the wording).

## Open questions (for mario)

- Several characters in one file (a name per line)?
- Conditions beyond topics (an item given, a flag set by the game), and
  lines that set them.
- Writing a line's text in the chart itself (today: double-click, the text).
