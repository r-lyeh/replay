-- plugins_mount.lua - /plugins (headless): the viewer's Lua (runtime/boot.lua)
-- mounts each folder of a plugins/ dir as /plugins/<name>: its data
-- leaves become components (code leaves, like editor.lua, stay on disk);
-- dirty / Save / Undo work against that folder; the world's own save never
-- has them.
-- Run: luajit plugins_mount.lua   (or lua5.4)

local here = (arg and arg[0] or ""):match("^(.*[/\\])") or ""
package.path = here .. "../?.lua;" .. here .. "?.lua;" .. package.path


dofile(here .. "../boot.lua")                     -- (the viewer's Lua)
local ecs, fs = require("ecs"), require("fs")

local fails = 0
local function check(ok, what) if not ok then fails = fails + 1; print("  FAIL: " .. what) end end

local dir = os.tmpname()
os.remove(dir)
local pdir = fs.join(dir, "texviewer")
fs.mkdir(pdir)
fs.write(fs.join(pdir, "files.lua"), 'return { "png", "jpg" }\n')
fs.write(fs.join(pdir, "config.lua"), '-- its settings\nreturn { grid = 8, background = "checker" }\n')
fs.write(fs.join(pdir, "editor.lua"), 'local P = ...\nlocal core = require "core"\nreturn {}\n')
fs.write(fs.join(pdir, "README.md"), '# texviewer\n')
viewer_plugins_dir = dir

local w = ecs.world()
w:spawn("/objects/x", {})                          -- (a layout world)
viewer_mount_plugins(w)
local n = w:node("/plugins/texviewer")
check(n ~= nil, "a plugins/ folder: mounted as /plugins/texviewer")
check(n and n.c.files and n.c.files[2] == "jpg", "... its files.lua: a component")
check(n and n.c.config and n.c.config.grid == 8, "... its config.lua too")
check(n and n.c.editor == nil, "... its code (editor.lua): left on disk")
check(not viewer_sel_dirty(w, { "/plugins/texviewer" }), "just mounted: not dirty")
n.c.config.grid = 4
check(viewer_sel_dirty(w, { "/plugins/texviewer" }), "a value changed: dirty")
check(viewer_sel_save(w, { "/plugins/texviewer" }), "Save")
local saved = fs.read(fs.join(pdir, "config.lua"))
check(saved and saved:find("grid = 4", 1, true), "... config.lua has it")
check(fs.read(fs.join(pdir, "files.lua")) == 'return { "png", "jpg" }\n', "... files.lua (unchanged): not rewritten")
check(fs.read(fs.join(pdir, "editor.lua")):find("require", 1, true), "... editor.lua untouched")
check(not viewer_sel_dirty(w, { "/plugins/texviewer" }), "saved: not dirty")
n.c.config.grid = 2
check(viewer_sel_undo(w, { "/plugins/texviewer" }) and w:node("/plugins/texviewer").c.config.grid == 4, "Undo: back to its folder's")
local _, blob = w:save("/**", true)
check(not blob:find("texviewer", 1, true), "the world's own save: no /plugins")
local w2 = ecs.world()
w2:spawn("/objects/x", {})
w2:spawn("/plugins/texviewer", { files = { "x" } })
viewer_mount_plugins(w2)
check(w2:node("/plugins/texviewer").c.files[1] == "x", "a node already there: left alone")

for _, f in ipairs({ "files.lua", "config.lua", "editor.lua", "README.md" }) do fs.rmfile(fs.join(pdir, f)) end
fs.rmdir(pdir); fs.rmdir(dir)
print(fails == 0 and "plugins mount: all ok" or (fails .. " failed"))
os.exit(fails == 0 and 0 or 1)
