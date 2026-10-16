-- editor.lua - the terrain generator: .terrain files (runs in Lite). Land and
-- water from noise (a seed, its size, how wide its features, how rugged),
-- beaches, grass and dry land, hills and snow, trees and flowers, on the
-- right; the land it makes in the middle, at once. Saving writes the
-- settings and a .tmap the tilemap editor opens, marked as made here
-- (plugins/chain: Regenerate, Open source). gen.lua does the work, without
-- Lite; the tab is plugins/genview's, shared with the dungeon generator.
local P = ...
P.title = "Terrain generator"
local G = P.require("gen")

return require("plugins.genview").make(P, G, {
  ext = "terrain",
  head = "Terrain",
  info = function(v, ui)
    ui:label("Land", v.info.land .. "%")
    ui:label("Water", v.info.water .. "%")
    ui:label("Bushes", tostring(v.info.trees))
  end,
  panel = function(v, ui, num, edit)
    local s = v.s
    ui:head("Shape")
    num("Width", "w", 8, 256, { fmt = "%d cells", int = true, step = 2 })
    num("Height", "h", 8, 256, { fmt = "%d cells", int = true, step = 2 })
    num("Scale", "scale", 2, 64, { fmt = "%.0f cells", step = 1 })
    num("Detail", "octaves", 1, 6, { fmt = "%d", int = true, step = 1 })
    ui:check("Island", s.island, function() edit(function(t) t.island = not t.island end) end)
    ui:head("Heights")
    num("Water", "water", 0, 1, { fmt = "%.2f", step = 0.01 })
    num("Beach", "beach", 0, 0.2, { fmt = "%.2f", step = 0.01 })
    num("Hills", "hills", 0, 1, { fmt = "%.2f", step = 0.01 })
    num("Snow", "snow", 0, 1, { fmt = "%.2f", step = 0.01 })
    ui:head("Life")
    num("Dry land", "dry", 0, 1, { fmt = "%.2f", step = 0.02 })
    num("Trees", "trees", 0, 1, { fmt = "%.2f", step = 0.02 })
    num("Flowers", "flowers", 0, 1, { fmt = "%.2f", step = 0.01 })
    ui:check("Shores", s.shores, function() edit(function(t) t.shores = not t.shores end) end)   -- (auto-tiles: sand edges on the water)
  end,
})
