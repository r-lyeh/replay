-- game: Parcels, a Game & Watch in spirit. Parcels come down three chutes,
-- a step each beat; the worker (left / right, or A / D) catches them on his
-- tray at the bottom. One that reaches the ground breaks: a miss; three and
-- it's over (space or enter: again). The beat quickens with the score.
-- Its state is data (/data/game/state): it saves, rewinds and shows in the
-- tree like anything else (/data/game: state, and rules: the pace). The lcd system lights the segments from it.
local function rand(st)                            -- a deterministic random (the state keeps its seed: a rewind replays it)
  st.seed = (st.seed * 16807) % 2147483647
  return st.seed / 2147483647
end
local LEFT = { left = true, a = true, ["pad dpleft"] = true, ["pad left"] = true }      -- (a gamepad: dpad / left stick)
local RIGHT = { right = true, d = true, ["pad dpright"] = true, ["pad right"] = true }
local AGAIN = { space = true, ["return"] = true, ["keypad enter"] = true, ["pad a"] = true, ["pad start"] = true }


local function beat(st, rules)                     -- everything moves one step
  st.splat = 0
  local keep = {}
  for _, b in ipairs(st.boxes) do
    b.r = b.r + 1
    if b.r <= 4 then keep[#keep + 1] = b
    elseif st.man == b.c then st.score = st.score + 1   -- (on the tray: caught)
    else st.misses = st.misses + 1; st.splat = b.c end
  end
  st.boxes = keep
  if st.misses >= rules.misses then st.over = true return end
  local busy = {}
  for _, b in ipairs(st.boxes) do if b.r <= 2 then busy[b.c] = true end end
  local want = math.min(3, 1 + math.floor(st.score / 15))   -- (more at once as it goes)
  if #st.boxes < want * 2 and rand(st) < 0.6 then
    local c = 1 + math.floor(rand(st) * 3)
    if not busy[c] then st.boxes[#st.boxes + 1] = { c = c, r = 1 } end
  end
end

return function(w, dt)
  local g, input = w:node("/data/game"), w:node("/data/input/p1")
  if not (g and input and g.c.state and g.c.rules) then return end
  local st, rules = g.c.state, g.c.rules
  local taps = input.c.taps or {}                  -- (pressed since the last frame: the input system's)
  local function edge(set) for k in pairs(set) do if taps[k] then return true end end return false end
  if st.over then
    if edge(AGAIN) then
      st.score, st.misses, st.man, st.boxes, st.splat, st.t, st.beats, st.over = 0, 0, 2, {}, 0, 0, 0, false
    end
  else
    if edge(LEFT) then st.man = math.max(1, st.man - 1) end   -- (moves at once, between beats)
    if edge(RIGHT) then st.man = math.min(3, st.man + 1) end
    st.t = st.t + dt
    local every = math.max(rules.fastest, rules.beat - st.score * rules.faster)
    if st.t >= every then
      st.t = st.t - every
      st.beats = st.beats + 1
      beat(st, rules)
    end
  end
  input.c.taps = {}
end
