# Roadmap

Was CLAUDE-IDEAS.md (renamed 2026-10-15): for now still the list of what's open,
grouped by area, the ones I'd do first at the top of each group; to become the
planning document (what's next, in what order). What's built moved to FEATURES.md.

> **p2p is for the games, not the editor** (mario, 2026-10-06). Nobody edits a shared
> world together with confidence (privacy, stress, competition, stalkers, bullying).
> Editing stays solo; what travels between players is the game. Admin review of other
> games' patches is the one exception: a reviewer looks at a patch, never a live session.



## Done since the first list (details in FEATURES.md)

- LOD
- Splits
- Breakpoints
- Doc tooltips
- Flow pulse
- Autoconversion
- Find references
- Values on wires
- Property editor
- Collapsible nodes
- Go to definition
- Collapse to function
- Snapshots on a timeline
- Profiler in the tree tab
- Graph diff, session sketch
- Play with unsaved editor files
- Load-time breakpoints (main script)
- Relative paths, `/` everywhere
- Players: 1..4 in split views, replication by tags
- Replicas over net.sim (scoped ownership, snapshot deltas)



## Open: editing loop

1. Create / delete / rename / duplicate nodes from the tree (RMB menu). For folder worlds
   these are folder and file operations; for script worlds, an edit of the script's text.
2. Drag nodes in the game view to move them (ALT = rotate, wheel = scale), written back to disk.
3. Search / filter box on the tree: `ship*`, `/scene/**` (the patterns `ecs.select` has).
4. Undo per node across saves: each save keeps its reverse patch.
5. Error overlay per node: a failing system marked red in the tree, a click opens the line.
6. Step mode: advance one tick while paused (F10 already steps lines at a breakpoint).



## Open: node graph

1. Reroute knots, align / tidy selected.
2. vec3 / vec4 types.
3. Snippets: a selection saved as a menu item.
4. Breakpoints on nodes (today: on lines, shown on nodes).
5. Load-time breakpoints in modules other than the main script (they run once, at require).
6. Probe hook cost: only files with an open graph are hooked; measure on big games.
7. A module map: the files of a game as nodes, `require` as wires.



## Open: graph diffs (mario's spec, 2026-10-05; session part sketched)

Built: a history per document ("N changes", teal, top-right), undo / redo aware; a click
diffs that state against now on the current graph (added green, changed amber, removed
red ghosts, moved at 25%). Left:

- **The git half of the list**: `git log --follow` of the file under the session's states.
- **Pick a range** (click + shift-click) and diff its two ends, not only "that state vs now".
- **A 2-way view in its own tab**: old left, new right, scroll and zoom in step; a text
  2-way view as the fallback (and for non-Lua files). This is the first editor plugin.
- **Later**: the same view reviews a peer's patch (admin nodes), and "revert this hunk".
- **Open questions**: git from where (a `git` on PATH, or reading `.git`); a moved node's
  pairing when its title changed.



## Open: editor plugins, each in its own tab (mario, 2026-10-06)

- A plugin is Lua that runs and renders in its own lite tab, like the node graph (a View:
  update / draw / input, get_state for the workspace). Candidates: the graph diff,
  animation graphs, mesh viewer, terrain tools.
- What it needs from us, kept small: a folder (`plugins/<name>/init.lua`), a way to open its
  tab for a file or a node (RMB menus, a file type), the host bridges (probe, breakpoints,
  world file, the world's tree).
- Open question: drawing beyond lite's 2D, i.e. a texture from the game renderer drawn
  into the tab (meshes, terrain).
- Built 2026-10-15: `hexedit` (any size, 1 MiB chunks), `particles` (.pfx, presets),
  `sfxr` (.sfx, the original synth ported to Lua, presets). Their tabs share
  `canvas.ui` (a side panel: sliders, checkboxes, choices, colours, buttons).

### Next plugins (annotated, mario 2026-10-15)

Built 2026-10-15: a simple **tilemap editor** (`plugins/tilemap`: tiles, layers, a stamp,
rect, fill, a CC0 tileset of our own). Still open from the map editor below: auto-tiles,
splines, areas, the TMX importer, heightmap brushes.


**Map editor** (`.map`; inspiration: Sean Barrett's stb_tilemap_editor.h, public domain:
its layers, the palette on the side, properties per tile, its undo buffer).
- Tiles: a tileset (an atlas or one picture cut in N x N cells), layers, paint / erase /
  fill / pick / rectangle, flip and rotate per cell, a property bag per tile kind
  (solid, damage, a class to spawn: `/classes/...`).
- Auto-tiles: a tile kind that picks its picture from its neighbours (the 4-bit and 8-bit
  47-tile "blob" rules; Wang tiles later), so walls, water and paths draw themselves.
- Splines: Catmull-Rom / Bezier paths as nodes (roads, rails, patrol routes), sampled into
  the game as points; tiles can be stamped along one.
- Areas: polygons and rectangles with a name and properties (spawn zones, triggers,
  camera bounds, music regions): the game gets them as nodes with a `shape`.
- TMX importer: Tiled's `.tmx` / `.tsx` (XML; CSV, base64 and zlib/gzip layer data;
  object layers -> areas; tile properties) into a `.map`.
- Heightmap brushes, even though the view is 2D: a height per cell (raise, lower, smooth,
  flatten, noise; brush size and strength), drawn as shading / contour lines, and kept for
  a 3D view, lighting, or line-of-sight later.
- Predefined tiles: a 256 x 256 sheet of 16 x 16 tiles in the layout of Minecraft
  classic's terrain.png (grass, stone, dirt, wood, water, lava, sand, leaves, glass ...).
  Not Minecraft's own pictures (Mojang's, not ours to ship): our own, or a CC0 set
  (Kenney's), drawn to the same grid so its slots and auto-tile rules match.
- The game side: a `tilemap` component that draws a `.map` (one draw per visible chunk,
  the atlas's sheet) and answers `solid(x, y)` / areas for systems.

**Sequencer** (`.seq`): a timeline of tracks (a node's property keyed over time with
curves; events: play a `.sfx`, emit a `.pfx`, call a system; camera moves), scrubbed with
the game paused, played by a `sequence` component. Cutscenes, attract modes, a level's
scripted moments. Shares the timeline's look with the editor's own bar.

**Viewers that edit**: meshes (`.obj`, `.gltf`/`.glb`: wireframe and flat shaded in lite's
2D for now, orbit, the bounds, the counts; LODs listed, generated by simplification, the
distance each switches at), animated meshes (skeletons, clips: play, scrub, rename, trim,
loop, blend times) and Aseprite files (`.ase`/`.aseprite`: layers, frames, tags as clips,
durations; edit tags and timing, export to an atlas with the frames named for the game).
All need the open question above for a real 3D view: a texture from the game renderer.



## Open: other languages (annotated 2026-10-06)

- **hurdy**: stays as it is (code leaves, `.hurdy` files, syntax highlighting). Not
  integrated further for now: no graph, no breakpoints in hurdy.
- **TypeScript → Lua, at some point** (mario). Likely TypeScriptToLua (tstl). It's a Node
  tool, so it's a build step outside the process, not an in-process compiler like hurdy:
  `.ts` saved → tstl → `.lua` next to it (or in a cache) → our hot reload picks it up.
- What any language needs, per language:
  1. a compiler to Lua (in-process via `ecs.languages[ext]`, or external as above);
  2. a line map (Lua line → source line) for errors, breakpoints, the probe;
  3. a rule for an `ecs.system` body in that language;
  4. lite syntax highlighting.
- The node graph stays Lua-only; a transpiled file could be shown as the Lua it became,
  read-only.



## Open: multiplayer, still simulated

Built (2026-10-06): the Players button (1..4, RMB quarters toggle anyone, player 1
too: a server alone), split views by quarter over net.sim, the Network button (0..100%,
5 presets blended), ownership by tags that changes hands (`by = 2`: player 2's while it
plays), prediction per node (`predict = true`, corrected by the owner's states).

### Network plan (after Gabriel Gambetta's "Fast-Paced Multiplayer", 2026-10-06)

His series, in one line each: (I) the server is the authority, clients send inputs and
draw what it says; (II) the client predicts its own player from its inputs, numbers them,
and when the server's state comes back (with "the last input I applied") resets to it and
replays the inputs not yet applied; (III) everyone else is drawn in the past, interpolated
between the two last server states, never guessed; (IV) the server judges an action (a
shot) against the world as the shooter saw it: rewound by its lag and interpolation delay.

Where we are against that: (I) yes, the host is authoritative for `by = 1`, and a player
for what it owns. (II) partly: we predict, but by comparing with our own guess from "half a
round trip ago" (a guess of the age), with no input numbers and no replay; inputs travel as
held-key *state*, so a tap shorter than one send can be lost. (III) no: what isn't
predicted snaps to each new state. (IV) no, but the timeline already keeps the past.

The plan, easiest first:

1. ~~**Ghosts**~~ (built 2026-10-09: the Network menu, RMB): in each peer's view, the owner's last state drawn faint (Gambetta's demo
   "show server positions"), toggled from the Network tooltip / RMB. Needed to see
   everything below.
2. ~~**Per-player links**~~ (built 2026-10-09: P1..P4 line in the Network menu; `sim:link`): each player's own quality (one on a bad link), and cut / heal a
   link (net.sim has `cut` / `heal`). The quarter of the Network icon under the mouse?
3. ~~**Send rate**~~ (built 2026-10-09: default 20/s, the Network menu; `replica.rate`): owners send at N Hz (default 20), not every tick; the Network tooltip
   shows it. Makes (5) visible and saves bandwidth.
4. ~~**Frame stamps**~~ (built 2026-10-15: times and the clock offsets; fixed 60 Hz ticks in a session, numbered by each peer's commands; "clock" messages say which time of yours I show and my latest command): every patch carries the owner's tick number and game time; each peer
   keeps the offset to every other peer's clock (from patch / ack pairs). The base for 5-8.
5. ~~**Interpolation**~~ (built 2026-10-15: `interp = true`, by the sender's time, `snap`; pong and asteroids use it for other players) (`replicate = { interpolate = true }`): non-owners keep the last
   timestamped states and show the node between two of them, one send interval (+ jitter)
   in the past. For what isn't predicted (others' paddles in a game with free movement).
6. ~~**Inputs as numbered commands**~~ (built 2026-10-15: `{ by = N, cmd = true }`, resent until acked, one a tick on the host, `ack` in each state) **Inputs as numbered commands**: a player's input node becomes a short list of
   `{ seq, held }` since the owner's last ack, applied by the owner one per tick in order;
   the owner's states say the last seq it applied per player. No tap is lost.
7. ~~**Reconciliation**~~ (built 2026-10-15: `{ by = 1, input = N }`, `w:rerun`; pong's paddles, asteroids' ships) **Reconciliation** (`predict = "inputs"`): for nodes driven by my inputs but owned by
   the host: on the owner's state, reset to it and re-run the node's per-node systems for
   my inputs it hasn't applied (needs a `w:tick` that runs per-node systems only, on one
   subtree: no once-systems, no side effects). Deterministic enough for pong; documented
   limits (randomness, other players' interference).
8. ~~**Exact age for the rest**~~ (built 2026-10-15: the sender's stamp on our clock; plus the star) **Exact age for the rest**: `predict = true` (the ball) compares with our guess at the
   owner's stamped frame instead of half the round trip: no bias at bounces.
9. ~~**Events, not state**~~ (built 2026-10-15: `w:event`, `on_event`, net `events`; asteroids' sparks) **Events, not state**: one-shot reliable messages (a sound, "left wins", a hit) from the
   owner only, so peers don't predict them (today a peer that simulates the ball would log
   its own "wins"). Irreversible things (a score, a death) wait for the owner (they do now).
10. ~~**Bandwidth**~~ (built 2026-10-15: component deltas, interest per scope, priorities + budget, lean commands; field-level and per-node interest not yet) **Bandwidth**: send only the scopes a peer cares about (interest: distance, view),
    priorities per scope, field-level deltas (now: node-level), measured in the tooltip.
11. ~~**Lag compensation**~~ (built 2026-10-15: `w.net:as_seen`, `seen`, `hold`; pong's ball judged by what player 2 saw) **Lag compensation**: an action carries the player's view time (its frame minus its
    interpolation delay); the host rewinds the nodes involved to that time (from the
    timeline's snapshots), judges the action there, applies the result now. Favors the
    shooter, as he notes.
12. **Real transport**: UDP sockets, then WebRTC data channels, behind net.sim's endpoint
    interface (id, send, recv); a relay for NATs that refuse.
13. **Host migration**: the host leaves, another player takes `by = 1` (it has the world:
    it predicted it), the others reconnect to it. The p2p step: no server to keep.
14. **Trust**: the host validates inputs (speeds, rates), patches are signed, admin nodes
    review other games' patches (never their own): the proposal queue below.

**Next (decided 2026-10-15): classic multiplayer first, p2p much later.** (6) numbered
inputs and (7) reconciliation are built (2026-10-15), on fixed 60 Hz ticks; (8) exact
ages for the rest (the ball) is next, with a real star (below). With them the topology becomes a star: players send inputs to the host
only, the host simulates and sends everyone the state (today: a mesh, each owner sends
its own nodes to all). p2p (host migration, trust, no host) comes after, when lag
compensation, interpolation, reconciliation and prediction are solid.

Later, apart from the plan:
- Proposal queue for admin nodes: edits to shared nodes become pending patches; an admin
  (never one of that game's own) views the diff and accepts or rejects it.
- Ownership colouring in the tree (mine / peer / shared / admin-reviewed): game data,
  not live co-editing.
- Peers' debug draw in their own views (now: the host's only).
- Enforce reloads every received scope each tick, and prediction keeps a copy per tick:
  fine for pong, measure on big games.



## The layout (agreed 2026-10-07; long names 2026-10-07)

`/assets` asset folders, `/data` everything else, `/classes` components' defaults,
`/objects` (saved), `/systems` (a node each, its order), `/entities` (spawned while
playing, never on disk), `/tmp` temporaries (never saved / sent). Built: the engine
rules, pong, snake, scene1 and scene2 (script and folder; the ships shoot: /entities/shots),
the tests, the new-project template, the tree (every root, in that order; +/-
branches; /classes dimmed, /entities /tmp marked). Next:
1. The property panel and /classes: inherited fields, differs, types kept, "used by",
   members described ({ type, value, min, max, options, container, values }: no
   more `meta`), the class panel (a block per member: rename / remove, type, kind,
   values drop-downs, default, min / max, options), + member (a name: a bool),
   + class, built-in int/number/string/bool/color, collections (+ item, + key, RMB
   out), the graph reading /classes, nodes' own typed fields (meta), + object /
   + data / + child, + system, the tree's menu (rename / duplicate / delete), the
   graph reading a node's meta. Next: node-typed fields following a renamed node
   (today they keep the old path), drag a node onto another parent (re-parent), keys of a class type (sets / maps),
   member order (today: by name; UE keeps the order you made them in), a member's
   tooltip / description text, a class extending another live (today "boss ship"
   copies once; a `base = "ship"` could keep boss following ship's upgrades), LuaLS
   annotations generated from /classes (editor autocomplete for students), a colour picker
   (the graph has one: share it once the tab is a lite view), a vec2 type (x, y as
   one row), a class's fields edited apply to nodes that don't override them
   (done: never-overridden values upgrade), "remove this component", overrides
   tracked explicitly (today: "differs from the class" decides, so setting the very
   same value doesn't pin it). Asset folders
   (`/assets/player`: one item, its files and their kinds listed; nodes refer to
   them by path, later by hash).
2. Draw order (see below).

"Classes" for students (mario, 2026-10-07): a class here is a component's defaults
(`/classes/shot` = what every `shot` starts with), data only, no functions, and a
node can have several. Close enough to what students expect from a class (a
blueprint) to be the friendlier word; the docs say "a class = a component's
defaults" once, and the code keeps `n.c` (components).

### Draw order (discussed 2026-10-07; built 2026-10-15 without y-sort and /classes defaults)

Today: tree order (the live roots /entities then /objects, then each subtree by rank
and name), so /entities (bullets) draws under /objects. Proposal, like /systems' order:
- A `layer` component (a name), inherited down the tree (a ship's flame is in its
  ship's layer unless it says otherwise). Unset: "default".
- One list gives the layers' order: `/data/layers = { "bg", "default", "fx", "hud" }`,
  shown in the tree and dragged to reorder like /systems. Unlisted layers after, by name.
- Within a layer: tree order. Later, per layer: `{ "units", sort = "y" }` (2D y-sort)
  or `z` for the odd exception.
- /classes gives defaults, not the order: `/classes/bullet { layer = "fx" }` and every
  spawned bullet is in fx. Sorting /classes or /assets themselves would tie order to
  types, but one type can need two layers (a ship and its shadow) and two of its
  instances can differ.
- Picking follows for free: after `bounds` (smallest first), it takes the last drawn.

### scene2 as an Asteroids clone (mario, 2026-10-07: later; built 2026-10-09 as games/asteroids, see FEATURES.md)

The solar system as the background; the player's ship against other ships and
asteroids that split at every shot (big -> 2 medium -> 2 small -> gone). Fits the
layout: `/classes/asteroid` (size, hp), `/entities/rocks/*` and `/entities/shots/*`,
systems `collide` (shots vs rocks / ships), `split`, `wrap` (leave one edge, come
back at the other). A good first multiplayer game too (two ships, `by = N`).

### The left tab as a lite view (asked 2026-10-07, not built)

Option B was built first (2026-10-08): the C tab draws with lite's font and theme
(editor/ui.h, editor/editor.c editor_ui_*); then the main menu, the console and the
timeline (2026-10-08, with the dark / light Theme setting). Still debug-font: the
picker at launch, the dev overlays (stats, picking, click log).

Drawing the tree + properties in a lite View (like the node graph) instead of SDL's
debug font: lite's fonts and colours, docking, splitting, closing, the workspace
keeps it. The data side is ready (viewer_outline, viewer_props are Lua in the game's
state); the work is the bridge and the input:
- Two Lua states: the tab's data lives in the viewer's state, lite runs in its own.
  A host function (like host_probe for the graph) hands lite a snapshot per frame:
  rows (text, kind, shape), selection, props rows; and takes actions back (select,
  fold, set a value, drag to reorder, save / undo). ~20 calls, all exist in C today.
- A TreeView + PropsView in lite (~600 lines: rows, lines and boxes, scrolling,
  editing a value in place, scrubbing numbers, drag & drop); what tab.h does in C.
- The viewer's tab goes away; the game area takes the window's left side.
- Costs: per-frame copying of what's visible (cheap: only visible rows); the game-only
  view (editor hidden) would have no tree unless we keep the C one for it.
- About 2-3 days. Worth it once the tab grows more widgets (/classes types, asset
  folders): those want real text input and fonts.

## Open: ECS core, worth taking from tiny-ecs (compared 2026-10-14)

tiny-ecs (bakpakin/tiny-ecs, MIT, one file): entities are plain tables, systems
pick them with filters and keep their own cached lists. Ours is a world model
first (paths, folders on disk, snapshots, diffs, replication, live code); its
speed and its system API are what's worth borrowing, on top of our paths,
without changing the file format:

1. ~~**Filters with cached lists.**~~ (built 2026-10-15) A system may declare
   `filter = { all = { "xform", "vel" }, none = { "frozen" } }` (and `any`);
   the world keeps each such system's matching nodes, updated when a node
   gains or loses a component (spawn, remove, a component set to nil), so a
   tick walks a list instead of `w:select` + checks. Path globs stay for
   what's about place (`/objects/*`). Measure first: asteroids' AI vs AI
   test (runtime/tests/asteroids.lua) as the benchmark, then a stress world
   of a few thousand entities.
2. ~~**onAdd / onRemove per system.**~~ (built: on_add / on_remove) Called when a node enters / leaves its
   filter (an explosion when a rock is removed, a sound when a ship spawns).
   Must be deterministic (p2p, the timeline): in the cached list's order.
3. ~~**Deferred structure changes.**~~ (built: lists worked out between systems) Spawns and removes during a tick are
   queued and applied between systems (or at the tick's end), so a system
   can remove what it's iterating. Today that works by luck (w:children
   copies); make it a rule, and say which: between systems is what tiny-ecs
   does (world:refresh).
4. ~~**interval.**~~ (built) `interval = 0.5` on a system: it runs every 0.5 s of game
   time, with the time since its last run as dt (spawners, AI thinking,
   autosave). Game time, not wall time: replays and peers agree.
5. ~~**active = false.**~~ (built: in code, or an `active` component) A system kept but not run (debug systems, pause
   menus), toggled from its props row.

Not worth taking: entities without identity (we need paths for saving,
diffs and the network), systems as free tables outside the world (ours are
nodes: saved, edited, hot-reloaded), its metatable-free classes (we have
/classes).

## The node graph as a project plugin (done 2026-10-14)

It's `plugins/nodegraph/` now, a project plugin like the texture viewer:
1. Done: `3rd/lite/data/plugins/tabflip.lua`: the flip icon, its tooltip and
   click, for any kind (the graph's, the markdown preview's).
2. Done: `3rd/lite/data/plugins/tabmenu.lua`: every tab's right-click menu
   (close, copy path, browse, the kind's toggle).
3. Done: a plugin may be a folder of modules: `P.require(mod)` and `require
   "plugins.<name>.<mod>"` find `plugins/<name>/<mod>.lua` (a searcher in
   `data/replay.lua`, ahead of lite's own: a stale copy left in lite's
   folder loses). The graph doesn't take `.lua` over: Lua opens as text and
   flips to its graph.
4. Done: the folder moved; its modules keep their names, so the C side's
   hooks (probe, breakpoints, Play's compile check) and the tests' requires
   didn't change; tests.lua / nodegraph_moves / theme_colors read its files
   at their new place. `P.reloadable = false`: it patches lite too deeply
   to reload live; saving its code says to restart.
5. Done: its settings are `plugins/nodegraph/config.lua` (grid, rebuild
   delay, the flow's colour and fade, the far zoom, the most zoom, header
   colours per kind), edited in the tree or as text, applied at once.

## Open: viewer and tooling

Settings for later (mario, 2026-10-07):
- FPS limit values beyond 0 / multiples of 6: -1 unlimited, 1 vsync, 2 adaptive vsync.
- Budgets: the most disk the log may use (MiB: `.log.txt` and its rolls), the most RAM
  the timeline's snapshots may use (MiB: older snapshots dropped, or thinned, past it).

Plain Lua comments in the graph (discussed 2026-10-07, not built):
- A comment block right above a statement (no blank line between) belongs to it: its
  node shows it as a note above the title (dim, wrapped, clipped to N lines, the rest on
  hover); a comment at the end of a line shows in that node's tooltip (or as a 2nd line).
- A comment alone (blank lines around it) becomes a note node: a box with the text, no
  pins, placed by the layout like a floating block; double-click edits it in place.
- Our own tags (`--@node`, `--@comment`, `--@float`, widget hints) aren't notes.
- The work: the parser keeps comments with their lines; a statement's range grows to
  its leading comments so that every graph edit (move, delete, collapse to function,
  float, split) carries them along; the text edits keep their order with our tags (the
  comment, then the tag, then the statement, or the other way round: pick one).
- Problems ahead: comments inside an expression (`f(a, -- why` / `b)`), several
  statements on a line, `--[[ ]]` blocks of commented-out code (big: collapsed by
  default), a file's license header (a note for the file, not the first statement),
  comment-only edits counted as changes in the diff list (they are text: fine).
- Cost: showing them read-only is small (a day); carried through every edit, more.

1. ~~Headless runs (`--headless --ticks N`) for CI~~: done (2026-10-14).
2. Textures by content hash: the first real binary asset, p2p-friendly.
3. Layers / draw order, toggled from the tree.
4. Grid and snap for positioning in the game view.
5. Camera follow (double-click a node).
6. A cost bar per tree item (solid background 0..100%), from the profiler.



## Testing like an author (mario, 2026-10-05)

Most UI tests start from code already wired; people start from an empty canvas where
everything they add floats.
- `scratch:` tests in nodegraph_ui.lua: an empty file, nodes added from the menu, wired,
  each feature used on them. Add one for every new feature.
- `NG_FLOAT=1|2` on the UI suite: every test's code floats as one block (1) or a block per
  statement (2). Worth a pass after big changes.

## Export: free disk space (2026-10-08)

Checking the destination's free space before packaging isn't possible with SDL3
as it is: `SDL_GetStorageSpaceRemaining` exists, but for plain folders
(`SDL_OpenFileStorage`) its generic backend returns `SDL_MAX_UINT64` (a TODO in
SDL's src/storage/generic/SDL_genericstorage.c). So the exporter doesn't check.
Later, if wanted: our own few lines per platform (`GetDiskFreeSpaceExW` on
Windows, `statvfs` elsewhere), compared with the export's size (the files are
known before copying: sum them first), and a gentle "needs 12 MB, 3 MB free"
before anything is written. Or when SDL implements it: no code of ours.

## A Game & Watch game, with the atlas (mario, 2026-10-14) — done: games/lcd (Parcels), 2026-10-15

A demo in the style of Nintendo's Game & Watch: an LCD screen with fixed
segments that are either on or off.

- Two full-screen pictures: the LCD **off** (the background, every segment
  faint or invisible) and the LCD **on** (every segment drawn, dark).
- An atlas (plugins/atlaspacker) over the "on" picture says where each segment
  is: frames named `man/left`, `man/middle`, `ball/1`..`ball/12`, `miss/1`...
  Packing isn't the point here; the frames are rectangles cut from one
  picture, so the atlas needs a mode that takes the rects from a source
  image (or a hand-made frames list) instead of packing many files.
- The game draws the "off" picture, then blits only the segments that are
  lit this tick: `image = { "/assets/lcd.atlas.lua", frame = "man/left" }`
  per lit segment, all at the same place as in the "on" picture (each
  frame keeps its x, y: drawn at its own spot, not centred).
- Game logic is a tiny state machine on a fixed tick (a beat: 2..4 steps a
  second, faster as the score goes up), the segments just a set of names.
- Nice for the editor too: a segment editor (click a rect on the "on"
  picture, name it) would be a canvas plugin on top of the atlas.
- Needs: image frames drawn at their own place (an `anchor = "frame"` or
  `at = "sheet"` option), the atlas taking rects from one image, a beat
  helper. Sounds (beeps) would be the first audio.

## Admin nodes: a plan (2026-10-15)

From the project's brief: some peers are privileged and supervise others
(a server-ish role, but they're clients like anyone). They can play, but
never administer their own games: they only review external ones. Online
play (net.udp, players.lua) is in; this is what could come next, in steps:

1. **Identity.** Each editor gets a key pair (Ed25519: monocypher, one C
   file, public domain-ish), kept next to the exe. A peer says who it is in
   `hello` and signs it; the host checks. Player numbers stay per session;
   keys are who you are across sessions.
2. **Games have authors.** A game's `config/` gets a manifest: its name,
   its authors' public keys, its version (the hash of its authored world,
   `w:save('/**', true)`), the previous version's hash.
3. **Changes are proposals.** A new version of an external game is a patch
   (ecs.diff between two saves: we have it) plus the author's signature.
   Peers keep the version they have until a proposal is accepted.
4. **Admins review.** An admin's editor gets a Review tab (a plugin): the
   queue of proposals for games it doesn't author; each shown as a diff
   (the tree, the node graph's diff view), run headless (`--headless
   --ticks N`: no errors, the game's own asserts), then signed: accepted or
   rejected with a note. A peer takes a proposal with enough signatures
   (1 to start; later N of M) from admins who aren't among its authors.
5. **Admins watch sessions.** An admin can join a session as an observer
   (no player, no keys sent): it gets every peer's states like anyone, and
   checks them against the game's rules (a paddle faster than its speed,
   a score that jumped): a report, not a ban, at first.
6. **Who's an admin.** A signed list (keys) shipped with the editor, or
   granted by existing admins (a few signatures). Never your own games:
   the review tab refuses proposals whose authors include your key.

The first useful slice: 1 + 2 + 3 + a review tab that shows and signs (4
without the network): proposals travel later, as files first.

## Kept for when we do p2p for real (mario, 2026-10-15)

Two pieces to pick up whenever the peer-to-peer work goes on; not now.

1. **The game travels with the joiner.** Today everyone needs the same game
   folder: only the world is sent. The host should send the game's files
   too (assets, modules, systems): named by a hash of their content, so a
   joiner asks only for the ones it lacks; then zipped deltas between two
   snapshots of the tree (both older ideas: "textures by content hash",
   "zip the world, send deltas"). Then anyone can join, not just people
   with a copy.
2. **The first admin-nodes slice** (the plan above, steps 1-3 and a review
   tab): a key pair per editor, a game's authors in its manifest, new
   versions as signed patches, a Review tab that shows the diff, runs it
   headless and signs (refused for games you author). Proposals as files
   first; the network later.

## Ticket: NAT traversal (mario, 2026-10-15) — apart, later

Online play works on a LAN, and over the internet when the host forwards
its UDP port. Getting through home routers without that is its own rabbit
hole: UDP hole punching with the host as introducer (half there: peers
already ping each other as soon as the roster says where they are), a
rendezvous for when the host itself is behind a NAT, STUN to learn one's
public address, TURN-like relaying as the last resort, symmetric NATs,
port prediction, keep-alives tuned to routers' timeouts. IPv6 (supported
now) needs none of it where both ends have it. To be scoped as a ticket.
