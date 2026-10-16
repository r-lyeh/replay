# bullets

A bullet-hell editor: `.bullets` files, what a shoot'em up's ships fire
(patterns), its ships, the waves they come in and the boss with its phases.
Games play the same file with the same code: `w:bullets("name.bullets")`
(runtime/bullets.lua; `games/starfall.lua` and `games/common/starfall.bullets`).

- `editor.lua`: the tab (runs in Lite)
- `files.lua`: the extensions it opens (`bullets`)
- `config.lua`: `background` (dark, light), `speed` (the preview's)
- `templates/stage.bullets`: a new file (the main menu's Plugins > Bullet editor)
- the format and the simulation: `runtime/bullets.lua` (one file for both)

## Using it

- **Left**: the patterns, the ships, the waves and the boss (a click selects,
  `x` deletes, `+` adds, Duplicate copies a pattern); the preview's controls.
- **Middle**: the play field (800 x 600). *Show pattern*: the selected pattern
  fired from the top at the player (the orange triangle: drag it with LMB, aimed
  patterns follow it). *Show stage*: the waves come in on their paths, then the
  boss goes through its phases (it weakens by itself, a few seconds a phase);
  the Time slider jumps (the stage is played again up to there).
- **Right**: what's selected. A pattern: its kind (ring, fan, random), count,
  spread, aim or angle, spin (a ring that spins is a spiral), rate, volleys
  (0: while its ship lives), delay; speed, acceleration, curve (bullets that
  turn), life; size, colour, sprite (dot, spark, shot); split (at that age a
  bullet bursts into another pattern). A ship: its hp, score, size, speed and
  the pattern it fires. A wave: when, which ship, how many, the gap between
  them, the path (down, sine, dive, zigzag, sweep, arc), where (x; a sweep's
  height), spacing, mirrored, and a pattern of its own if wanted. The boss: hp,
  size, score, and phases: from what part of its hp each starts, the patterns it fires.
- Renaming a pattern or a ship renames it wherever it's used.
- **A new file**: the main menu's Plugins > Bullet editor (from the template);
  CTRL+S asks where, suggesting the open game's folder for them
  (`games/common/` for a single-file game, `assets/` for a folder game).
- **Import from...** (left, or the right-click menu): another `.bullets` file's
  patterns and ships, added to these (a name already here gets a number;
  what the imported ones name follows).
- **Play field**: its width and height (saved in the file as `field`);
  bullets leave past its edges, the paths and the boss's place follow it;
  Starfall makes its window that size.
- The stage preview and the games run the same stage code
  (`runtime/bullets.lua`: `stage_new`, `stage_step`, `stage_kill`): what the
  preview shows is what a game plays (minus the player: here the boss
  weakens by itself).
- SPACE pauses, CTRL+Z / CTRL+Y undo and redo, CTRL+S saves, MMB pans,
  CTRL+wheel zooms, double-click fits.
