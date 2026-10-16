-- config.lua: the atlas packer's settings (the tree: /plugins/atlaspacker:
-- config). An atlas's own (its .atlas.lua: what its tab's Settings write)
-- win over these.
return {
  padding = 2,           -- px between two packed images (and none at the sheet's edges)
  power_of_two = true,   -- the sheet's sides: 64, 128, 256... (false: as small as it packs)
  max_size = 2048,       -- the most a side can be, px
  rotate = false,        -- images may be turned a quarter, when that packs tighter (frames: deg = 90)
  checker = 1.5,         -- the squares behind the sheet: % of the monitor's height
}
