-- probe.lua - the editor's probe (the world VM): which lines ran and with
-- what values, breakpoints, for the node graph in lite. replay.c runs it at
-- start (editor/probe.h: the C side, the hook and the hand-over to lite).

local P = { files = {}, recs = {}, gen = 0, ticks = 0, since = {}, breaks = {}, alias = {}, span = {} }
local NIL = {}                                     -- (a local that is nil)
viewer_probe = P
local function norm(p) return (tostring(p):gsub('\\', '/'):lower()) end
local function fmtv(v, deep)
  local t = type(v)
  if t == 'number' then
    if v == math.floor(v) and math.abs(v) < 1e15 then return string.format('%d', v) end
    return string.format('%.4g', v)
  elseif t == 'string' then
    if #v > 24 then v = v:sub(1, 22) .. '..' end
    return string.format('%q', v)
  elseif t == 'table' then
    if deep then return '{..}' end
    local out, n = {}, 0
    for k, x in pairs(v) do
      n = n + 1
      if n > 4 then out[#out + 1] = '..'; break end
      out[#out + 1] = (type(k) == 'string' and (k .. '=') or '') .. fmtv(x, true)
    end
    return '{' .. table.concat(out, ', ') .. '}'
  elseif t == 'function' then return 'function'
  end
  return tostring(v)
end
local function watched(f)

  for w in pairs(P.files) do
    if w == f or w:sub(-#f - 1) == '/' .. f or f:sub(-#w - 1) == '/' .. w then return w end
  end
end
local leaf_cache = {}
local function origin(src)
  local o = leaf_cache[src]
  if o and o.gen == P.gen then return o.w and o or nil end
  local file, line
  local E = package.loaded['ecs']
  local co = E and E.chunk_origins and E.chunk_origins[src]
  if co then file, line = co.file, co.line
  elseif src:sub(1, 1) == '@' then file, line = src:sub(2), 1
  elseif src:sub(1, 1) == '=' and viewer_leaf then
    local path, comp = src:sub(2):match('^(.*)/([^/]+)$')
    if path then
      local ok, f = pcall(viewer_leaf, path == '' and '/' or path, comp)
      if ok and f then file, line = f, 1 end
    end
  end
  o = { gen = P.gen, w = file and watched(norm(file)), line = line }
  if not co then leaf_cache[src] = o end
  return o.w and o or nil
end
local cur
local getlocal = debug.getlocal
-- the C line hook (probe.h) asks: is this chunk's code watched? (once per chunk)
function viewer_probe_watch(src)
  return origin(src) ~= nil
end
-- and calls this on each line of watched code: count it, keep its locals
-- (as they are: formatted when asked for); true: a breakpoint, stop here
function viewer_probe_line(src, line)
  local o = origin(src)
  if not o or not cur then return end
  local fl = o.line + line - 1
  local rf = cur[o.w]
  if not rf then rf = {}; cur[o.w] = rf end
  local r = rf[fl]
  if not r then r = { n = 0, v = {} }; rf[fl] = r end
  r.n = r.n + 1
  P.seq = (P.seq or 0) + 1                           -- (the order lines last ran in: which one changed a variable)
  r.s = P.seq
  local rv = r.v
  for i = 1, 200 do
    local k, v = getlocal(2, i)
    if not k then break end
    if v == nil then v = NIL end
    rv[k] = v
  end
  if not (P.co and coroutine.running() == P.co) then return end
  local b = P.breaks[o.w]
  local hit, as = b and b[fl], nil
  local a = not hit and P.alias[o.w] and P.alias[o.w][fl]
  if a then                                         -- a function's definition runs on its 'end' line (Lua):
    local d = debug.getinfo(2, 'S')                  -- there, but not that function's own return
    if not (d and o.line + d.linedefined - 1 == a.fdef) then hit, as = true, a.as end
  end
  local c = P.cont                                   -- continued from a stop: a statement on several lines
  if c and o.w == c.w then                            -- (a call: back on its first line) doesn't stop again
    local d = 2
    while debug.getinfo(d + 1, 'l') do d = d + 1 end
    if d < c.depth then P.cont = nil
    elseif d == c.depth then
      if fl == c.line then if not P.step then hit, as = nil, nil end
      elseif not (fl > c.line and fl <= c.last) then P.cont = nil end
    end
  end
  local depth
  if P.step or hit then                              -- (how deep: stepping over / out compares it)
    depth = 2
    while debug.getinfo(depth + 1, 'l') do depth = depth + 1 end
  end
  if not hit and P.step then
    local m = P.step.mode
    hit = m == 'in' or (m == 'over' and depth <= P.step.depth) or (m == 'out' and depth < P.step.depth)
  end
  if hit then
    P.step = nil
    P.brk = { file = o.w, line = as or fl, raw = fl, n = (P.brk_n or 0) + 1, depth = depth }
    P.brk_n = P.brk.n
    P.brk_rec = { t = P.brk_t or 0, files = cur, brk = P.brk }
    return true
  end
end
local function off(...) probe_hook_off(); return ... end
local function wrap(w, on)
  for name, s in pairs(w.systems or {}) do
    if s.fn and s.fn ~= s.probe_wrap then s.probe_orig, s.probe_wrap = nil, nil end
    local want = on and s.code and s.fn and origin('=' .. name)
    if want and not s.probe_wrap then
      local f = s.fn
      local g = function(...) probe_hook_on(); return off(f(...)) end
      s.probe_orig, s.probe_wrap, s.fn = f, g, g
    elseif not want and s.probe_wrap then
      s.fn, s.probe_orig, s.probe_wrap = s.probe_orig, nil, nil
    end
  end
end
-- a tick: with breakpoints set, it runs as a coroutine the line hook can
-- stop (true: stopped at one; viewer_tick_resume() goes on, viewer_tick_abort()
-- drops it: the world is left mid-tick, for a stop / seek / reload)
local tick0 = viewer_tick
local function tick_done(w, ok, err)
  if P.step then P.step = { mode = 'in', depth = 0 } end   -- (the frame ended while stepping: its next one's first line)
  probe_hook_off()
  wrap(w, true)
  P.pending = cur
  P.co, P.brk, P.brk_rec, P.cont = nil, nil, nil, nil
  if not ok then error(err, 0) end
end
-- a system being built (its setup: the code before its run function, and
-- the modules it requires: the first frame after a load / Play / Rewind, or
-- an edit): watched, the hook is on while it runs, so its lines count and a
-- breakpoint stops there. With breakpoints set, a build outside a tick waits
-- for the next tick (ecs.DEFER), where it can stop.
local function built(ok, ...) probe_hook_off(); if not ok then error((...), 0) end return ... end
local function on_build(chunk, name)
  if next(P.breaks) and not (P.co and coroutine.running() == P.co) then
    local E = package.loaded['ecs']                  -- (outside a tick it couldn't stop, nor the modules it
    if E and E.DEFER then return E.DEFER end         -- requires: built in the next tick instead)
  end
  if not (cur and (origin('=' .. name) or next(P.breaks))) then return chunk() end
  probe_hook_on()
  return built(pcall(chunk))
end
-- the boot step: Play / Rewind arm it (viewer_boot_arm); the first frame after
-- runs the world's main script again before the world ticks (a dry run: the
-- world it builds is dropped; the game goes on with the edited world), only
-- if that script has breakpoints: its top level stops like any frame's code
function viewer_boot_arm(file) P.boot = file end
local function run_boot(path)
  local E = package.loaded['ecs']
  local f = E and io.open(path, 'rb')
  if not f then return end
  local src = f:read('*a'); f:close()
  if src:match('^%s*return%s*{%s*version') then return end
  local chunk = E.loadscript(src, path, 'lua')
  if not chunk then return end
  local kept = {}                                    -- (the modules it requires that have breakpoints: loaded again, to stop in)
  for name, v in pairs(package.loaded) do
    local f = type(name) == 'string' and package.searchpath and package.searchpath(name, package.path)
    local wf = f and watched(norm(f))
    if wf and P.breaks[wf] then kept[name] = v; package.loaded[name] = nil end
  end
  probe_hook_on()
  pcall(chunk)
  probe_hook_off()
  for name, v in pairs(kept) do package.loaded[name] = v end   -- (the game goes on with the ones it has)
end
local function booting(path) return function(w, dt) run_boot(path); return tick0(w, dt) end end
function viewer_tick(w, dt, t)
  local boot = P.boot
  P.boot = nil
  if boot and not (boot:match('%.lua$') and P.breaks[watched(norm(boot)) or '']) then boot = nil end
  local E = package.loaded['ecs']
  if E then E.on_build = next(P.files) and on_build or nil end
  if not next(P.files) then
    if P.wrapped then wrap(w, false); P.wrapped = nil end
    return tick0(w, dt)
  end
  cur = {}
  probe_hook_reset()
  wrap(w, true)
  P.wrapped = true
  if not (next(P.breaks) or P.step) then return tick_done(w, pcall(tick0, w, dt)) end
  P.co, P.co_w, P.brk_t = coroutine.create(boot and booting(boot) or tick0), w, t
  local ok, err = coroutine.resume(P.co, w, dt)
  if ok and coroutine.status(P.co) == 'suspended' then return true end
  return tick_done(w, ok, err)
end
function viewer_tick_resume()
  if not P.co then return end
  local k = P.brk                                    -- (its statement: not again until it's left)
  local sp = k and P.span[k.file]
  P.cont = k and { w = k.file, line = k.raw, depth = k.depth, last = sp and sp[k.raw] or k.raw } or nil
  P.brk, P.brk_rec = nil, nil
  local ok, err = coroutine.resume(P.co)
  if ok and coroutine.status(P.co) == 'suspended' then return true end
  return tick_done(P.co_w, ok, err)
end
function viewer_tick_abort()
  if not P.co then return end
  probe_hook_off()
  if P.co_w then wrap(P.co_w, true) end
  P.co, P.brk, P.brk_rec, P.pending, P.step, P.cont = nil, nil, nil, nil, nil, nil
end
-- breakpoints, from the editor: a file of one is always watched
-- as > 0: an alias (line: where Lua runs it; as: the breakpoint's line, the
-- header of a function defined there: fdef, its own return doesn't count)
function viewer_break_set(file, line, on, as, fdef)
  local f = norm(file)
  if as and as < 0 then                               -- (as < 0: that breakpoint's statement ends on line -as)
    local sp = P.span[f] or {}
    sp[line] = on and -as or nil
    P.span[f] = next(sp) and sp or nil
    return
  end
  if as and as > 0 then
    local al = P.alias[f] or {}
    al[line] = on and { as = as, fdef = fdef } or nil
    P.alias[f] = next(al) and al or nil
    P.gen = P.gen + 1
    return
  end
  local b = P.breaks[f] or {}
  b[line] = on or nil
  P.breaks[f] = next(b) and b or nil
  if P.breaks[f] then P.files[f] = math.huge elseif P.files[f] == math.huge then P.files[f] = os.time() end
  P.gen = P.gen + 1
  probe_hook_reset()
end
-- stepping from a stop: 'over' (the next line in this function or its caller),
-- 'in' (the next line anywhere), 'out' (the next line in a caller), 'continue'
function viewer_break_step(mode)
  if not P.brk then return end
  P.step = mode ~= 'continue' and { mode = mode, depth = P.brk.depth or 0 } or nil
end
function viewer_break_where()                       -- stopped at a breakpoint: file, line, which stop
  if P.brk then return P.brk.file, P.brk.line, P.brk.n end
end
function viewer_probe_commit(t)
  local c = P.pending
  P.pending = nil
  if not c then return end
  while #P.recs > 0 and P.recs[#P.recs].t >= t do P.recs[#P.recs] = nil end
  P.ticks = P.ticks + 1
  P.recs[#P.recs + 1] = { t = t, files = c, n = P.ticks }
  if #P.recs > 1500 then table.remove(P.recs, 1) end
end
local function rec_at(t)                          -- the record of the frame shown (the last at or before t)
  local lo, hi, best = 1, #P.recs, nil
  while lo <= hi do
    local m = math.floor((lo + hi) / 2)
    if P.recs[m].t <= t + 1e-9 then best = m; lo = m + 1 else hi = m - 1 end
  end
  return best and P.recs[best]
end
-- an expression's value in the frame shown (a wire from an expression node):
-- evaluated with the locals recorded at its line (then the game's globals).
-- The editor only asks for expressions without calls (nothing in the game runs).
-- what an expression shown in the graph may call: functions that only compute
local function only(lib, names)
  local t = {}
  for n in names:gmatch('%S+') do t[n] = lib[n] end
  return t
end
local SAFE = { tostring = tostring, tonumber = tonumber, type = type, select = select,
  math = only(math, 'abs ceil floor max min sqrt sin cos tan asin acos atan atan2 exp log pow fmod modf deg rad huge pi tointeger type ult maxinteger mininteger'),
  string = only(string, 'byte char find format len lower upper rep reverse sub match') }
function viewer_probe_eval(file, t, line, src)
  local r = P.brk_rec or rec_at(t)
  local rf = r and r.files[norm(file)]
  local rl = rf and rf[line]
  if not rl then return nil end
  local env = setmetatable({}, { __index = function(_, k)
    local v = rl.v[k]
    if SAFE[k] ~= nil then                            -- the only functions it may call (the graph asks for no others)
      if v ~= nil then error('shadowed: ' .. k) end   -- (a local of that name: not the library)
      return SAFE[k]
    end
    if v == NIL then return nil end
    if v ~= nil then return v end
    local g = _G[k]
    if type(g) == 'function' then return nil end      -- (any other function: never called from here)
    return g
  end })
  local fields = src:match('^\1fields (.*)$')       -- "\1fields x": a table's fields, "key\tvalue" a line (a watch unfolded)
  local f = load('return ' .. (fields or src), '=eval', 't', env)
  if not f then return nil end
  local ok, v = pcall(f)
  if not ok then return nil end
  if fields then
    if type(v) ~= 'table' then return nil end
    local keys = {}
    for k in pairs(v) do if type(k) == 'string' or type(k) == 'number' then keys[#keys + 1] = k end end
    table.sort(keys, function(a, b) if type(a) == type(b) then return a < b end return type(a) == 'number' end)
    local out = {}
    for i = 1, math.min(#keys, 40) do out[#out + 1] = tostring(keys[i]) .. '\t' .. fmtv(v[keys[i]]) end
    if #keys > 40 then out[#out + 1] = '..\t(' .. (#keys - 40) .. ' more)' end
    return table.concat(out, '\n')
  end
  if v == nil then return 'nil' end
  return fmtv(v)
end
function viewer_probe_get(file, t, stopped, paused)
  local f = norm(file)
  local now = os.time()
  if not P.files[f] then P.gen = P.gen + 1; probe_hook_reset(); P.since[f] = P.ticks + 1 end
  P.files[f] = now
  for k, at in pairs(P.files) do
    if now - at > 300 then P.files[k] = nil; P.gen = P.gen + 1; probe_hook_reset() end
  end
  if stopped or not paused then return 'return {}' end
  local r = P.brk_rec or rec_at(t)                    -- (stopped at a breakpoint: the frame so far)
  -- paused on a frame that ran before this file was watched: ask for a
  -- frame more (probe_step_wanted, replay.c steps one tick, stays paused)
  if not r or (r.n and r.n < (P.since[f] or 0)) then viewer_probe_step = true end   -- (a breakpoint's: no n)
  if not r then return 'return {}' end
  if P.cache_r == r and P.cache_f == f then return P.cache_s end
  local lines = r.files[f]
  local out = { 'return {t=', string.format('%.4f', r.t), ',stopped=', tostring(not not stopped),
                r.brk and r.brk.file == f and (',brk=' .. r.brk.line .. ',brk_n=' .. r.brk.n) or '', ',lines={' }
  for l, x in pairs(lines or {}) do
    out[#out + 1] = '[' .. l .. ']={n=' .. x.n .. ',s=' .. (x.s or 0) .. ',v={'
    for k, v in pairs(x.v) do
      if k:sub(1, 1) ~= '(' then out[#out + 1] = '[' .. string.format('%q', k) .. ']=' .. string.format('%q', v == NIL and 'nil' or fmtv(v)) .. ',' end
    end
    out[#out + 1] = '}},'
  end
  out[#out + 1] = '}}'
  P.cache_r, P.cache_f, P.cache_s = r, f, table.concat(out)
  return P.cache_s
end
-- the poor man's profiler (the tree's bars): the time each node's systems
-- take a tick (ecs.profiler), with its children's (inclusive), in ms,
-- smoothed over a few frames
local PR = { acc = {}, ms = {} }
local E = package.loaded['ecs']
if E and not viewer_standalone then
  E.profiler = { now = probe_now, add = function(p, s) PR.acc[p] = (PR.acc[p] or 0) + s end }
end
-- every tick's (smoothed) costs are kept by game time, so the timeline can be
-- scrubbed back over them (the last 5 minutes at 60 fps): each frame a list
-- of ms, in the order of PR.paths (a path's index never changes in a session)
PR.paths, PR.index, PR.recs = {}, {}, {}
local up, nup = {}, 0  -- path -> its parent's (worked out once; forgotten past 20000)
local function parent(q)
  local u = up[q]
  if not u then
    if nup > 20000 then up, nup = {}, 0 end
    u = q:match('^(.+)/[^/]*$') or '/'; up[q], nup = u, nup + 1
  end
  return u
end
function viewer_prof_commit(t)
  local incl = {}
  for p, s in pairs(PR.acc) do
    local q = p
    while true do
      incl[q] = (incl[q] or 0) + s * 1000
      if q == '/' then break end
      q = parent(q)
    end
  end
  PR.acc = {}
  for p, v in pairs(PR.ms) do
    if not incl[p] then local x = v * 0.85; PR.ms[p] = x > 0.0005 and x or nil end
  end
  for p, v in pairs(incl) do PR.ms[p] = (PR.ms[p] or v) * 0.85 + v * 0.15 end
  if not t then return end
  local row = { t = t }
  for p, v in pairs(PR.ms) do
    local i = PR.index[p]
    if not i then i = #PR.paths + 1; PR.paths[i] = p; PR.index[p] = i end
    row[i] = v
  end
  local R = PR.recs
  while #R > 0 and R[#R].t >= t do R[#R] = nil end   -- (resumed after a seek: a new future)
  R[#R + 1] = row
  if #R > 18000 then                               -- (the oldest go 1000 at a time, not one by one each tick)
    table.move(R, 1001, #R, 1)
    for i = #R - 999, #R do R[i] = nil end
  end
end
function viewer_prof_reset() PR.acc, PR.ms, PR.paths, PR.index, PR.recs, PR.shown = {}, {}, {}, {}, {}, nil end
-- which costs the tree shows this frame: running, the live ones; paused, the
-- ones of the frame at game time t (the timeline scrubbed back)
function viewer_prof_select(t, paused)
  PR.shown = nil
  if not paused then return end
  local R, lo, hi, best = PR.recs, 1, #PR.recs, nil
  while lo <= hi do
    local m = math.floor((lo + hi) / 2)
    if R[m].t <= t + 1e-9 then best = m; lo = m + 1 else hi = m - 1 end
  end
  PR.shown = best and R[best] or {}
end
function viewer_prof_ms(p)
  local s = PR.shown
  if s then local i = PR.index[p]; return i and s[i] or 0 end
  return PR.ms[p] or 0
end
