-- scenes.lua - the gallery's scenes (docs/gallery/gallery.py runs one per
-- editor run: SCENE=<name>): each sets the editor up for a picture, then
-- waits; the run's --shot takes it.
local core = require "core"
local scene = os.getenv("SCENE") or ""
local ROOT = (os.getenv("ROOT") or ".") .. "/"     -- (the repo: lite's folder is the game's)
local ow = require "plugins.openwith"
local menu = require "plugins.contextmenu"
local style = require "core.style"

local function open(key, path) local v = ow.open(key, ROOT .. path); coroutine.yield(1); return v end
local function hover(m, pat)                       -- (a menu's item, hovered: its submenu opens)
  for i, it in ipairs(m.items) do
    if it.text and it.text:find(pat) then
      menu:on_mouse_moved(m.x + 20, m.y + 4 * SCALE + m.top + (i - 1 - m.scroll) * m.ih + m.ih / 2)
    end
  end
end

local S = {}
S.graph = function()                               -- (at 100%, from its top left)
  local v = open("nodegraph", "games/hop/systems/hud/system.lua")
  local t0 = system.get_time()
  while not v.g and system.get_time() - t0 < 5 do coroutine.yield(0.1) end
  local g, top = v.g, style.font:get_height() + 8 * SCALE
  if g then v.zoom = 1; v.pan.x = 24 - (g.x0 or 0); v.pan.y = top + 24 - (g.y0 or 0) end
end
S.code = function() open("text", "games/hop/systems/player/system.lua") end
S.markdown = function()
  lite_theme("light")
  local v = open("markdown", "docs/HELP.md")
  menu:show(v.position.x + 40, v.position.y + 10); coroutine.yield(0.3)
  hover(menu.m, "^5%.")
end
S.tilemap = function() open("tilemap", "plugins/tilemap/samples/island.tmap") end
S.sfxr = function() open("sfxr", "plugins/sfxr/samples/jump.sfx") end
S.particles = function()                           -- (zoomed in on the emitter)
  local v = open("particles", "plugins/particles/samples/fire.pfx")
  v:set_zoom(3, v:to_screen(0, -20)); coroutine.yield(2)
end
S.atlas = function() open("atlaspacker", "games/lcd/assets/lcd.atlas.lua") end
S.hex = function() open("hexedit", "plugins/tilemap/tiles.png") end

core.add_thread(function()
  coroutine.yield(1)
  if S[scene] then S[scene]() end
  core.redraw = true
end)
