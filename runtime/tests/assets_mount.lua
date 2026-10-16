-- assets_mount.lua - /assets (headless): the viewer's Lua (runtime/boot.lua)
-- shows a folder world's assets/ files that a plugin opens as
-- /assets/.../<file.ext> nodes, never in the world's own save; + folder and
-- + <kind> (a plugin's templates/) make them on disk; a file gone from disk
-- leaves the tree. Run: luajit assets_mount.lua   (or lua5.4)
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
fs.mkdir(fs.join(game, "assets", "sprites"))
write(fs.join(game, "assets", "ship.png"), "png")
write(fs.join(game, "assets", "notes.txt"), "no plugin takes it")
write(fs.join(game, "assets", "sprites", "ball.png"), "png")
fs.mkdir(fs.join(plugins, "img", "templates"))
write(fs.join(plugins, "img", "editor.lua"), "local P = ...\n")
write(fs.join(plugins, "img", "files.lua"), 'return { "png", "mat" }\n')
write(fs.join(plugins, "img", "config.lua"), 'return { thumbnails = "image" }\n')
write(fs.join(plugins, "img", "templates", "material.mat"), "return {}\n")
fs.mkdir(fs.join(plugins, "pack", "templates"))     -- (a two-part extension: name.atlas.lua)
write(fs.join(plugins, "pack", "editor.lua"), "local P = ...\n")
write(fs.join(plugins, "pack", "files.lua"), 'return { "atlas.lua" }\n')
write(fs.join(plugins, "pack", "templates", "atlas.atlas.lua"), "return { sources = {} }\n")
write(fs.join(game, "assets", "ui.atlas.lua"), "return { sources = {} }\n")
viewer_plugins_dir = plugins

local w = assert(viewer_load(game))
viewer_mount_assets(w, true)
check(w:node("/assets/ship.png") and w:node("/assets/sprites/ball.png"), "its files: nodes")
check(not w:node("/assets/notes.txt"), "a file no plugin opens: not shown")
check(w:node("/assets/ui.atlas.lua") and viewer_asset_ext("ui.atlas.lua") == "atlas.lua" and viewer_asset_ext("x.lua") == "lua"
      and viewer_asset_exts["atlas.lua"] == "pack", "a two-part extension (ui.atlas.lua): its plugin's")
do -- thumbnails: a folder's previewed files, last, as lines of cells (kind 'g', span rows each)
  local closed = viewer_outline(w, 1, 200, "", false, "")
  check(not table.concat(closed, " "):find("ship.png", 1, true), "the tree starts closed (but /)")
  viewer_unfolded["/assets"], viewer_unfolded["/assets/sprites"] = true, true
  local out, count, paths, sel, kinds, shapes, grids = viewer_outline(w, 1, 200, "/assets/ship.png", false, "", { cw = 40, span = 3, room = 200, ind = 11 })
  local g, rows = {}, 0
  for i = 1, #out do if kinds[i] == "g" then rows = rows + 1; g[#g + 1] = grids[i] end end
  check(rows == 6 and g[1]:match("^0\nimage\n/assets/sprites/ball.png$") and g[4]:match("^0\nimage\n/assets/ship.png$")
        and g[2]:match("^1\n"), "thumbnails: a line of 3 rows per folder (" .. rows .. ")")
  check(sel > 0 and kinds[sel] == "g" and shapes[sel]:sub(-1) == "g", "the selected file: its line's first row")
  local plain = viewer_outline(w, 1, 200, "", false, "")
  local names = table.concat(plain, " ")
  check(names:find("ship.png", 1, true), "no thumbnails: a row each")
  check(viewer_asset_thumbs.png == "image", "its plugin's config.lua: thumbnails = image")
end
check(ecs.is_file("/assets/ship.png") and not ecs.is_file("/assets/sprites") and not ecs.is_file("/objects/a.b"), "ecs.is_file: a name with a dot, under /assets")
local _, blob = w:save("/**", true)
check(not blob:find("ship", 1, true) and blob:find("sprites", 1, true), "the world's save: its folders, not its files")
check(not viewer_sel_dirty(w, { "/assets", "/assets/sprites" }), "mounted: nothing to save")
local labels = {}
for _, r in ipairs(viewer_props(w, { "/assets" })) do labels[r[2]] = true end
check(labels["+ folder"] and labels["+ material"] and labels["+ atlas"], "/assets: + folder, + material, + atlas")
labels = {}
for _, r in ipairs(viewer_props(w, { "/assets/ship.png" })) do labels[r[2]] = r end
check(labels.edit and labels.edit[11] == "open:" .. fs.join(game, "assets", "ship.png") and labels.plugin and labels.plugin[3] == "img", "a file: edit (its plugin), plugin")
local src = viewer_source(w, "/assets/ship.png")
check(src and src[1] and src[1].file == fs.join(game, "assets", "ship.png"), "a click opens the file")

check(viewer_prop_set(w, { "/assets" }, ecs.encode({ "?folder" }), "maps"), "+ folder")
check(fs.isdir(fs.join(game, "assets", "maps")) and w:node("/assets/maps"), "+ folder: on disk, in the tree")
check(not viewer_sel_dirty(w, { "/assets/maps" }), "+ folder: not an unsaved change")
check(not viewer_prop_set(w, { "/assets" }, ecs.encode({ "?folder" }), "bad name!"), "+ folder: a bad name refused")
local tpl = fs.join(plugins, "img", "templates", "material.mat")
check(viewer_prop_set(w, { "/assets/maps" }, ecs.encode({ "?asset", tpl }), "rock"), "+ material")
check(fs.read(fs.join(game, "assets", "maps", "rock.mat")) == "return {}\n" and w:node("/assets/maps/rock.mat"), "+ material: the template, copied, mounted")
check(viewer_open == fs.join(game, "assets", "maps", "rock.mat") and viewer_select == "/assets/maps/rock.mat", "+ material: selected, opened")
check(not viewer_prop_set(w, { "/assets/maps" }, ecs.encode({ "?asset", tpl }), "rock"), "+ material: not over a file there")
check(viewer_prop_set(w, { "/assets/maps" }, ecs.encode({ "?asset", fs.join(plugins, "pack", "templates", "atlas.atlas.lua") }), "tiles")
      and fs.read(fs.join(game, "assets", "maps", "tiles.atlas.lua")) and w:node("/assets/maps/tiles.atlas.lua"), "+ atlas: tiles.atlas.lua")
check(viewer_tree_undo(w) and not w:node("/assets/maps/tiles.atlas.lua"), "+ atlas: undone (the levels below as they were)")

os.remove(fs.join(game, "assets", "ship.png"))
viewer_mount_assets(w, true)
check(not w:node("/assets/ship.png") and w:node("/assets/sprites/ball.png"), "a file gone from disk: gone from the tree")

-- the tree's menu on assets: on disk at once
local menu = viewer_tree_menu(w, "/assets")
check(menu:find("New folder", 1, true) and menu:find("New material", 1, true), "/assets' menu: New folder, New material (" .. menu .. ")")
check(viewer_tree_action(w, "/assets/sprites", "Rename") and viewer_naming == "/assets/sprites", "Rename: its name typed")
check(viewer_prop_set(w, { "/assets/sprites" }, ecs.encode({ "?name" }), "sprotes"), "renamed")
check(fs.read(fs.join(game, "assets", "sprotes", "ball.png")) and not fs.isdir(fs.join(game, "assets", "sprites")), "a folder renamed: on disk too (not a copy)")
check(w:node("/assets/sprotes/ball.png") and not w:node("/assets/sprites"), "... and in the tree")
check(viewer_prop_set(w, { "/assets/maps/rock.mat" }, ecs.encode({ "?name" }), "stone.mat"), "a file renamed")
check(fs.read(fs.join(game, "assets", "maps", "stone.mat")) and not fs.read(fs.join(game, "assets", "maps", "rock.mat")) and w:node("/assets/maps/stone.mat"), "a file: renamed on disk, its extension kept")
check(viewer_tree_action(w, "/assets/maps/stone.mat", "Duplicate"), "a file duplicated")
check(fs.read(fs.join(game, "assets", "maps", "stone2.mat")) and w:node("/assets/maps/stone2.mat"), "... copied on disk")
check(viewer_tree_action(w, "/assets/sprotes", "Delete"), "a folder deleted")
check(not fs.isdir(fs.join(game, "assets", "sprotes")) and not w:node("/assets/sprotes"), "... gone from assets/ and the tree")
local day = fs.join(game, ".trash", os.date("%Y-%m-%d"))
check(#viewer_history == 6 and fs.read(fs.join(day, "6", "sprotes", "ball.png")) and fs.read(fs.join(day, "6", "undo.lua")),
      "... its files in .trash/<day>/6: its undo level (new, new, rename, rename, duplicate, delete)")
for i = 1, 5 do check(fs.read(fs.join(day, tostring(i), "undo.lua")), "level " .. i .. ": its undo.lua") end
check(viewer_tree_action(w, "/assets/maps/stone.mat", "Delete", { "/assets/maps/stone.mat", "/assets/maps/stone2.mat" }), "two deleted at once")
check(not w:node("/assets/maps/stone.mat") and not w:node("/assets/maps/stone2.mat"), "... both")
check(not viewer_sel_dirty(w, { "/assets", "/assets/maps" }), "none of it is an unsaved change")
check(viewer_tree_action(w, "/assets/maps", "New folder") and viewer_rename == ecs.encode({ "?folder" }), "New folder: its row typed")

-- Undo: the stack, last first; on disk (.trash/<day>/<level>/), read back by the next load
check(#viewer_history == 7 and viewer_tree_menu(w, "/assets"):find("Undo delete 2 nodes", 1, true), "the menu: Undo <the last>")
check(viewer_tree_undo(w) and w:node("/assets/maps/stone.mat") and w:node("/assets/maps/stone2.mat")
      and fs.read(fs.join(game, "assets", "maps", "stone2.mat")), "undo: both back, on disk and in the tree")
check(not fs.isdir(fs.join(day, "7")) and #viewer_history == 6, "... its level's folder: gone")
viewer_new_session()                               -- (a later session: not the same world read again)
w = assert(viewer_load(game))                      -- a later session
viewer_mount_assets(w, true)
check(#viewer_history == 6 and viewer_history[6].what == "delete /assets/sprotes", "the stack: read back from .trash (" .. #viewer_history .. ")")
check(viewer_tree_action(w, "/assets", "Undo delete /assets/sprotes") and fs.read(fs.join(game, "assets", "sprotes", "ball.png"))
      and w:node("/assets/sprotes/ball.png"), "undo in a later session: the folder back")
check(viewer_tree_undo(w) and not w:node("/assets/maps/stone2.mat") and not fs.read(fs.join(game, "assets", "maps", "stone2.mat")), "undo a duplicate: the copy gone")
check(viewer_tree_undo(w) and w:node("/assets/maps/rock.mat") and fs.read(fs.join(game, "assets", "maps", "rock.mat")), "undo a rename: its old name")
check(viewer_tree_undo(w) and w:node("/assets/sprites/ball.png") and fs.isdir(fs.join(game, "assets", "sprites")), "undo the first rename")
check(viewer_tree_undo(w) and not w:node("/assets/maps/rock.mat") and not fs.read(fs.join(game, "assets", "maps", "rock.mat")), "undo a new material: gone")
check(viewer_tree_undo(w) and not w:node("/assets/maps") and not fs.isdir(fs.join(game, "assets", "maps")), "undo a new folder: gone")
check(#viewer_history == 0 and not fs.isdir(fs.join(day, "1")), "nothing left to undo, no levels left")
check(not viewer_tree_undo(w) and not viewer_tree_menu(w, "/assets"):find("Undo", 1, true), "an empty stack: no Undo")
-- world nodes: undo a delete brings them back (and their components)
check(viewer_tree_action(w, "/objects/box", "Delete") and not w:node("/objects/box"), "a node deleted")
check(viewer_tree_undo(w) and w:node("/objects/box") and w:node("/objects/box").c.xform.x == 1, "undo: the node back, its components")
check(viewer_tree_action(w, "/objects/box", "Duplicate") and w:node("/objects/box2") and viewer_tree_undo(w) and not w:node("/objects/box2"), "undo a node's copy")

local function rm(d)                               -- (clean up)
  for _, e in ipairs(fs.list(d)) do
    local p = fs.join(d, e.name)
    if e.dir then rm(p) else fs.rmfile(p) end
  end
  fs.rmdir(d)
end
rm(root)
print(fails == 0 and "assets mount: all ok" or (fails .. " failed"))
os.exit(fails == 0 and 0 or 1)
