-- dialog.lua - .dialog files: conversations with a character (plugins/dialog
-- shows and edits them; games read them with w:dialog(name) and run them
-- with the functions below). A first take on mario's sample
-- (plugins/dialog/sample.dialog); see plugins/dialog/README.md.
--
--   0 Hi! Is this your first visit? [1,2]   line 0: said; the player picks line 1 or 2
--   1 Yes, I just arrived -> 3              a line, then line 3 (a choice: picking it goes there)
--   3 Awesome! Have fun!                    no arrow: the talk ends after it
--   10 Great! -> 13                         13 is past a `--`: the talk ends; the next one starts at 13
--   12 Please! -> 5                         back to an earlier line: the talk ends; the next one starts at 5
--   13 Oh hi -> 13                          leads to itself: the talk ends, and the next starts here
--   --                                      the end of a conversation (a scene)
--   #monster It is said... {...} Scary!     the answer to "Tell me more about monster" (once the player knows #monster)
--
-- In a line: #word (a topic: the player learns it on hearing it), :name: (an
-- emote: the character shows it), {...} (three dots, slowly), {wait 2} (2 s),
-- // a comment (to the end of the line). //@dx,dy at the very end: where its
-- box was moved in the chart (plugins/dialog), ignored by games.
local M = {}

local function trim(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end

-- one line's text -> parts: { text = "..." } / { emote = "grin" } / { wait = 0.5 } / { topic = "monster", text = "monster" }
function M.parts(text)
  local out, i = {}, 1
  local function add(t) if t ~= "" then out[#out + 1] = { text = t } end end
  while i <= #text do
    local a, b, inner = text:find("{([^}]*)}", i)
    local e1, e2, emote = text:find(":([%a_][%w_]*):", i)
    local t1, t2, topic = text:find("#([%a_][%w_]*)", i)
    local first = math.min(a or math.huge, e1 or math.huge, t1 or math.huge)
    if first == math.huge then add(text:sub(i)); break end
    add(text:sub(i, first - 1))
    if first == a then
      if inner == "..." then                          -- {...}: three dots, slowly
        for _ = 1, 3 do out[#out + 1] = { text = "." }; out[#out + 1] = { wait = 0.25 } end
      else out[#out + 1] = { wait = tonumber(inner:match("^%s*wait%s+([%d%.]+)")) or 0.5 } end
      i = b + 1
    elseif first == e1 then out[#out + 1] = { emote = emote }; i = e2 + 1
    else out[#out + 1] = { topic = topic, text = topic }; i = t2 + 1 end
  end
  return out
end

-- a .dialog's text -> { lines = { [n] = { n, text, parts, next, choices, row } }, start, topics = { [name] = line }, order = { n... }, errors = { { row, msg } } }
function M.parse(src)
  local d = { lines = {}, topics = {}, order = {}, errors = {}, scenes = {} }
  local row, scene = 0, 1
  for raw in (src .. "\n"):gmatch("([^\n]*)\n") do
    row = row + 1
    local s = trim((raw:gsub("\r$", "")))
    local tdx, tdy = s:match("//@(%-?%d+),(%-?%d+)%s*$")   -- (the chart's: where the box was moved, an offset)
    if tdx then s = trim((s:gsub("%s*//@%-?%d+,%-?%d+%s*$", ""))) end
    local comment = s:find("//", 1, true)
    if comment then s = trim(s:sub(1, comment - 1)) end
    if s == "" then
    elseif s:match("^%-%-+$") then scene = scene + 1
    else
      local n, rest = s:match("^(%d+)%s+(.*)$")
      local topic, trest = s:match("^#([%a_][%w_]*)%s+(.*)$")
      if n then
        n = tonumber(n)
        local L = { n = n, row = row, scene = scene, dx = tonumber(tdx), dy = tonumber(tdy) }
        local body, list = rest:match("^(.-)%s*%[([%d%s,]*)%]%s*$")
        if body then
          L.choices = {}
          for c in list:gmatch("%d+") do L.choices[#L.choices + 1] = tonumber(c) end
          rest = body
        else
          local b2, to = rest:match("^(.-)%s*%->%s*(%d+)%s*$")
          if b2 then rest, L.next = b2, tonumber(to) end
        end
        L.text, L.parts = rest, M.parts(rest)
        if d.lines[n] then d.errors[#d.errors + 1] = { row, "line " .. n .. " again (the first one counts)" }
        else d.lines[n] = L; d.order[#d.order + 1] = n end
        d.start = d.start or n
      elseif topic then
        d.topics[topic] = { topic = topic, text = trest, parts = M.parts(trest), row = row, scene = scene, dx = tonumber(tdx), dy = tonumber(tdy) }
      else d.errors[#d.errors + 1] = { row, "not a line: a number first (or #topic)" } end
    end
  end
  for _, n in ipairs(d.order) do                     -- links to lines that aren't there
    local L = d.lines[n]
    for _, c in ipairs(L.choices or {}) do if not d.lines[c] then d.errors[#d.errors + 1] = { L.row, "no line " .. c } end end
    if L.next and not d.lines[L.next] then d.errors[#d.errors + 1] = { L.row, "no line " .. L.next } end
  end
  return d
end

-- the plain text of parts (what's shown): topics as their word, emotes and waits dropped
function M.plain(parts)
  local t = {}
  for _, p in ipairs(parts) do if p.text then t[#t + 1] = p.text end end
  return (table.concat(t):gsub("%s+", " "))
end

-- running a talk. `st` is plain data (keep it in the world: it saves and rewinds):
-- { at = line n | "#topic" | "?" (the player's questions), shown = chars typed so far,
--   wait = s, pick = choice index, start = where the next talk starts,
--   known = { topic = true }, emote = name, done = the talk ended }
-- A talk ends at a line with no arrow, at a line leading back (to itself or
-- to a line above it: the next talk starts there), or at a line leading out
-- of its scene (past a `--`: the next talk starts at that line). Then, if the player knows topics, they can
-- ask "Tell me more about <topic>" (its #topic line answers), or say bye.
M.ASK, M.BYE = "Tell me more about %s", "Bye"
local ASK_LINE = { parts = {} }                      -- (the questions: the character says nothing meanwhile)
local function go(st, at) st.at, st.part, st.typed, st.shown, st.wait, st.pick, st.emote = at, 1, 0, 0, 0, 1, nil end
local function topics_known(d, st)
  local t = {}
  for name in pairs(d.topics) do if st.known[name] then t[#t + 1] = name end end
  table.sort(t)
  return t
end
function M.begin(d, st)
  st.known = st.known or {}
  st.done = false
  go(st, st.start or d.start)
  return st
end
function M.line(d, st)                               -- the line being said (a line, a topic's, or the questions)
  if st.at == "?" then return ASK_LINE end
  if type(st.at) == "string" then return d.topics[st.at:sub(2)] end
  return d.lines[st.at]
end
-- type it out: `cps` letters a second; waits and emotes on the way. -> true while typing
function M.update(d, st, dt, cps)
  local L = M.line(d, st)
  if not L or st.done then return false end
  if st.wait > 0 then st.wait = st.wait - dt; return true end
  local budget = dt * (cps or 40)
  while budget > 0 do
    local p = L.parts[st.part]
    if not p then return false end
    if p.wait then st.wait = p.wait; st.part = st.part + 1; return true
    elseif p.emote then st.emote = p.emote; st.part = st.part + 1
    else
      if p.topic then st.known[p.topic] = true end
      local left = #p.text - (st.typed or 0)
      local take = math.min(left, math.ceil(budget))
      st.typed = (st.typed or 0) + take
      st.shown = st.shown + take
      budget = budget - take
      if st.typed >= #p.text then st.part, st.typed = st.part + 1, 0 end
    end
  end
  return true
end
function M.typed(d, st)                              -- the text shown so far
  local L = M.line(d, st)
  if not L then return "" end
  return M.plain(L.parts):sub(1, st.shown)
end
function M.finish(d, st)                             -- skip the typing: all of the line at once
  local L = M.line(d, st)
  if not L then return end
  for i = st.part, #L.parts do
    local p = L.parts[i]
    if p.emote then st.emote = p.emote end
    if p.topic then st.known[p.topic] = true end
  end
  st.part, st.typed, st.wait = #L.parts + 1, 0, 0
  st.shown = #M.plain(L.parts)
end
function M.choices(d, st)                            -- the player's options now: { { n | topic, text }... } | nil
  if st.at == "?" then
    local out = {}
    for _, name in ipairs(topics_known(d, st)) do out[#out + 1] = { topic = name, text = M.ASK:format(name) } end
    out[#out + 1] = { bye = true, text = M.BYE }
    return out
  end
  local L = M.line(d, st)
  if not (L and L.choices) then return nil end
  local out = {}
  for _, c in ipairs(L.choices) do
    local C = d.lines[c]
    if C then out[#out + 1] = { n = c, text = M.plain(C.parts) } end
  end
  return out
end
local function the_end(d, st)                        -- the conversation is over: questions, if any, else done
  if #topics_known(d, st) > 0 then go(st, "?"); return true end
  st.done = true
  return false
end
-- go on (the player pressed the button): the next line, a choice's, a question, or the end. -> false: the talk ended
function M.advance(d, st)
  local L = M.line(d, st)
  if not L then st.done = true; return false end
  if (st.part or 1) <= #L.parts then M.finish(d, st); return true end
  if st.at == "?" then                               -- a question picked (or bye)
    local c = M.choices(d, st)[st.pick or 1]
    if not c or c.bye then st.done = true; return false end
    go(st, "#" .. c.topic)
    return true
  end
  if type(st.at) == "string" then go(st, "?"); return true end   -- a topic answered: back to the questions
  local to, from = nil, L
  if L.choices then
    local c = L.choices[st.pick or 1]
    local C = c and d.lines[c]
    for _, p in ipairs(C and C.parts or {}) do if p.topic then st.known[p.topic] = true end end
    to, from = C and C.next, C or L
  else to = L.next end
  local T = to and d.lines[to]
  if not T then return the_end(d, st) end            -- no arrow: the end
  if T.row <= from.row or T.scene ~= L.scene then     -- back (to itself, or an earlier line), or past a `--`: the next talk starts there
    st.start = to
    return the_end(d, st)
  end
  go(st, to)
  return true
end

-- a parsed file's methods: d:begin(st), d:update(st, dt, cps), d:typed(st),
-- d:choices(st), d:advance(st), d:finish(st), d:line(st)
M.methods = { __index = { begin = M.begin, update = M.update, typed = M.typed, choices = M.choices,
                          advance = M.advance, finish = M.finish, line = M.line, plain = function(_, parts) return M.plain(parts) end } }

-- games: w:dialog("fairy.dialog") -> the parsed file (assets/), read again when it changes
local ok, ecs = pcall(require, "ecs")
if ok and type(ecs) == "table" and ecs.assets then
  local cache = {}
  ecs.dialog = function(w, name)
    name = tostring(name):gsub("^/assets/", ""):gsub("^/", "")
    if not name:find("%.%w+$") then name = name .. ".dialog" end
    local text = ecs.assets.read(name)
    if not text then return nil, "no asset " .. name end
    local c = cache[name]
    if not c or c.text ~= text then c = { text = text, d = setmetatable(M.parse(text), M.methods) }; cache[name] = c end
    return c.d
  end
end
return M
