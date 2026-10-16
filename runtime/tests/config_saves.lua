-- config_saves.lua - /config and /saves (headless): the viewer's Lua
-- (runtime/boot.lua) on a folder world. /config: the project's settings, its
-- components (config/*.lua, saved like any node; the viewer reads window =
-- { w, h, title }). /saves: savegames, w:savegame(name, t) writes
-- saves/<name>.sav, w:loadgame(name) reads it; the tree shows them as files
-- (never in the world's save), their props show what's in them.
-- Run: luajit config_saves.lua   (or lua5.4)
local here = (arg and arg[0] or ""):match("^(.*[/\\])") or ""
package.path = here .. "../?.lua;" .. here .. "?.lua;" .. package.path
dofile(here .. "../boot.lua")                     -- (the viewer's Lua)
local ecs, fs = require("ecs"), require("fs")
hostfs = hostfs or { isdir = fs.isdir }            -- (the viewer's: SDL)

local fails = 0
local function check(ok, what) if not ok then fails = fails + 1; print("  FAIL: " .. what) end end
local function write(p, s) assert(fs.write(p, s)) end

-- in memory (no folder): a savegame round trip
local mw = ecs.world()
check(mw:savegame("best", { time = 12.5, who = "P1" }), "savegame: in memory")
local got = mw:loadgame("best")
check(got and got.time == 12.5 and got.who == "P1", "loadgame: what was saved")
check(mw:loadgame("none") == nil, "loadgame: nothing saved: nil")
check(not mw:savegame("../x", {}) and not mw:savegame("a.b", {}), "a savegame's name: [%w_-]")
check(not mw:savegame("f", { f = print }), "data only")

local root = os.tmpname()
os.remove(root)
fs.mkdir(root)
local game = fs.join(root, "game")
fs.mkdir(fs.join(game, "objects", "box"))
write(fs.join(game, "objects", "box", "xform.lua"), "return { x = 1, y = 2 }\n")
fs.mkdir(fs.join(game, "config"))
write(fs.join(game, "config", "window.lua"), 'return { w = 640, h = 360, title = "Demo" }\n')

local w = assert(viewer_load(game))
viewer_mount_assets(w, true)
local cfg = w:node("/config")
check(cfg and cfg.c.window and cfg.c.window.w == 640 and cfg.c.window.title == "Demo", "/config: config/*.lua, its components")
local roots = {}
for _, r in ipairs(ecs.ROOTS) do roots[#roots + 1] = r end
check(roots[1] == "/config" and table.concat(roots, " "):find("/entities /saves", 1, true), "the roots: /config first, /saves after /entities")
check(viewer_tree_menu(w, "/config") == "New component", "/config's menu: a new setting")
local crow = {}
for _, r in ipairs(viewer_props(w, { "/config" })) do crow[r[2]] = r end
check(crow["+ component"] and crow.w and crow.title, "/config's props: its settings, + component")
check(viewer_prop_set(w, { "/config" }, crow.w[1], "800") and w:node("/config").c.window.w == 800, "a setting: edited in props")
check(viewer_sel_dirty(w, { "/config" }), "... an unsaved change (config/window.lua)")
check(not w:node("/saves"), "no saves/ yet: no /saves")

-- a savegame: on disk, in the tree, not in the world's save
check(w:savegame("record", { time = 31.2, who = "P2 (AI)" }), "savegame: written")
check(fs.read(fs.join(game, "saves", "record.sav")), "... saves/record.sav")
check(w:loadgame("record").who == "P2 (AI)", "loadgame: from disk")
viewer_mount_assets(w, true)
check(w:node("/saves") and w:node("/saves/record.sav") and ecs.is_file("/saves/record.sav"), "the tree: /saves/record.sav")
local _, blob = w:save("/**", true)
check(not blob:find("record", 1, true), "the world's save: not the savegames")
check(not viewer_sel_dirty(w, { "/saves", "/saves/record.sav" }), "mounted: nothing to save")
local labels = {}
for _, r in ipairs(viewer_props(w, { "/saves/record.sav" })) do labels[#labels + 1] = r[2] .. "=" .. tostring(r[3]) end
local s = table.concat(labels, " ")
check(s:find("edit=record.sav", 1, true) and s:find("who=", 1, true) and s:find("time=31.2", 1, true), "its props: open it, what's in it: " .. s)
local sm = viewer_tree_menu(w, "/saves/record.sav")
check(sm:match("^Open tab with>Text|Open beside with>Text|Rename|Duplicate|Delete|Undo edit"), "a savegame's menu: Open tab with > Text, Open beside with > Text, Rename... (and Undo: the edit to /config above): " .. sm)
local ok_b, code_b = viewer_tree_action(w, "/saves/record.sav", "Open beside with:Text")
check(ok_b and tostring(code_b):find("open_beside(\"text\"", 1, true), "Open beside with > Text: the editor opens it beside: " .. tostring(code_b))
viewer_tree_action(w, "/saves/record.sav", "Duplicate")
check(w:node("/saves/record2.sav") and fs.read(fs.join(game, "saves", "record2.sav")), "duplicate: on disk")
viewer_tree_action(w, "/saves/record2.sav", "Delete")
check(not w:node("/saves/record2.sav") and not fs.read(fs.join(game, "saves", "record2.sav")), "delete: off disk (to .trash)")

-- /docs: the game's documents, on disk at once (create, rename, delete, undo)
check(w:node("/docs") and fs.isdir(fs.join(game, "docs")), "/docs: a game folder gets docs/")
check(viewer_tree_menu(w, "/docs"):find("New document", 1, true), "/docs' menu: New document")
check(viewer_prop_set(w, { "/docs" }, ecs.encode({ "?doc" }), "design_notes"), "+ document")
local dfile = fs.join(game, "docs", "design_notes.md")
check((fs.read(dfile) or ""):match("^# design notes"), "... a .md with its title")
check(w:node("/docs/design_notes.md") and ecs.is_file("/docs/design_notes.md"), "... in the tree, a file")
local _, dblob = w:save("/**", true)
check(not dblob:find("design_notes", 1, true), "the world's save: not the documents")
local drows = {}
for _, r in ipairs(viewer_props(w, { "/docs/design_notes.md" })) do drows[r[2]] = r[3] end
check(drows.edit and drows.title == "design notes", "its props: edit, its title")
check(viewer_prop_set(w, { "/docs" }, ecs.encode({ "?folder" }), "levels"), "+ folder in /docs")
viewer_tree_action(w, "/docs/design_notes.md", "Rename")
check(viewer_prop_set(w, { "/docs/design_notes.md" }, ecs.encode({ "?name" }), "design"), "rename a document")
check(fs.read(fs.join(game, "docs", "design.md")) and not fs.read(dfile) and w:node("/docs/design.md"), "... on disk, .md kept")
check(viewer_tree_action(w, "/docs/design.md", "Delete") and not fs.read(fs.join(game, "docs", "design.md")), "delete: off disk")
check(viewer_tree_undo(w) and fs.read(fs.join(game, "docs", "design.md")) and w:node("/docs/design.md"), "undo: back")

-- a script world: savegames in memory again
local sp = fs.join(root, "s.lua")
write(sp, "local w = ecs.world() return w\n")
viewer_load(sp)
check(ecs.saves.read("record") == nil, "a script world: in memory, not the folder's")

local function rm(d)
  for _, e in ipairs(fs.list(d)) do
    local p = fs.join(d, e.name)
    if e.dir then rm(p) else fs.rmfile(p) end
  end
  fs.rmdir(d)
end
rm(root)
print(fails == 0 and "config saves: all ok" or (fails .. " failed"))
os.exit(fails == 0 and 0 or 1)
