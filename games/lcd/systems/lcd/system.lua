-- lcd: which segments are lit, from the game's state. Every segment is a
-- node of /objects/lcd drawing its frame of the LCD's "on" picture where it
-- belongs (image = { "/assets/lcd.atlas.lua", frame = <its name>, at =
-- "sheet" }); here each one is shown or hidden. Stopped (the authored
-- world), none is hidden: every segment shows, as on a real one's test.
local DIGITS = { [0] = "abcdef", "bc", "abdeg", "abcdg", "bcfg", "acdfg", "acdefg", "abc", "abcdefg", "abcdfg" }

return function(w, dt)
  local g = w:node("/data/game")
  local st = g and g.c.state
  if not st then return end
  local lit = {}
  lit["man" .. st.man] = true
  for _, b in ipairs(st.boxes) do lit["box" .. b.c .. b.r] = true end
  if st.splat > 0 then lit["splat" .. st.splat] = true end
  for i = 1, st.misses do lit["miss" .. i] = true end
  if st.misses > 0 then lit.misslabel = true end
  if st.over and st.beats % 2 == 0 then lit.over = true end
  if st.over then                                  -- (over: it blinks, a beat on, a beat off)
    st.blink = (st.blink or 0) + dt
    if st.blink >= 0.5 then st.blink = 0; st.beats = st.beats + 1 end
  end
  local s = string.format("%4d", math.min(9999, st.score))
  for i = 1, 4 do
    local ch = s:sub(i, i)
    if ch ~= " " then for seg in DIGITS[tonumber(ch)]:gmatch(".") do lit["d" .. i .. seg] = true end end
  end
  for _, n in ipairs(w:select("/objects/lcd/*")) do
    local hide = not lit[n.name] or nil
    if n.c.hidden ~= hide then n.c.hidden = hide end
  end
end
