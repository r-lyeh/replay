# scene2

The scene1.lua demo as a world folder: `play.exe games\scene2\`

- Every folder is a node (`objects/fleet/ship1` = `/objects/fleet/ship1`).
- Every `.lua` file is one component of that node; it returns plain data
  (`xform.lua` -> `return { x = -340, y = 195, r = 1 }`).
- The roots: `assets/` the parts that `ref` draws
  (`objects/fleet/ship1/ref.lua` -> `"/assets/ship"`), `data/` rules, state
  and players, `classes/` components' members (`classes/shot/life.lua`:
  every shot lives 1.5 s, a number from 0.2 to 5: a slider in the editor), `systems/` the code (one each, run in
  `systems/order.lua`'s order), `objects/` what you see.
- While it plays, the ships shoot now and then (`systems/fire`): each shot
  is an entity, under `/entities/shots` in the tree, gone when its life runs
  out (`systems/shots`). Entities are never saved: Stop clears them.
- A file that returns code instead of data is a system
  (`systems/fly/system.lua`), or input (`systems/keys/system.lua`). Systems
  can use `dd.*` to debugdraw on the dev overlay (`systems/debug/system.lua`).
- Edit any file while the game runs: on save only that node is patched,
  the rest of the world keeps its live state. Systems swap in place.
- Add a node: make a folder with some files (e.g. copy `objects/fleet/ship5`
  to `ship6`). Delete a folder to remove the node.
- Files that are not `.lua` (like this one) are ignored.
