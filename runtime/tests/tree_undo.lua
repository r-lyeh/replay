-- tree_undo.lua - the tree's Undo (headless): the viewer's Lua
-- (runtime/boot.lua) on a folder world. Delete / Rename / Duplicate / New,
-- undone last first (viewer_tree_undo; the tree's menu "Undo ...", CTRL+Z
-- over the tree). A deleted asset's files go to .trash/<day>/<n>/ (n: its
-- undo level) with an undo.lua: a later session can still undo it.
-- Run: luajit tree_undo.lua   (or lua5.4)
local here = (arg and arg[0] or ""):match("^(.*[/\\])") or ""
package.path = here .. "../?.lua;" .. here .. "?.lua;" .. package.path
dofile(here .. "../boot.lua")                     -- (the viewer's Lua)
local ecs, fs = require("ecs"), require("fs")
hostfs = hostfs or { isdir = fs.isdir }            -- (the viewer's: SDL)

local fails = 0
local function check(ok, what) if not ok then fails = fails + 1; print("  FAIL: " .. what) end end
local function write(p, s) assert(fs.write(p, s)) end

local root = os.tmpname()
os.remove(root)
fs.mkdir(root)
local game, plugins = fs.join(root, "game"), fs.join(root, "plugins")
fs.mkdir(fs.join(game, "objects", "box"))
write(fs.join(game, "objects", "box", "xform.lua"), "return { x = 1, y = 2 }\n")
fs.mkdir(fs.join(game, "objects", "box", "lid"))
write(fs.join(game, "objects", "box", "lid", "xform.lua"), "return { x = 0, y = 3 }\n")
fs.mkdir(fs.join(game, "assets", "rocks"))
write(fs.join(game, "assets", "rocks", "big.png"), "BIG")
write(fs.join(game, "assets", "rocks", "small.png"), "SMALL")
write(fs.join(game, "assets", "ship.png"), "SHIP")
fs.mkdir(plugins)
fs.mkdir(fs.join(plugins, "img"))
write(fs.join(plugins, "img", "editor.lua"), "local P = ...\n")
write(fs.join(plugins, "img", "files.lua"), 'return { "png" }\n')
viewer_plugins_dir = plugins
local day = fs.join(game, ".trash", os.date("%Y-%m-%d"))

local w = assert(viewer_load(game))
viewer_mount_assets(w, true)
check(#viewer_history == 0 and not viewer_tree_menu(w, "/assets/ship.png"):find("Undo", 1, true), "nothing done: no Undo")

-- an asset folder deleted, then undone
check(viewer_tree_action(w, "/assets/rocks", "Delete"), "delete /assets/rocks")
check(not w:node("/assets/rocks") and not fs.isdir(fs.join(game, "assets", "rocks")), "... gone (tree, disk)")
check(fs.read(fs.join(day, "1", "rocks", "big.png")) == "BIG" and fs.read(fs.join(day, "1", "undo.lua")), "... in .trash/<day>/1/, with its undo.lua")
check(viewer_tree_menu(w, "/assets/ship.png"):find("Undo delete /assets/rocks", 1, true), "the menu: Undo delete /assets/rocks")
check(viewer_tree_action(w, "/assets/ship.png", "Undo delete /assets/rocks"), "undo")
check(w:node("/assets/rocks/big.png") and fs.read(fs.join(game, "assets", "rocks", "small.png")) == "SMALL", "... back (tree, disk)")
check(not fs.isdir(fs.join(day, "1")), "... its trash folder gone")
check(not viewer_sel_dirty(w, { "/assets", "/assets/rocks" }), "... not an unsaved change")
check(#viewer_history == 0, "... the history empty")

-- a world node deleted (with what's below), undone
check(viewer_tree_action(w, "/objects/box", "Delete") and not w:node("/objects/box/lid"), "delete /objects/box")
check(viewer_tree_undo(w) and w:node("/objects/box/lid") and w:node("/objects/box").c.xform.x == 1, "undo: box and lid back")
check(not viewer_sel_dirty(w, { "/objects/box" }), "... as on disk")

-- several, in one step
check(viewer_tree_action(w, "/assets/ship.png", "Delete", { "/assets/ship.png", "/objects/box" }), "delete two")
check(not w:node("/assets/ship.png") and not w:node("/objects/box"), "... both gone")
check(#viewer_history == 1, "... one step")
check(viewer_tree_undo(w) and w:node("/assets/ship.png") and w:node("/objects/box"), "undo: both back")

-- rename (an asset: on disk), undone
check(viewer_tree_action(w, "/assets/rocks", "Rename"), "rename: typed")
check(viewer_prop_set(w, { "/assets/rocks" }, ecs.encode({ "?name" }), "stones", "lit"), "rename to stones")
check(w:node("/assets/stones") and fs.isdir(fs.join(game, "assets", "stones")), "... renamed (disk)")
check(viewer_tree_undo(w) and w:node("/assets/rocks/big.png") and not w:node("/assets/stones") and not fs.isdir(fs.join(game, "assets", "stones")), "undo: rocks again")

-- duplicate, undone
check(viewer_tree_action(w, "/assets/ship.png", "Duplicate") and w:node("/assets/ship2.png"), "duplicate ship.png")
viewer_naming = nil
check(viewer_tree_undo(w) and not w:node("/assets/ship2.png") and not fs.read(fs.join(game, "assets", "ship2.png")), "undo: the copy gone")
check(fs.read(fs.join(day, "undone", "ship2.png")) == "SHIP", "... into .trash/<day>/undone")

-- new node, undone
check(viewer_prop_set(w, { "/objects" }, ecs.encode({ "?new" }), "crate", "lit") and w:node("/objects/crate"), "new /objects/crate")
check(viewer_tree_undo(w) and not w:node("/objects/crate"), "undo: gone")

-- a delete undone in a later session (the world loaded again)
check(viewer_tree_action(w, "/assets/rocks", "Delete"), "delete rocks again")
check(viewer_tree_action(w, "/assets/ship.png", "Delete"), "and ship.png")
check(fs.isdir(fs.join(day, "1")) and fs.isdir(fs.join(day, "2")), "... levels 1 and 2")
viewer_new_session()  -- (a later session: its stack from the trash)
local w2 = assert(viewer_load(game))
viewer_mount_assets(w2, true)
check(#viewer_history == 2 and viewer_history[2].what == "delete /assets/ship.png", "a later session: the deletes, from the trash")
check(viewer_tree_undo(w2) and w2:node("/assets/ship.png"), "undo: ship.png back")
check(viewer_tree_undo(w2) and w2:node("/assets/rocks/small.png"), "undo: rocks back")
check(not viewer_tree_undo(w2), "nothing left to undo")
check(not fs.isdir(fs.join(day, "1")) and not fs.isdir(fs.join(day, "2")), "the trash: levels gone")

-- a clean quit forgets the stack (replay.c: viewer_history_forget); deleted files stay in .trash
check(viewer_tree_action(w2, "/assets/ship.png", "Delete"), "delete ship.png, then quit")
check(viewer_prop_set(w2, { "/objects" }, ecs.encode({ "?new" }), "crate2", "lit"), "and a new node")
viewer_history_forget()
check(#viewer_history == 0 and not fs.read(fs.join(day, "1", "undo.lua")) and not fs.isdir(fs.join(day, "2")), "forgotten: no levels")
local kept = false
for _, e in ipairs(fs.list(day)) do if e.name:match("^deleted%-%d+%-1$") and fs.read(fs.join(day, e.name, "ship.png")) then kept = true end end
check(kept, "the deleted file kept: .trash/<day>/deleted-<time>-1/ship.png")
viewer_new_session()
local w3 = assert(viewer_load(game))
check(#viewer_history == 0 and not viewer_tree_undo(w3), "the next session: nothing to undo")

-- one undo for everything: property edits and moves in the game view (in memory)
local w4 = assert(viewer_load(game))
viewer_mount_assets(w4, true)
check(viewer_prop_set(w4, { "/objects/box" }, ecs.encode({ "xform", "x" }), "5", "lit") and w4:node("/objects/box").c.xform.x == 5, "edit box.x = 5")
local depth = #viewer_history
check(viewer_prop_set(w4, { "/objects/box" }, ecs.encode({ "xform", "x" }), "6", "lit") and #viewer_history == depth, "edit it again, at once: the same level")
check(viewer_history[#viewer_history].what:match("^edit /objects/box %.xform%.x"), "its name: " .. tostring(viewer_history[#viewer_history].what))
check(viewer_tree_undo(w4) and w4:node("/objects/box").c.xform.x == 1, "undo: x as it was before both (1)")
check(viewer_move_begin(w4, "/objects/box") and viewer_move_by(w4, 10, -4, 0, 1) and viewer_move_by(w4, 0, 0, 0.5, 2), "drag the box: moved, turned, scaled")
local xf = w4:node("/objects/box").c.xform
check(viewer_move_end(w4) and xf.x == 11 and xf.y == -2 and xf.r == 0.5 and xf.s == 2, "moved: " .. ecs.encode(xf))
check(viewer_tree_undo(w4) and w4:node("/objects/box").c.xform.x == 1 and w4:node("/objects/box").c.xform.r == nil, "undo the move")
check(viewer_move_begin(w4, "/objects/box") and not viewer_move_end(w4), "a click, no drag: no level")
viewer_session_start(w4)
check(viewer_prop_set(w4, { "/objects/box" }, ecs.encode({ "xform", "x" }), "9", "lit"), "an edit while playing")
viewer_session_stop(w4)
check(w4:node("/objects/box").c.xform.x == 1 and not (viewer_history[#viewer_history] or {}).mem, "Stop: the edit and its level gone")

local function rm(d)
  for _, e in ipairs(fs.list(d)) do
    local p = fs.join(d, e.name)
    if e.dir then rm(p) else fs.rmfile(p) end
  end
  fs.rmdir(d)
end
rm(root)
print(fails == 0 and "tree undo: all ok" or (fails .. " failed"))
os.exit(fails == 0 and 0 or 1)
