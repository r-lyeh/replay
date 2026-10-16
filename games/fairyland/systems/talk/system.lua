-- talk: near the fairy, the talk button starts a conversation (her .dialog:
-- runtime/dialog.lua runs it). The button goes on (or shows all of a line
-- being typed); up / down choose an answer.
local room = require "room"
return function(w, dt)
  local st, rl, input = w:node("/data/state"), w:node("/data/rules"), w:node("/data/input/p1")
  if not (st and rl and input) then return end
  local talk, walk, R = st.c.talk, st.c.walk, rl.c.room
  local taps = input.c.taps or {}
  input.c.taps = {}
  local d = w:dialog(R.dialog)
  if not d then return end
  local f = w:node("/objects/fairy").c.xform
  local near = math.abs(f.x - walk.x) < R.reach and math.abs(f.y - walk.y) < R.reach
  talk.near = near
  if not talk.on then
    if near and room.any(taps, room.TALK) then talk.on = true; d:begin(talk) end
    return
  end
  d:update(talk, dt, R.cps)
  local ch = d:choices(talk)
  local typing = (talk.part or 1) <= #(d:line(talk) or { parts = {} }).parts
  if ch and not typing then
    if room.any(taps, room.UP) then talk.pick = (talk.pick - 2) % #ch + 1 end
    if room.any(taps, room.DOWN) then talk.pick = talk.pick % #ch + 1 end
  end
  if room.any(taps, room.TALK) then
    if not d:advance(talk) then talk.on = false end
  end
end
