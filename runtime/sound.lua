-- sound.lua - the game's sounds: w:sound("jump") plays assets/jump.sfx (a
-- sound effect made with the sfxr plugin: plain data, sfxr's parameters),
-- rendered by runtime/sfxr.lua once (again when its file changes) and played
-- through the host (host_sound: editor/sound.h, eight voices mixed). Without
-- the host (headless, a test) nothing plays: w:sound returns false.
local sfxr = require('sfxr')
local ecs = require('ecs')

local M = { cache = {}, volume = 1 }

function M.play(w, name, volume)
  if not host_sound or M.muted then return false end
  name = tostring(name):gsub('^/assets/', ''):gsub('^/', '')
  if not name:find('%.%w+$') then name = name .. '.sfx' end
  local text = ecs.assets.read(name)
  if not text then return false end
  local c = M.cache[name]
  if not c or c.text ~= text then                  -- (rendered once; again when it changed)
    local p = ecs.decode(text, name)
    if type(p) ~= 'table' then return false end
    c = { text = text, pcm = sfxr.pcm16(sfxr.render(sfxr.check(p))) }
    M.cache[name] = c
  end
  return host_sound(c.pcm, sfxr.RATE, (volume or 1) * M.volume) and true or false
end

ecs.sound = M.play
return M
