-- editor.lua - the dungeon generator: .dungeon files (runs in Lite). A
-- dungeon's settings (a seed, its size, rooms, corridors, a theme, torches,
-- clutter...) on the right; the dungeon it makes in the middle, at once; on
-- the left what it made and the map it writes. Saving writes the settings and
-- the map: a .tmap the tilemap editor opens (plugins/tilemap), marked as made
-- here, so it offers Regenerate and Open source (plugins/chain: plugins that
-- feed other plugins). gen.lua does the work, without Lite (a game could too);
-- the tab is plugins/genview's, shared with the terrain generator.
local P = ...
P.title = "Dungeon generator"
local G = P.require("gen")

return require("plugins.genview").make(P, G, {
  ext = "dungeon",
  head = "Dungeon",
  info = function(v, ui)
    ui:label("Rooms", tostring(v.info.rooms))
    ui:label("Corridors", tostring(v.info.corridors))
  end,
  panel = function(v, ui, num, edit)
    local s = v.s
    ui:head("Layout")
    num("Width", "w", 12, 160, { fmt = "%d cells", int = true, step = 2 })
    num("Height", "h", 12, 160, { fmt = "%d cells", int = true, step = 2 })
    num("Rooms", "rooms", 1, 60, { fmt = "%d", int = true, step = 1 })
    num("Room min", "room_min", 3, 30, { fmt = "%d", int = true, step = 1 })
    num("Room max", "room_max", 3, 40, { fmt = "%d", int = true, step = 1 })
    num("Loops", "loops", 0, 1, { fmt = "%.2f", step = 0.05 })
    ui:head("Look")
    ui:choice("Theme", s.theme, G.THEME_NAMES, function(x) edit(function(t) t.theme = x end) end)
    ui:check("Wall edges", s.auto_walls, function() edit(function(t) t.auto_walls = not t.auto_walls end) end)   -- (auto-tiles: the stone theme's walls outlined where they meet the floor)
    num("Torches", "torches", 0, 1, { fmt = "%.2f", step = 0.02 })
    num("Clutter", "clutter", 0, 1, { fmt = "%.2f", step = 0.02 })
    ui:check("Doors", s.doors, function() edit(function(t) t.doors = not t.doors end) end)
  end,
})
