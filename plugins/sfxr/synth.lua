-- synth.lua - the sfxr synth: runtime/sfxr.lua (games play the same sounds:
-- runtime/sound.lua, w:sound). Loaded from there, so there's one copy.
local here = (debug.getinfo(1, "S").source:match("^@(.*)[/\\][^/\\]*$") or ".")
return dofile(here .. "/../../runtime/sfxr.lua")
