-- boot.lua - the viewer's Lua side (play.exe, the game's world VM): loading a
-- world, ticking, the timeline, the tree and properties panel, saving, the
-- plugins and assets folders. replay.c runs it once at start (runtime/, next
-- to the exe or in the cwd; Export ships it with runtime/'s other modules).
-- Globals named viewer_* are its API: C calls them by name.
-- Edit it like any Lua file; it's read when the editor starts.

-- Play runs the game as it is on disk, except what the editor has changed
-- and not saved yet: those buffers win (like UE). viewer_unsaved: file
-- (normalized absolute path) -> its editor text. Every read of the game
-- goes through it: io.open for reading (scripts, folder worlds through fs,
-- ecs.system's source text) and require (a searcher before the files').
viewer_unsaved = {}
function viewer_unsaved_key(p)
  p = viewer_abspath and viewer_abspath(tostring(p)) or tostring(p)
  return (p:gsub('\\', '/'):gsub('/%./', '/'):lower())
end
local function mem_file(text)                     -- a read-only file over a string
  local pos, f = 1, {}
  function f:read(...)
    local out = {}
    for i, fmt in ipairs({ ... }) do
      if type(fmt) == 'number' then
        if pos > #text then out[i] = nil; break end
        out[i] = text:sub(pos, pos + fmt - 1); pos = pos + fmt
      else
        fmt = tostring(fmt):gsub('^%*', '')
        if fmt:sub(1, 1) == 'a' then out[i] = text:sub(pos); pos = #text + 1
        elseif fmt:sub(1, 1) == 'n' then
          local s, e = text:find('^%s*[-+]?%d*%.?%d+[eE]?[-+]?%d*', pos)
          if not s then out[i] = nil; break end
          out[i] = tonumber(text:sub(s, e)); pos = e + 1
        else
          if pos > #text then out[i] = nil; break end
          local e = text:find('\n', pos, true) or #text + 1
          out[i] = text:sub(pos, fmt:sub(1, 1) == 'L' and e or e - 1); pos = e + 1
        end
      end
    end
    if select('#', ...) == 0 then
      if pos > #text then return nil end
      local e = text:find('\n', pos, true) or #text + 1
      local l = text:sub(pos, e - 1); pos = e + 1; return l
    end
    return table.unpack(out, 1, select('#', ...))
  end
  function f:lines(...) local a = { ... } return function() return f:read(table.unpack(a)) end end
  function f:seek(whence, off)
    whence, off = whence or 'cur', off or 0
    pos = (whence == 'set' and 0 or whence == 'end' and #text or pos - 1) + off + 1
    return pos - 1
  end
  function f:close() return true end
  function f:setvbuf() return true end
  return f
end
local io_open = io.open
function io.open(path, mode)
  if not (mode or 'r'):find('[wa+]') then
    local t = next(viewer_unsaved) and viewer_unsaved[viewer_unsaved_key(path)]
    if t then return mem_file(t) end
  end
  return io_open(path, mode)
end
table.insert(package.searchers or package.loaders, 2, function(name)
  if not next(viewer_unsaved) then return nil end
  local f = package.searchpath(name, package.path)
  local t = f and viewer_unsaved[viewer_unsaved_key(f)]
  if not t then return nil end
  local chunk, err = load(t, '@' .. f)
  if not chunk then error(err, 0) end
  return chunk, f
end)
local ecs = require('ecs')
if ecs.code_globals and dd then ecs.code_globals.dd = dd end  -- debugdraw inside systems
local viewer_disk, viewer_file, viewer_last_disk
local memory_saves = ecs.saves  -- (savegames: in memory, unless the world is a folder: its saves/)
pcall(require, 'sound')  -- (w:sound: runtime/sound.lua plays a game's .sfx through the host)
pcall(require, 'dialog')  -- (w:dialog: runtime/dialog.lua reads a game's .dialog files)
pcall(require, 'bullets')  -- (w:bullets: runtime/bullets.lua plays a game's .bullets patterns)
local function assets_in(dir)  -- w:asset / w:sound read a game's files from its assets/ folder
  local fs = require('fs')
  return function(name) return fs.read(fs.join(dir, name)) end
end
local function disk_saves(d)
  local fs = require('fs')
  return {
    read = function(name) return fs.read(fs.join(d:dir('/saves'), name .. '.sav')) end,
    write = function(name, text)
      local dir = d:dir('/saves')
      fs.mkdir(dir)
      return fs.write(fs.join(dir, name .. '.sav'), text) and true or false
    end,
  }
end
-- script worlds: property edits are saved as an overrides file next to
-- the script (scene1.lua -> scene1.overrides.lua): the fields that differ
-- from the world the script builds (viewer_script_base; ecs.overrides).
-- Loading runs the script, then applies it (viewer_script_disk = result),
-- so script changes to other fields keep coming through.
local viewer_script_base, viewer_script_disk
function viewer_overrides_path(file)
  return (file:gsub('%.%w+$', '')) .. '.overrides.lua'
end
function viewer_apply_overrides(w, path)
  local ok, b = w:save('/**')
  if not ok then return nil, b end
  viewer_script_base = b
  local f = io.open(viewer_overrides_path(path), 'rb')
  if f then
    local src = f:read('*a'); f:close()
    local ok2, err = ecs.apply_overrides(w, src)
    if not ok2 then return nil, viewer_overrides_path(path) .. ': ' .. tostring(err) end
  end
  viewer_script_disk = select(2, w:save('/**', true))
  return w
end
local function write_overrides(t)  -- t: the full world to keep on disk
  local ok, patch, count = ecs.overrides(viewer_script_base, t)
  if not ok then return false, patch end
  local p = viewer_overrides_path(viewer_file)
  if count == 0 then
    os.remove(p)  -- no overrides left
  else
    local f, err = io.open(p, 'wb')
    if not f then return false, err end
    f:write('-- overrides for ' .. viewer_file:match('[^/\\]*$') .. ': property edits saved by the viewer.\n'
         .. '-- The script builds the world, then this is applied on top. Delete it to undo all.\n')
    f:write(patch); f:close()
  end
  viewer_script_disk = select(2, t:save('/**', true))
  return true
end
function viewer_game_name()  -- "pong" (games/pong/), "pong.lua": the game's folder or file name
  return ((viewer_file or '?'):gsub('[/\\]+$', ''):match('[^/\\]+$') or '?')
end
function viewer_new_session() viewer_file = nil end  -- (tests: the next viewer_load is a later session: its undo stack from disk)
function viewer_load(path)
  local again = viewer_file == path and viewer_history  -- (the same world read again: its undo stack stays)
  viewer_disk, viewer_file, viewer_file_blob = nil, path, nil
  ecs.saves = memory_saves
  ecs.assets.read = assets_in((tostring(path):gsub('[/\\]+$', ''):match('^(.*)[/\\]') or '.') .. '/common')   -- (a script: common/ beside it, shared by the single-file games)
  viewer_history = {}
  viewer_script_base, viewer_script_disk = nil, nil
  if hostfs.isdir(path) then
    local d = require('disk').new(path)
    local ok, blob = d:read('/**')
    if not ok then return nil, blob end
    local ok2, w = ecs.load(blob, '/')
    if not ok2 then return nil, w end
    viewer_disk, viewer_last_disk = d, blob
    ecs.saves = disk_saves(d)
    ecs.assets.read = assets_in(d:dir('/assets'))
    if again then viewer_history = again else viewer_history_load() end
    return w
  end
  local f, err = io.open(path, 'rb')
  if not f then return nil, err end
  local src = f:read('*a'); f:close()
  if src:match('^%s*return%s*{%s*version') then  -- a save() blob
    local ok, w = ecs.load(src, '/')
    if ok then viewer_file_blob = select(2, w:save('/**', true)); return w end
    return nil, w
  end
-- ecs.loadscript remembers the text, for ecs.system(function() ... end)
  local lang = path:match('%.(%w+)$')
  if not ecs.languages[lang] then lang = 'lua' end
  local name = lang == 'lua' and path or path:match('[^/\\]+$')  -- hurdy: short chunk name
  local chunk, map = ecs.loadscript(src, name, lang)
  if not chunk then return nil, map end
  local ok, w = pcall(chunk)
  if not ok then return nil, map and ecs.remap_error(tostring(w), name, map) or w end
  if type(w) == 'string' then
    local ok2, w2 = ecs.load(w, '/')
    if ok2 then return w2 end
    return nil, w2
  end
  if type(w) == 'table' and w.nodes and w.root then return viewer_apply_overrides(w, path) end
  return nil, 'script must return a world (or a save() blob)'
end
function viewer_tick(w, dt) w:tick('/**', dt) end
-- Play checks first that every Lua file the game reads compiles: the
-- world's own (the script; or every .lua / .hurdy file of the folder) and
-- every module loaded (required), as the editor has them (unsaved text
-- wins). -> nil, or the first failure: file, line, message
function viewer_check(path)
  local fs = require('fs')
  local texts = viewer_unsaved_new or viewer_unsaved
  local seen = {}
  local function check(f, lang)
    f = fs.join(f)
    if seen[f] then return end
    seen[f] = true
    local src = texts[viewer_unsaved_key(f)]
    if not src then
      local h = io_open(f, 'rb')  -- (the disk: not viewer_unsaved's old texts)
      if not h then return end
      src = h:read('*a'); h:close()
    end
    local chunk, err
    if lang == 'lua' then chunk, err = (loadstring or load)(src, '=?')  -- ('=?': long paths aren't cut short in the message)
    else chunk, err = ecs.compile(src, '?', nil, lang) end
    if chunk then return end
    err = tostring(err)
    local line, msg = err:match('^%?:(%d+): ?(.*)$')
    return { f, tonumber(line) or 1, msg or err }
  end
  local function lang_of(name)
    local ext = name:match('%.(%w+)$')
    if ext == 'lua' or (ext and ecs.languages[ext]) then return ext end
  end
  local function walk(dir)  -- a world folder: every code file (not .workspace.lua & co)
    for _, e in ipairs(fs.list(dir)) do
      if e.name:sub(1, 1) ~= '.' then
        local f, r = fs.join(dir, e.name)
        if e.dir then r = walk(f)
        elseif lang_of(e.name) then r = check(f, lang_of(e.name)) end
        if r then return r end
      end
    end
  end
  local r
  if fs.isdir(path) then r = walk(path) else r = check(path, lang_of(path) or 'lua') end
  if not r and package.searchpath then
    local names = {}
    for name in pairs(package.loaded) do if type(name) == 'string' then names[#names + 1] = name end end
    table.sort(names)
    for _, name in ipairs(names) do
      local f = package.searchpath(name, package.path)
      r = f and check(f, 'lua')
      if r then break end
    end
  end
  if r then return r[1], r[2], r[3] end
end
-- Play (from the edited world): the editor's unsaved files in
-- viewer_unsaved_new; when they changed what the game reads (or did last
-- time), the world is built again (from the disk + those), and the edits
-- made in the viewer since it was loaded (props, moves) go on top. Returns
-- the new world, nil (nothing to do) or false, why
function viewer_play_prepare(w, path)
  local new = viewer_unsaved_new or {}
  viewer_unsaved_new = nil
  local before = next(viewer_unsaved) ~= nil
  local same = true
  for k, t in pairs(new) do if viewer_unsaved[k] ~= t then same = false end end
  for k in pairs(viewer_unsaved) do if new[k] == nil then same = false end end
  if same then return nil end
  if not next(new) and not before then return nil end
  viewer_unsaved = new
  for name in pairs(package.loaded) do            -- modules changed (or reverted) in the editor: required again
    local f = type(name) == 'string' and package.searchpath(name, package.path)
    if f and (new[viewer_unsaved_key(f)] ~= nil) then package.loaded[name] = nil end
  end
  local base = viewer_disk and viewer_last_disk or viewer_file_blob or viewer_script_disk
  local patch
  if base then
    local ok, b = w:save('/**')
    if ok then local ok2, p = ecs.diff(base, b); if ok2 then patch = p end end
  end
  local nw, err = viewer_load(path)
  if not nw then return false, err end
  if patch then nw:load(patch, '/') end
  return nw
end

-- code leaves (ecs.code): sync them into systems now if asked, and
-- report the first error, if any
function viewer_code(w, sync)
  if sync and w.sync_code and w.code ~= false then w:sync_code() end
  local ks = {}
  for k in pairs(w.code_err or {}) do ks[#ks + 1] = k end
  if #ks == 0 then return nil end
  table.sort(ks)
  local m = tostring(w.code_err[ks[1]])
  if not m:find(ks[1], 1, true) then m = ks[1] .. ': ' .. m end
  if #ks > 1 then m = m .. '  (+' .. (#ks - 1) .. ' more)' end
  return (m:gsub('[\r\n\t]+', ' '))
end
-- --headless (replay.c, no window): the world played for `ticks` ticks of
-- 1/60 s, as Play would, for scripts and CI. keys: { "space@30", "w@10-90" }
-- (pressed at that tick, released the next; a range: held), evals: Lua
-- lines run on the world at their tick, as the console would ("assert(...)
-- @600": a failed assert fails the run). Prints each eval and a summary.
-- online: { host = port, via = "room@intro" } or { join = "addr:port" or
-- "room@intro" } (players.lua): played online, at the real pace (a tick every
-- 1/60 s), leaving at the end; introducer = port: one here too (nat.lua).
-- -> exit code: 0 ok, 1 an error (a tick, an eval, broken code)
function viewer_headless(w, ticks, keys, evals, online)
  local dt, fails = 1 / 60, 0
  if online and online.introducer and viewer_introducer then
    local ok, err = viewer_introducer(online.introducer)
    if not ok then print('introducer: ' .. tostring(err)); return 1 end
  end
  if online and (online.host or online.join) then  -- (online: ticks at the real pace, the network ticks too)
    viewer_online_set(true, online.host and 'host' or 'join', online.host or online.join, online.via)   -- (the power button on)
  end
  local ok, err = viewer_online_begin(w)           -- (Play: online if the switch is on)
  if not ok then print('online: ' .. tostring(err)); return 1 end
  local pace = online and (online.host or online.join or online.introducer) and udp and udp.clock
  local pace0 = pace and udp.clock()
  local function at(s) local body, a, b = s:match('^(.*)@(%d+)%-?(%d*)$'); return body, tonumber(a), tonumber(b) end
  viewer_session_start(w)
  local t0 = os.clock()
  for t = 1, ticks do
    for _, k in ipairs(keys or {}) do
      local key, a, b = at(k)
      if key and a == t then viewer_key(w, key:lower(), true, 1) end
      if key and (b or a + 1) == t then viewer_key(w, key:lower(), false, 1) end
    end
    for _, e in ipairs(evals or {}) do
      local code, a = at(e)
      if code and a == t then
        local ok, out = viewer_eval(w, code, '')
        print(string.format('[%d] > %s\n[%d] %s %s', t, code, t, ok and '=' or '!', tostring(out)))
        if not ok then fails = fails + 1 end
      end
    end
    local ok, err = pcall(viewer_tick, w, dt, t * dt)
    if not ok then print(string.format('[%d] tick: %s', t, tostring(err))); fails = fails + 1; break end
    if not pace and udp and udp.clock and viewer_net_busy and viewer_net_busy() then   -- (gone online from an eval, a lobby scan: the real pace from now)
      pace, pace0 = true, udp.clock() - t * dt
    end
    if pace then
      if viewer_introducer_tick then viewer_introducer_tick(dt) end
      ok, err = pcall(viewer_players_tick, dt)
      if not ok then print(string.format('[%d] network: %s', t, tostring(err))); fails = fails + 1; break end
      local wait = (pace0 or 0) + t * dt - udp.clock()
      if wait > 0 then udp.sleep(wait) end
    end
  end
  if online and online.join and not (viewer_online_player and viewer_online_player()) then
    print('online: never joined ' .. tostring(online.join)); fails = fails + 1
  end
  if pace and viewer_online_drop then viewer_online_drop() end
  if online and online.introducer and viewer_introducer then viewer_introducer(false) end
  if viewer_release_ports then viewer_release_ports(1) end
  local code_err = viewer_code(w)
  if code_err then print('code: ' .. code_err); fails = fails + 1 end
  local n = 0
  for _ in pairs(w.nodes) do n = n + 1 end
  print(string.format('headless: %d ticks (%.1f s of game), %d nodes, %s in %.2f s', ticks, ticks * dt, n,
    fails == 0 and 'ok' or (fails .. ' failed'), os.clock() - t0))
  return fails == 0 and 0 or 1
end
-- the game's mouse and pads, every frame (replay.c: game_input): w.mouse =
-- { x, y (world units), inside (over the game area), left, middle, right
-- (held: pressed on the game while it plays, for a world that asks:
-- /config window = { mouse = true }) }, w.pads = { { lx, ly, rx, ry (-1..1),
-- lt, rt (0..1) }, ... } (pad 1 first). -> wants the mouse, hide the cursor
function viewer_input(w, x, y, inside, left, middle, right, pads)
  local m = w.mouse or {}
  m.x, m.y, m.inside, m.left, m.middle, m.right = x, y, inside, left, middle, right
  w.mouse, w.pads = m, pads
  local cfg = w.node and w:node('/config')
  local win = cfg and type(cfg.c.window) == 'table' and cfg.c.window
  return win and win.mouse == true or false, win and win.cursor == false or false
end
-- keys for the game: w.on_key(w, key, down) and code leaves' on_key
function viewer_key(w, key, down, player)
  if w.key then return w:key(key, down, player) end
  if type(w.on_key) ~= 'function' then return false end
  w.on_key(w, key, down, player)
  return true
end
-- Play / Stop (like a play-in-editor): Play remembers the authored world
-- (and the disk state); Stop restores it, plus whatever changed on disk
-- meanwhile (e.g. a system edited while playing). Edits made while
-- playing are dropped by Stop; edits made while stopped can be saved.
local viewer_authored, viewer_play_disk
-- Play / Rewind: the world's code systems are built again on the next frame
-- (their setup runs again: fresh, and a breakpoint there stops)
function viewer_rebuild_systems(w)
  if viewer_boot_arm and not viewer_disk then viewer_boot_arm(viewer_file) end  -- (the probe: the main script's top level runs again, to stop in)
  for _, s in pairs(w.systems or {}) do if s.code then s.src = nil end end
  w._modules = nil                                 -- (and the modules they require: their top level runs again too)
  w._code_dirty = true                             -- (on the next frame)
end
local session_mark  -- (the undo stack's height when Play started: Stop drops what was done while playing)
function viewer_session_start(w)
  session_mark = #viewer_history
  viewer_rebuild_systems(w)
  local ok, b = w:save('/**', true)  -- (no /entities: Stop clears it)
  viewer_authored = ok and b or nil
  viewer_play_disk = viewer_last_disk
end
function viewer_session_stop(w)
  for i = #viewer_history, (session_mark or #viewer_history) + 1, -1 do   -- (edits made while playing: gone with them)
    if viewer_history[i].mem then table.remove(viewer_history, i) end
  end
  session_mark = nil
  if viewer_authored then assert(w:load(viewer_authored, '/')) end
  if viewer_disk and viewer_play_disk and viewer_last_disk ~= viewer_play_disk then
    local ok, patch = ecs.diff(viewer_play_disk, viewer_last_disk)
    if ok then assert(w:load(patch, '/')) end
  end
  viewer_authored = nil
end
-- what Save can do: 'folder' (world folder), 'blob' (a save() file), nil (script)
local viewer_file_blob
function viewer_savable()
  if viewer_disk then return 'folder' end
  if viewer_file_blob then return 'blob' end
  if viewer_script_base then return 'overrides' end
  return nil
end
function viewer_dirty(w)  -- world differs from what is on disk? (/entities: never)
  local ok, b = w:save('/**', true)
  if not ok then return false end
  if viewer_disk then return b ~= viewer_last_disk end
  if viewer_file_blob then return b ~= viewer_file_blob end
  if viewer_script_disk then return b ~= viewer_script_disk end
  return false
end
-- per selection (props panel Save / Undo): compare, revert or write just
-- the selected nodes against what is on disk
local disk_cache_blob, disk_cache_world
local function disk_world()  -- the on-disk world (cached)
  local b = viewer_disk and viewer_last_disk or viewer_file_blob or viewer_script_disk
  if not b then return nil end
  if b ~= disk_cache_blob then
    local ok, dw = ecs.load(b, '/')
    disk_cache_blob, disk_cache_world = b, ok and dw or nil
  end
  return disk_cache_world
end
-- Undo's reference: while playing, the world as it was when Play was
-- pressed (what Stop restores); while stopped, the world on disk
local auth_cache_blob, auth_cache_world
local function base_world()
  if viewer_authored then
    if viewer_authored ~= auth_cache_blob then
      local ok, aw = ecs.load(viewer_authored, '/')
      auth_cache_blob, auth_cache_world = viewer_authored, ok and aw or nil
    end
    return auth_cache_world
  end
  return disk_world()
end
-- a class selected (/classes/<name>): its nodes come along (Save, Undo,
-- what's changed): an edit of the class upgrades them (w:upgrade_class)
local function with_users(w, paths)
  local out, seen = {}, {}
  for _, p in ipairs(paths) do
    if not seen[p] then seen[p] = true; out[#out + 1] = p end
    local name = p:match('^/classes/([^/]+)$')
    if name then
      local users = {}
      for q, n in pairs(w.nodes) do
        if n.c[name] ~= nil and q:sub(1, 9) ~= '/classes/' and not seen[q] then users[#users + 1] = q end
      end
      table.sort(users)
      for _, q in ipairs(users) do seen[q] = true; out[#out + 1] = q end
    end
  end
  return out
end
-- /plugins: the editor's plugins, a folder each in plugins/ (next to games/,
-- viewer_plugins_dir). /plugins/<name> holds that folder's data leaves (the
-- files it opens, its config...) as components; its code (editor.lua: it
-- runs in lite) stays on disk. Never saved with the world (ecs: unsaved);
-- Save writes a plugin's components back to its folder (a leaf only when its
-- value changed), Undo reads them again.
local function plugin_dir(path)  -- '/plugins/x' -> its folder, its name (nil: not a plugin node)
  local name = path:match('^/plugins/([^/]+)$')
  if not name or not viewer_plugins_dir then return nil end
  return require('fs').join(viewer_plugins_dir, name), name
end
local plugin_leaves = {}  -- file -> { mtime, size, v }: read again only when it changed
local function plugin_read(dir)  -- its data leaves -> { comp = value } (code leaves: left out)
  local fs, out = require('fs'), {}
  for _, e in ipairs(fs.list(dir)) do
    local stem = not e.dir and e.name:match('^([^%.].*)%.lua$')
    if stem then
      local file = fs.join(dir, e.name)
      local c = plugin_leaves[file]
      if not (c and e.mtime and c.mtime == e.mtime and c.size == e.size) then
        local src = fs.read(file)
        local v, err = nil, nil
        if src then v, err = ecs.decode(src, e.name) end
        if v ~= nil and (err or not pcall(ecs.serialize, v)) then v = nil end
        c = { mtime = e.mtime, size = e.size, v = v }
        if e.mtime then plugin_leaves[file] = c end
      end
      if c.v ~= nil then out[stem] = ecs.copy(c.v) end
    end
  end
  return out
end
function viewer_mount_plugins(w)  -- once per world: a node per folder of plugins/
  if w._plugins_mounted or not viewer_plugins_dir or not w:layout() then return end
  w._plugins_mounted = true
  local fs = require('fs')
  for _, e in ipairs(fs.list(viewer_plugins_dir)) do
    if e.dir and e.name:sub(1, 1) ~= '.' and not w.nodes['/plugins/' .. e.name] then
      w:spawn('/plugins/' .. e.name, plugin_read(fs.join(viewer_plugins_dir, e.name)))
    end
  end
end
-- /assets: a folder world's assets/ folder. Its files that a plugin opens
-- (plugins/<name>/files.lua) show as nodes /assets/<folders>/<file.ext>
-- (ecs.is_file: never saved, the file is the data); its folders are the
-- world's nodes already. Read again every 2 seconds (files added, gone).
-- A plugin's templates/<kind>.<ext> files: what "+ <kind>" makes.
viewer_asset_files, viewer_asset_exts, viewer_asset_templates = {}, {}, {}
viewer_asset_thumbs = {}  -- ext -> how the tree previews it (its plugin's config.lua: thumbnails = "image")
-- a file name's extension as a plugin took it (exts: ext -> plugin): a
-- two-part one first ("ui.atlas.lua" -> "atlas.lua"), else its last ("png")
function viewer_asset_ext(name, exts)
  local e2 = name:match('[^/]%.([^%./]+%.[^%./]+)$')
  if e2 and (exts or viewer_asset_exts)[e2:lower()] then return e2:lower() end
  return (name:match('%.([^%./]+)$') or ''):lower()
end
local function asset_plugins()  -- (name, folder) of each plugin with code
  local fs, out = require('fs'), {}
  if not viewer_plugins_dir then return out end
  for _, e in ipairs(fs.list(viewer_plugins_dir)) do
    local dir = fs.join(viewer_plugins_dir, e.name)
    if e.dir and e.name:sub(1, 1) ~= '.' then
      local code = false                           -- (it has an editor.lua: listed, not read)
      for _, f in ipairs(fs.list(dir)) do if f.name == 'editor.lua' and not f.dir then code = true end end
      if code then out[#out + 1] = { e.name, dir } end
    end
  end
  return out
end
local asset_scan_t, asset_scan_w = -1, nil
function viewer_mount_assets(w, force)
  if not viewer_disk or not w:layout() then return end
  local now = os.time()
  if not force and asset_scan_w == w and now - asset_scan_t < 2 then return end
  asset_scan_t, asset_scan_w = now, w
  local fs, disk = require('fs'), require('disk')
  local exts, templates = {}, {}
  local thumbs = {}
  for _, pl in ipairs(asset_plugins()) do
    local data = plugin_read(pl[2])
    local files, kind = data.files, type(data.config) == 'table' and data.config.thumbnails
    if type(files) == 'table' then
      for _, x in ipairs(files) do
        if type(x) == 'string' then
          local ext = x:lower():gsub('^%.', '')
          exts[ext] = pl[1]
          if kind == 'image' then thumbs[ext] = kind end  -- (the only kind yet: the file is a picture)
        end
      end
    end
    for _, e in ipairs(fs.list(fs.join(pl[2], 'templates'))) do
      local kind, ext = e.name:match('^([^%.]+)%.([^%.]+%.?[^%.]*)$')  -- (kind.ext, kind.a.b: a two-part one)
      if kind and not e.dir then templates[#templates + 1] = { kind = kind, ext = ext, plugin = pl[1], file = fs.join(pl[2], 'templates', e.name) } end
    end
  end
  exts.lua = nil  -- (.lua there: the world's own leaves)
  table.sort(templates, function(a, b) return #a.kind < #b.kind or (#a.kind == #b.kind and a.kind < b.kind) end)
  viewer_asset_exts, viewer_asset_templates, viewer_asset_thumbs = exts, templates, thumbs
  local dir = viewer_disk:dir('/assets')
  if not w:node('/assets') and fs.mkdir(dir) then  -- (a game folder gets its assets/: where they go)
    w:spawn('/assets', {})
    local ok, b = viewer_disk:read('/**')
    if ok then viewer_last_disk = b end
  end
  local seen = {}
  local function walk(d, p)
    for _, e in ipairs(fs.list(d)) do
      if e.dir then
        local name = disk.decode(e.name)
        if disk.encode(name) == e.name and not name:find('.', 1, true) then walk(fs.join(d, e.name), p .. '/' .. name) end
      else
        if e.name:sub(1, 1) ~= '.' and exts[viewer_asset_ext(e.name, exts)] then seen[p .. '/' .. e.name] = fs.join(d, e.name) end
      end
    end
  end
  walk(dir, '/assets')
  local ddir = viewer_disk:dir('/docs')  -- documents: docs/**/*.md (*.txt), files like assets
  if not w:node('/docs') and fs.mkdir(ddir) then  -- (a game folder gets its docs/: where they go)
    w:spawn('/docs', {})
    local ok, b = viewer_disk:read('/**')
    if ok then viewer_last_disk = b end
  end
  local function walk_docs(d, p)
    for _, e in ipairs(fs.list(d)) do
      if e.dir then
        local name = disk.decode(e.name)
        if disk.encode(name) == e.name and not name:find('.', 1, true) then walk_docs(fs.join(d, e.name), p .. '/' .. name) end
      elseif e.name:match('^[^%.].*%.[Mm][Dd]$') or e.name:match('^[^%.].*%.[Tt][Xx][Tt]$') then
        seen[p .. '/' .. e.name] = fs.join(d, e.name)
      end
    end
  end
  walk_docs(ddir, '/docs')
  local sdir = viewer_disk:dir('/saves')  -- savegames: saves/*.sav (w:savegame), files like assets
  if fs.isdir(sdir) then
    if not w:node('/saves') then
      w:spawn('/saves', {})
      local ok, b = viewer_disk:read('/**')
      if ok then viewer_last_disk = b end
    end
    for _, e in ipairs(fs.list(sdir)) do
      if not e.dir and e.name:match('^[%w_%-]+%.sav$') then seen['/saves/' .. e.name] = fs.join(sdir, e.name) end
    end
  end
  for path in pairs(seen) do if not w.nodes[path] then w:spawn(path, {}) end end
  for path in pairs(viewer_asset_files) do
    if not seen[path] and w.nodes[path] and ecs.is_file(path) then w:remove(path) end  -- (gone from disk)
  end
  viewer_asset_files = seen
end
-- Undo: what the tree did (its menu: New, Rename, Duplicate, Delete), last
-- first: the tree's menu "Undo ...", or CTRL+Z with the mouse over the tree.
-- viewer_history: a stack, each level { what = "delete /assets/rocks", steps }:
--   { 'moved', from, to }    files moved (an asset deleted: into the trash)
--   { 'nodes', list }        world nodes removed ({ path, c } each, parents first)
--   { 'order', list }        /systems' run order as it was
--   { 'made', path }         a node made (undo: deleted; its files to .trash/<day>/undone)
--   { 'renamed', from, to }  undo: renamed back
-- A folder game keeps the stack on disk: level n is .trash/<day>/<n>/ (n: its
-- place in the stack), with an undo.lua (its steps) and the files it moved.
-- The top of the stack is the highest n; an undo empties and removes it. The
-- game's next load reads them back: undo works in a later session too.
viewer_history = {}
local undo_rec, undoing = nil, false  -- (the level being recorded; an undo's own changes: not recorded)
local function trash_dir(name)  -- .trash/<today>/<name>, made
  local fs = require('fs')
  local day = fs.join(viewer_disk.root, '.trash', os.date('%Y-%m-%d'))
  fs.mkdir(fs.join(viewer_disk.root, '.trash'))
  fs.mkdir(day)
  local d = fs.join(day, name)
  fs.mkdir(d)
  return d
end
local function level_dir(r)  -- its folder: .trash/<today>/<its level> (taken: the next free one)
  if not r.dir then
    local fs, n = require('fs'), r.level
    while fs.read(fs.join(viewer_disk.root, '.trash', os.date('%Y-%m-%d'), tostring(n), 'undo.lua')) do n = n + 1 end
    r.dir = trash_dir(tostring(n))
  end
  return r.dir
end
local function rel(abs) return abs:sub(#viewer_disk.root + 2) end  -- (undo.lua: paths in the game's folder)
local function history_begin(what) if not undoing then undo_rec = { what = what, steps = {}, level = #viewer_history + 1 } end end
local function history_step(step) if undo_rec then undo_rec.steps[#undo_rec.steps + 1] = step end end
local function history_end()
  local r = undo_rec
  undo_rec = nil
  if not r or #r.steps == 0 then return end
  viewer_history[#viewer_history + 1] = r
  if not viewer_disk then return end  -- (a script world: this session only)
  local steps = {}
  for _, st in ipairs(r.steps) do
    if st[1] == 'moved' then steps[#steps + 1] = { 'moved', rel(st[2]), rel(st[3]) }
    elseif ecs.encode(st) then steps[#steps + 1] = st end  -- (nodes that aren't data: this session only)
  end
  local fs = require('fs')
  fs.write(fs.join(level_dir(r), 'undo.lua'), ecs.encode({ what = r.what, steps = steps }))
end
local function history_made(what, path) history_begin(what); history_step({ 'made', path }); history_end() end
function viewer_history_load()  -- the stack a session before left: .trash/<day>/<n>/undo.lua, in order
  viewer_history = {}
  if not viewer_disk then return end
  local fs = require('fs')
  local root = fs.join(viewer_disk.root, '.trash')
  local days = {}
  for _, e in ipairs(fs.list(root)) do if e.dir and e.name:match('^%d%d%d%d%-%d%d%-%d%d$') then days[#days + 1] = e.name end end
  table.sort(days)
  for _, day in ipairs(days) do
    local ns = {}
    for _, e in ipairs(fs.list(fs.join(root, day))) do if e.dir and tonumber(e.name) then ns[#ns + 1] = tonumber(e.name) end end
    table.sort(ns)
    for _, n in ipairs(ns) do
      local dir = fs.join(root, day, tostring(n))
      local m = ecs.decode(fs.read(fs.join(dir, 'undo.lua')) or '', 'undo.lua')
      if type(m) == 'table' and type(m.steps) == 'table' then
        local r = { what = tostring(m.what or (day .. '/' .. n)), steps = {}, dir = dir, level = #viewer_history + 1 }
        for _, st in ipairs(m.steps) do
          if type(st) == 'table' and st[1] == 'moved' and type(st[2]) == 'string' and type(st[3]) == 'string' then
            r.steps[#r.steps + 1] = { 'moved', fs.join(viewer_disk.root, st[2]), fs.join(viewer_disk.root, st[3]) }
          elseif type(st) == 'table' and type(st[1]) == 'string' then r.steps[#r.steps + 1] = st end
        end
        viewer_history[#viewer_history + 1] = r
      end
    end
  end
end
-- A clean quit (replay.c, after its main loop) forgets the stack: each level's
-- undo.lua goes; a level that kept files (deleted assets) is renamed
-- .trash/<day>/deleted-<hhmmss>-<n> (out of the stack, there until .trash is
-- wiped), an empty one goes. A crash skips this: the next load offers the
-- undo levels again.
function viewer_history_forget()
  viewer_history = {}
  if not viewer_disk then return end
  local fs = require('fs')
  local root = fs.join(viewer_disk.root, '.trash')
  for _, d in ipairs(fs.list(root)) do
    if d.dir and d.name:match('^%d%d%d%d%-%d%d%-%d%d$') then
      local day = fs.join(root, d.name)
      for _, e in ipairs(fs.list(day)) do
        local dir = fs.join(day, e.name)
        if e.dir and tonumber(e.name) and fs.read(fs.join(dir, 'undo.lua')) then
          fs.rmfile(fs.join(dir, 'undo.lua'))
          if #fs.list(dir) == 0 then fs.rmdir(dir)
          else fs.rename(dir, fs.join(day, 'deleted-' .. os.date('%H%M%S') .. '-' .. e.name)) end
        end
      end
      if #fs.list(day) == 0 then fs.rmdir(day) end
    end
  end
  if #fs.list(root) == 0 then fs.rmdir(root) end
end
local function asset_new_folder(w, parent, text)  -- + folder: on disk and in the tree
  local name = tostring(text):match('^%s*([%w_%-]+)%s*$')
  if not name then return false, 'a name: letters, digits, _ and -' end
  local path = parent .. '/' .. name
  if w:node(path) then return false, path .. ' is already there' end
  local fs, dir = require('fs'), viewer_disk:dir(path)
  if not fs.mkdir(dir) then return false, "can't make " .. dir end
  w:spawn(path, {})
  local ok, b = viewer_disk:read('/**')  -- (it's on disk now: not an unsaved change)
  if ok then viewer_last_disk = b end
  viewer_select, viewer_note = path, path .. ': a new folder (' .. dir .. ')'
  history_made('new ' .. path, path)
  return true
end
local function asset_new(w, parent, template, text)  -- + <kind>: its plugin's template, copied, opened
  local name = tostring(text):match('^%s*([%w_%-]+)')
  if not name then return false, 'a name: letters, digits, _ and -' end
  local fs = require('fs')
  local ext = template:match('([^/\\]*)$'):match('^[^%.]*%.(.+)$')  -- (its kind.<ext>: "atlas.lua" too)
  local dir = viewer_disk:dir(parent)
  fs.mkdir(dir)
  local file = fs.join(dir, name .. '.' .. ext)
  if fs.read(file) then return false, file .. ' is already there' end
  local src = fs.read(template)
  if not src then return false, "can't read " .. template end
  local ok, err = fs.write(file, src)
  if not ok then return false, tostring(err) end
  viewer_mount_assets(w, true)
  local path = parent .. '/' .. name .. '.' .. ext
  viewer_select, viewer_open, viewer_note = path, file, path .. ': new (' .. file .. ')'
  history_made('new ' .. path, path)
  return true
end
local function doc_new(w, parent, text)  -- + document: <name>.md in that folder of docs/, a title in it, opened
  local name = tostring(text):match('^%s*([%w_%-]+)')
  if not name then return false, 'a name: letters, digits, _ and -' end
  local fs = require('fs')
  local dir = viewer_disk:dir(parent)
  fs.mkdir(dir)
  local file = fs.join(dir, name .. '.md')
  if fs.read(file) then return false, file .. ' is already there' end
  local ok, err = fs.write(file, '# ' .. name:gsub('[_%-]+', ' ') .. '\n\n')
  if not ok then return false, tostring(err) end
  viewer_mount_assets(w, true)
  local path = parent .. '/' .. name .. '.md'
  viewer_select, viewer_open, viewer_note = path, file, path .. ': new (' .. file .. ')'
  history_made('new ' .. path, path)
  return true
end
local function plugin_dirty(w, p)
  local dir = plugin_dir(p)
  local n = w.nodes[p]
  if not dir or not n then return false end
  local disk = plugin_read(dir)
  for k, v in pairs(n.c) do
    if disk[k] == nil or ecs.serialize(disk[k]) ~= ecs.serialize(v) then return true end
  end
  for k in pairs(disk) do if n.c[k] == nil then return true end end
  return false
end
local function plugin_save(w, p)  -- -> ok, err
  local dir = plugin_dir(p)
  local n = w.nodes[p]
  if not dir or not n then return true end
  local fs = require('fs')
  local disk = plugin_read(dir)
  for k, v in pairs(n.c) do
    if disk[k] == nil or ecs.serialize(disk[k]) ~= ecs.serialize(v) then
      local src, err = ecs.pretty(v)
      if not src then return false, p .. '.' .. k .. ': ' .. tostring(err) end
      local ok, werr = fs.write(fs.join(dir, k .. '.lua'), 'return ' .. src .. '\n')
      if not ok then return false, werr end
    end
  end
  for k in pairs(disk) do  -- a component removed: its leaf goes
    if n.c[k] == nil then fs.rmfile(fs.join(dir, k .. '.lua')) end
  end
  return true
end
local function plugin_undo(w, p)
  local dir = plugin_dir(p)
  local n = w.nodes[p]
  if not dir or not n then return end
  local disk = plugin_read(dir)
  for k in pairs(n.c) do n.c[k] = nil end
  for k, v in pairs(disk) do n.c[k] = v end
end
local function plugin_paths(paths)  -- -> the plugin nodes, the rest
  local pl, rest = {}, {}
  for _, p in ipairs(paths) do
    if plugin_dir(p) then pl[#pl + 1] = p elseif not ecs.is_plugin(p) then rest[#rest + 1] = p end
  end
  return pl, rest
end
function viewer_sel_dirty(w, paths)
  local pl
  pl, paths = plugin_paths(paths)  -- (a plugin: against its folder)
  for _, p in ipairs(pl) do if plugin_dirty(w, p) then return true end end
  local dw = base_world()
  if not dw then return false end
  paths = with_users(w, paths)
  for _, p in ipairs(paths) do
    if select(2, w:save(p)) ~= select(2, dw:save(p)) then return true end
  end
  return false
end
function viewer_sel_undo(w, paths)  -- back to the base (a node not there goes away)
  local pl
  pl, paths = plugin_paths(paths)
  for _, p in ipairs(pl) do plugin_undo(w, p) end
  if #paths == 0 then return true end
  local dw = base_world()
  if not dw then return false, 'nothing on disk' end
  paths = with_users(w, paths)
  for _, p in ipairs(paths) do
    local ok, b = dw:save(p)
    if ok then assert(w:load(b, '/')) end
  end
  return true
end
function viewer_sel_save(w, paths)  -- -> ok, err
  local pl
  pl, paths = plugin_paths(paths)  -- (a plugin: to its folder)
  for _, p in ipairs(pl) do
    local ok, err = plugin_save(w, p)
    if not ok then return false, err end
  end
  if #paths == 0 then return true end
  paths = with_users(w, paths)
  if viewer_disk then
    for _, p in ipairs(paths) do
      local ok, err = viewer_disk:flush(w, p)
      if not ok then return false, err end
    end
    local ok2, blob = viewer_disk:read('/**')
    if not ok2 then return false, blob end
    viewer_last_disk = blob
    return true
  end
  if viewer_file_blob then
    local ok, t = ecs.load(viewer_file_blob, '/')
    if not ok then return false, t end
    for _, p in ipairs(paths) do assert(t:load(select(2, w:save(p)), '/')) end
    local ok2, blob = t:save('/**', true)
    local f, err = io.open(viewer_file, 'wb')
    if not f then return false, err end
    f:write(blob); f:close()
    viewer_file_blob = blob
    return true
  end
  if viewer_script_base then  -- overrides: on-disk world + the selection
    local ok, t = ecs.load(viewer_script_disk, '/')
    if not ok then return false, t end
    for _, p in ipairs(paths) do assert(t:load(select(2, w:save(p)), '/')) end
    return write_overrides(t)
  end
  return false, 'nothing to save to'
end
function viewer_save(w)  -- -> ok, err
  if viewer_disk then
    local ok, err = viewer_disk:flush(w, '/**')
    if not ok then return false, err end
    local ok2, blob = viewer_disk:read('/**')
    if not ok2 then return false, blob end
    viewer_last_disk = blob
    return true
  end
  if viewer_file_blob then
    local ok, blob = w:save('/**', true)
    if not ok then return false, blob end
    local f, err = io.open(viewer_file, 'wb')
    if not f then return false, err end
    f:write(blob); f:close()
    viewer_file_blob = blob
    return true
  end
  if viewer_script_base then return write_overrides(w) end
  return false, 'nothing to save to'
end
-- folder worlds: re-read, and apply only what changed on disk since the
-- last read (a diff), so saving one file (e.g. a system) patches just
-- that node: the rest of the live state, and the timeline, keep going
function viewer_poll(w)
  if not viewer_disk then return true end
  local stamp = viewer_disk.stamp and viewer_disk:stamp('/**')   -- (no file changed: nothing to read)
  if stamp and stamp == viewer_last_stamp and viewer_last_disk then return true end
  viewer_last_stamp = stamp
  local ok, blob = viewer_disk:read('/**')
  if not ok then error(blob, 0) end
  if blob == viewer_last_disk then return true end
  local ok1, patch = ecs.diff(viewer_last_disk, blob)
  if not ok1 then error(patch, 0) end
  local classes, before = w:node('/classes'), {}  -- (a class edited on disk: its nodes follow)
  for name, c in pairs(classes and classes.children or {}) do before[name] = ecs.copy(c.c) end
  local ok2, err = w:load(patch, '/')
  if not ok2 then error(err, 0) end
  local k = 0
  for name, b in pairs(before) do k = k + w:upgrade_class(name, b) end
  if k > 0 then viewer_note = string.format('a class changed on disk: %d value%s upgraded in its nodes (not their own)', k, k > 1 and 's' or '') end
  if viewer_players_patch then viewer_players_patch(patch) end  -- (the other players have the same files)
  viewer_last_disk = blob
  return true
end
-- timeline: world snapshots every 0.5 s of game time, seek with blending
-- each snapshot also keeps the fps measured since the previous one
-- (viewer_fps, set by C before recording): the timeline draws it
local hist, HIST_MAX, hist_ver = {}, 7200, 0  -- 7200 = 1 hour at 2/s
viewer_fps = 0
function viewer_hist_reset(w)
  hist, hist_ver = {}, hist_ver + 1
  local ok, b = w:save('/**')
  if ok then hist[1] = { t = 0, blob = b, frame = 0 } end  -- epoch: no fps yet
end
function viewer_hist_record(w, t)  -- -> true if a snapshot was taken
  local last = hist[#hist]
  if last and t - last.t < 0.5 then return false end
  local ok, b = w:save('/**')
  if not ok then return false end
  hist[#hist + 1] = { t = t, blob = b, fps = viewer_fps, frame = viewer_gframe }
  if #hist > HIST_MAX then table.remove(hist, 2) end  -- keep the epoch
  hist_ver = hist_ver + 1
  return true
end
function viewer_hist_truncate(w, t)  -- resume after a seek: new future
  while #hist > 1 and hist[#hist].t > t do hist[#hist] = nil end
  local last = hist[#hist]
  if last and last.t < t then
    local ok, b = w:save('/**')
    if ok then hist[#hist + 1] = { t = t, blob = b, frame = viewer_gframe } end  -- blended state: no fps
  end
  hist_ver = hist_ver + 1
end
function viewer_hist_series(ver)  -- -> ver [, times, fps] if changed
  if ver == hist_ver then return hist_ver end
  local ts, fs = {}, {}
  for i, h in ipairs(hist) do ts[i] = h.t; fs[i] = h.fps or 0 end
  return hist_ver, ts, fs
end
local function lerp(a, b, k)  -- numbers blend, tables recurse
  local ta, tb = type(a), type(b)
  if ta == 'number' and tb == 'number' then return a + (b - a) * k end
  if ta == 'table' and tb == 'table' then
    local o = {}
    for key, v in pairs(a) do o[key] = lerp(v, b[key], k) end
    return o
  end
  return a  -- text, flags: switch at b
end
function viewer_hist_seek(w, t)  -- -> the time actually shown, its frame
  if #hist == 0 then return 0, 0 end
  if t < hist[1].t then t = hist[1].t end
  if t > hist[#hist].t then t = hist[#hist].t end
  local lo, hi = 1, #hist  -- last snapshot at or before t
  while lo < hi do
    local mid = math.floor((lo + hi + 1) / 2)
    if hist[mid].t <= t then lo = mid else hi = mid - 1 end
  end
  local a, b = hist[lo], hist[lo + 1]
  local blob = a.blob
  local frame = a.frame or 0
  if b and t > a.t then
    local k = (t - a.t) / (b.t - a.t)
    frame = math.floor((a.frame or 0) + ((b.frame or 0) - (a.frame or 0)) * k + 0.5)
    local da, db = ecs.decode(a.blob), ecs.decode(b.blob)
    for path, comps in pairs(da.nodes) do
      local cb = db.nodes[path]
      if cb then da.nodes[path] = lerp(comps, cb, k) end
    end
    blob = assert(ecs.encode(da))
  end
  assert(w:load(blob, '/'))
  return t, frame
end
function viewer_hist_info()  -- -> snapshots, last time
  return #hist, hist[#hist] and hist[#hist].t or 0
end
-- tree tab: node names from line `first`, at most `max` of them. The root
-- row is '/'; its children are the first level. In a layout world every
-- root shows, in the layout's order, even when it isn't there (an empty
-- row). Per row, kinds: 'v' a missing root, 'c' under /classes (dimmed), 'x' not
-- saved (/entities, /tmp), '' the rest. shapes: how C draws its lines: one char
-- per level above it ('|' a line goes on down there, ' ' none), then its
-- own ('T' more siblings below, 'L' the last one), then '-' open, '+'
-- closed (not in viewer_unfolded) or ' ' (no children). The root's shape is ''.
-- reveal: open the selected node's ancestors.
viewer_unfolded = {}  -- open branches (this session only: the editor starts with all closed, but /)
local function tree_kind(path)
  if ecs.is_plugin(path) then return '' end  -- (saved: to its folder)
  if ecs.is_builtin(path) then return 'c' end
  if ecs.is_scratch(path) then return 'x' end
  if path == '/classes' or path:sub(1, 9) == '/classes/' then return 'c' end
  return ''
end
-- thumb (nil: none): { cw = a cell's width, span = its height in rows,
-- room = the width for cells at level 0, ind = a level's indent }, px. An
-- /assets folder's files its plugins preview (viewer_asset_thumbs) show last,
-- as a matrix: lines of cells, each line `span` rows of kind 'g' (shape
-- prefix .. own .. 'g'); grids[i] = "k\nkind\npath\npath...": row k of its
-- line, the preview's kind, its cells
local function thumb_kind(path)
  local f = viewer_asset_files[path]
  return f and viewer_asset_thumbs[viewer_asset_ext(path)]
end
-- the draw order's layers, bottom to top (render.h draw_layers): the ones
-- /data/layers' `order` lists, then the others used (a `layer` component),
-- by name; "default" (no layer) among the unlisted when not listed. None
-- set anywhere: {} (one pass, tree order)
function viewer_layers(w)
  local out, seen, extra = {}, {}, {}
  local L = w.node and w:node('/data/layers')
  for _, x in ipairs(L and type(L.c.order) == 'table' and L.c.order or {}) do
    if type(x) == 'string' and not seen[x] then seen[x] = true; out[#out + 1] = x end
  end
  for _, n in ipairs(w.query and w:query('layer') or {}) do
    local x = n.c.layer
    if type(x) == 'string' and not seen[x] then seen[x] = true; extra[#extra + 1] = x end
  end
  if #out == 0 and #extra == 0 then return out end
  if not seen.default then extra[#extra + 1] = 'default' end
  table.sort(extra)
  for _, x in ipairs(extra) do out[#out + 1] = x end
  return out
end
function viewer_outline(w, first, max, selected, reveal, filter, thumb)
  local out, count, paths, sel, kinds, shapes, grids = {}, 0, {}, 0, {}, {}, {}
  filter = type(filter) == 'string' and filter:lower() or ''  -- the filter box: only what matches, and what leads to it
  if reveal and selected ~= '' then
    local p = selected:match('^(.*)/[^/]*$')
    while p and p ~= '' do viewer_unfolded[p] = true; p = p:match('^(.*)/[^/]*$') end
  end
  local layout = w.layout and w:layout()
  if layout and w.builtins then w:builtins() end  -- (the built-in classes: /classes/int...)
  if layout then viewer_mount_plugins(w) end  -- (/plugins: plugins/<name>/ folders)
  if layout then viewer_mount_assets(w) end  -- (/assets: the assets/ folder's files)
  local function row(path, name, shape, kind)
    count = count + 1
    if path == selected then sel = count end
    if count >= first and #out < max then
      out[#out + 1], paths[#paths + 1], kinds[#kinds + 1], shapes[#shapes + 1] = name, path, kind, shape
    end
  end
  local function grid(cells, prefix, last, lv)  -- a line of thumbnails: span rows
    local kind = thumb_kind(cells[1]) or 'image'
    local cell = table.concat(cells, '\n')
    for k = 0, thumb.span - 1 do
      count = count + 1
      for _, c in ipairs(cells) do if c == selected and k == 0 then sel = count end end
      if count >= first and #out < max then
        out[#out + 1], paths[#paths + 1], kinds[#kinds + 1], shapes[#shapes + 1] = '', cells[1], 'g', prefix .. (last and 'L' or 'T') .. 'g'
        grids[#out] = k .. '\n' .. kind .. '\n' .. cell
      end
    end
  end
  local function items(n)  -- a node's rows below it: nodes, or a missing root's path
    local kids, list, seen = w:children(n), {}, {}
    if layout and n == w.root then
      for _, r in ipairs(ecs.ROOTS) do list[#list + 1] = w:node(r) or r; seen[r] = true end
    end
    for _, ch in ipairs(kids) do if not seen[ch.path] then list[#list + 1] = ch end end
    if n.path == '/classes' then  -- (your classes first, the built-in types after)
      local mine, built = {}, {}
      for _, ch in ipairs(list) do if ecs.is_builtin(ch.path) then built[#built + 1] = ch else mine[#mine + 1] = ch end end
      for _, ch in ipairs(built) do mine[#mine + 1] = ch end
      list = mine
    end
    local dirs, files = {}, {}  -- (on disk, in /assets, /docs, /saves...: folders first, then files, each by name)
    for _, ch in ipairs(list) do
      if type(ch) ~= 'string' and ecs.is_file(ch.path) then files[#files + 1] = ch else dirs[#dirs + 1] = ch end
    end
    if #files > 0 and #dirs > 0 then
      for _, ch in ipairs(files) do dirs[#dirs + 1] = ch end
      list = dirs
    end
    return list
  end
  local by_path, hit = filter:find('/', 1, true), {}
  local function shown(n)  -- filtering: its name (with a "/": its path) holds the text, or something below it does
    if filter == '' then return true end
    local path = type(n) == 'string' and n or n.path
    if hit[path] == nil then
      local text = by_path and path or (type(n) == 'string' and n:sub(2) or n.name)
      local m = text:lower():find(filter, 1, true) ~= nil
      if not m and type(n) ~= 'string' then
        for _, ch in ipairs(items(n)) do if shown(ch) then m = true break end end
      end
      hit[path] = m
    end
    return hit[path]
  end
  local function visible(list)  -- (the rows it shows of a list)
    if filter == '' then return list end
    local out2 = {}
    for _, ch in ipairs(list) do if shown(ch) then out2[#out2 + 1] = ch end end
    return out2
  end
  local function desc(n)  -- how many nodes below it (all levels; a missing root: none)
    if w._sorted and n._e then w:_sorted(); return n._e - n._i end   -- (the world's kept order: its subtree's size)
    local k = 0
    for _, ch in ipairs(items(n)) do if type(ch) ~= 'string' then k = k + 1 + desc(ch) end end
    return k
  end
  local function walk(n, depth, prefix, last)  -- depth 1: the root's children
    local own = last and 'L' or 'T'
    if type(n) == 'string' then  -- a missing root
      local name = n:sub(2) .. '/' .. (ecs.is_scratch(n) and not ecs.is_plugin(n) and '  (not saved)' or '')
      return row(n, name, prefix .. own .. ' ', 'v')
    end
    local all = items(n)
    local list = visible(all)
    local folded = not viewer_unfolded[n.path] and filter == ''  -- (filtering: every match shows, folded or not)
    local fold = #list == 0 and ' ' or (folded and '+' or '-')
    local name = n.name
    local p = n.path
    local on_disk = p:sub(1, 8) == '/assets/' or p:sub(1, 6) == '/docs/' or p:sub(1, 7) == '/saves/'
    if #all > 0 or (layout and depth == 1) or (on_disk and not ecs.is_file(p)) then name = name .. '/' end   -- (a folder: docs/)
    if layout and depth == 1 and ecs.is_scratch(n.path) and not ecs.is_plugin(n.path) then name = name .. '  (not saved)' end
    if depth == 2 and ecs.is_builtin(n.path) then name = name .. '  (built in)' end
    if #all > 0 then name = name .. '\t(' .. desc(n) .. ')' end  -- (what it holds: after a tab, drawn dim)
    row(n.path, name, prefix .. own .. fold, tree_kind(n.path))
    if folded then return end
    local below = prefix .. (last and ' ' or '|')
    local cells = {}
    if thumb and (n.path == '/assets' or n.path:sub(1, 8) == '/assets/') then  -- (its previewed files: a matrix, last)
      local rest = {}
      for _, ch in ipairs(list) do
        if type(ch) ~= 'string' and thumb_kind(ch.path) then cells[#cells + 1] = ch.path else rest[#rest + 1] = ch end
      end
      list = rest
    end
    for i, ch in ipairs(list) do walk(ch, depth + 1, below, i == #list and #cells == 0) end
    if #cells > 0 then
      local cols = math.max(1, math.floor((thumb.room - depth * thumb.ind) / thumb.cw))
      local lines = math.ceil(#cells / cols)
      for l = 1, lines do
        local line = {}
        for j = (l - 1) * cols + 1, math.min(#cells, l * cols) do line[#line + 1] = cells[j] end
        grid(line, below, l == lines, depth)
      end
    end
  end
  row('/', '/\t(' .. desc(w.root) .. ')', '', '')  -- the root: always open (its count: the whole tree)
  local top = visible(items(w.root))
  for i, ch in ipairs(top) do walk(ch, 1, '', i == #top) end
  return out, count, paths, sel, kinds, shapes, grids
end
-- a click on a row's '+' / '-' box: close / open it. -> true if it has one
function viewer_tree_fold(w, path)
  local n = w:node(path)
  if not n or n == w.root or not next(n.children) then return false end
  viewer_unfolded[path] = not viewer_unfolded[path] or nil
  return true
end
-- status-bar console: run a line of Lua against the live world.
-- Globals you set persist between lines; `w` = the world, `sel` = the
-- selected node, ls(pat) lists nodes, print() collects output.
local con_env = setmetatable({}, { __index = _G })
local function con_show(v)
  if type(v) == 'table' and v.path and v.c and v.children then  -- a node
    local ks = {}
    for k in pairs(v.c) do ks[#ks + 1] = tostring(k) end
    table.sort(ks)
    return v.path .. ' {' .. table.concat(ks, ', ') .. '}'
  end
  if type(v) == 'table' and #v > 0 and type(v[1]) == 'table' and v[1].path and v[1].c then
    local ps = {}  -- a node list
    for i, n in ipairs(v) do ps[i] = n.path end
    return #v .. ' nodes: ' .. table.concat(ps, '  ')
  end
  if type(v) == 'table' and v.root and v.nodes then return 'world (' .. tostring(v.frame or 0) .. ' ticks)' end
  if type(v) == 'string' then return string.format('%q', v) end
  if type(v) == 'table' then
    local s = ecs.encode(v)
    if s then return (s:gsub('^return ', '')) end
  end
  return tostring(v)
end
function viewer_eval(w, src, selected)  -- -> ok, text
  local out = {}
  con_env.w, con_env.ecs = w, ecs
  for k, f in pairs(viewer_console_cmds or {}) do con_env[k] = function(...) return f(w, ...) end end   -- (players.lua: host, join, leave, online)
  con_env.sel = selected ~= '' and w:node(selected) or nil
  con_env.print = function(...)
    local t = {}
    for i = 1, select('#', ...) do t[i] = tostring((select(i, ...))) end
    out[#out + 1] = table.concat(t, '  ')
  end
  con_env.ls = function(p)  -- ls() / ls('/scene') = children
    p = p or '/'
    if not p:find('[%*%?]') then p = (p:gsub('/$', '')) .. '/*' end
    return w:select(p)
  end
  local f, err = load('return ' .. src, '=console', 't', con_env)  -- expression?
  if not f then f, err = load(src, '=console', 't', con_env) end  -- statement
  if not f then return false, err end
  local r = table.pack(pcall(f))
  if not r[1] then return false, tostring(r[2]) end
  for i = 2, r.n do out[#out + 1] = con_show(r[i]) end
  if #out == 0 then out[1] = 'ok' end
  return true, (table.concat(out, '  |  '):gsub('[\r\n\t]+', ' '))
end
-- property editor: the selected nodes' components as flat rows.
-- Structure comes from the first node; with several selected, a row is
-- `mixed` when the others hold a different value there. Each row's id is
-- its key path, encoded ({ 'xform', 'x' }), for viewer_prop_set/add.
local function prop_get(n, keys)
  local v = n.c
  for _, k in ipairs(keys) do
    if type(v) ~= 'table' then return nil end
    v = v[k]
  end
  return v
end
local function prop_same(a, b)
  if a == b then return true end
  if type(a) ~= 'table' or type(b) ~= 'table' then return false end
  return ecs.encode(a) == ecs.encode(b)
end
local function prop_num(v)
  if v == math.floor(v) and math.abs(v) < 1e15 then return string.format('%d', v) end
  local s = string.format('%.4f', v):gsub('0+$', ''):gsub('%.$', '')
  return s
end
local function prop_keys(t)  -- array part first, then sorted keys
  local ks, n = {}, #t
  for i = 1, n do ks[i] = i end
  local rest = {}
  for k in pairs(t) do
    if not (type(k) == 'number' and k >= 1 and k <= n and k == math.floor(k)) then rest[#rest + 1] = k end
  end
  table.sort(rest, function(a, b) return tostring(a) < tostring(b) end)
  for _, k in ipairs(rest) do ks[#ks + 1] = k end
  return ks
end
-- script worlds: the world the script alone builds (to mark overrides)
local script_cache_blob, script_cache_world
function viewer_script_world()
  if not viewer_script_base then return nil end
  if viewer_script_base ~= script_cache_blob then
    local ok, sw = ecs.load(viewer_script_base, '/')
    script_cache_blob, script_cache_world = viewer_script_base, ok and sw or nil
  end
  return script_cache_world
end
-- Classes (the layout's /classes/<name>): what a `name` component starts
-- with. A class's components are its members, each described (ecs.member):
-- hp = { type = "int", value = 10, min = 1, max = 20 }
-- type: a class (bool int number string color: built in), container: none,
-- "array", "set" or "map" (keys: type, values: `values`), min / max, options.
-- A node's component that has a class shows the members it lacks too (cls
-- 'i': inherited, dim; setting one writes it into the node), marks those
-- that differ (cls 'd'; def: the class's value; RMB: back to it), and values
-- keep to their member's type (widgets: a slider for min..max, a drop-down
-- for options, a swatch for a colour). A class node shows its members: a row
-- each (its name: double-click renames, RMB: rename / remove; its type and
-- kind: drop-downs, a map's values in a sub-list), then its range (numbers)
-- or options (text), then its default (viewer_prop_pick).
local function class_of_path(path)  -- '/classes/<name>' (not a built-in) -> name
  local c = path:match('^/classes/([^/]+)$')
  if c and ecs.BUILTIN[c] == nil then return c end
end
local function class_node(w, n, comp)  -- n's component comp: its class node, if any
  if type(comp) ~= 'string' or ecs.BUILTIN[comp] ~= nil or n.path == '/classes' or n.path:sub(1, 9) == '/classes/' then return nil end
  return w.layout and w:layout() and w:node('/classes/' .. comp) or nil
end
local function member_of(w, cname, f)  -- class cname's member f: its description, or nil
  local c = w:node('/classes/' .. tostring(cname))
  local d = c and c.c[f]
  if d ~= nil then return ecs.member(d) end
end
local function is_class(w, t)  -- a class of yours (not a plain type)
  return type(t) == 'string' and ecs.BUILTIN[t] == nil and w:node('/classes/' .. t) ~= nil
end
local function element(d)  -- a collection's element: its type (a map's values: theirs alone)
  if d.container == 'map' then return { type = d.values or 'bool' } end
  return { type = d.type, min = d.min, max = d.max, options = d.options }
end
-- A node's own fields (an object's, a /data node's: not a class component)
-- can be typed too: its `meta` component describes them, like members:
-- meta = { velocity = { type = "vec3" }, target = { type = "node" } }
-- (the values stay plain: n.c.velocity.x). `meta` is a reserved name.
local RESERVED = { meta = true }
local function meta_of(n)  -- a node's meta (not a class's: its members describe themselves), or nil
  if n.path == '/classes' or n.path:sub(1, 9) == '/classes/' then return nil end
  local m = n.c.meta
  return type(m) == 'table' and m or nil
end
local function own_desc(n, f)  -- a node's own field f: its description (in its meta), or nil
  local m = meta_of(n)
  local d = m and m[f]
  if type(d) == 'table' and type(d.type) == 'string' then return d end
end
local function view_at(w, n, keys)  -- the type of what's at keys: a member's description, or an element's, or nil
  local d, i
  local cname = class_of_path(n.path)
  if cname then d, i = member_of(w, cname, keys[1]), 2
  elseif own_desc(n, keys[1]) then d, i = own_desc(n, keys[1]), 2
  elseif #keys >= 2 and class_node(w, n, keys[1]) then d, i = member_of(w, keys[1], keys[2]), 3
  else return nil end
  while d and i <= #keys do
    if d.container then d = element(d)
    elseif is_class(w, d.type) then d = member_of(w, d.type, keys[i])
    else return nil end
    i = i + 1
  end
  return d
end
local function store(n, keys)  -- where keys live: on a class, a member's value ({ f, ... } -> { f, 'value', ... })
  local d = class_of_path(n.path) and n.c[keys[1]]
  if type(d) ~= 'table' or type(d.type) ~= 'string' then return keys end
  local k = { keys[1], 'value' }
  for i = 2, #keys do k[#k + 1] = keys[i] end
  return k
end
local function get(n, keys) return prop_get(n, store(n, keys)) end
local function class_value(w, n, keys)  -- the class's value for { comp, field }, or nil
  if #keys ~= 2 then return nil end
  local c = class_node(w, n, keys[1])
  local d = c and c.c[keys[2]]
  if d ~= nil then return ecs.start_value(ecs.member(d)) end
end
-- The plain types (built in: ecs.BUILTIN). Numbers (int, number, angle in
-- degrees: a range), text (string; key, asset, node: picked from a list),
-- bool; vectors and the like (named numbers: vec2 { x, y }, vec3, vec4,
-- quat { x, y, z, w } kept normalized, rect { x, y, w, h }: one row,
-- typed "1, 2, 3"); colours (color3 / color4: { r, g, b [, a] }, 0..255, a
-- swatch; color: the old name, 3 or 4).
local PRIM = { int = 'number', number = 'number', angle = 'number', string = 'string', bool = 'boolean',
               key = 'string', asset = 'string', node = 'string' }
local NUMS = { int = true, number = true, angle = true }
local VEC = { vec2 = { 'x', 'y' }, vec3 = { 'x', 'y', 'z' }, vec4 = { 'x', 'y', 'z', 'w' },
              quat = { 'x', 'y', 'z', 'w' }, rect = { 'x', 'y', 'w', 'h' } }
local COLOR = { color3 = 3, color4 = 4, color = 0 }
local KEYS = { 'space', 'enter', 'escape', 'tab', 'up', 'down', 'left', 'right', 'shift', 'ctrl', 'alt' }
for c = string.byte('a'), string.byte('z') do KEYS[#KEYS + 1] = string.char(c) end
for c = 0, 9 do KEYS[#KEYS + 1] = tostring(c) end
local function choices(w, d)  -- what a value can be picked from: its options, the keys, the assets, the nodes (or nil)
  if not d or d.container then return nil end
  if d.type == 'string' and type(d.options) == 'table' and #d.options > 0 then return d.options end
  if d.type == 'key' then return KEYS end
  if (d.type == 'asset' or d.type == 'node') and w then
    local out = { 'none' }
    local function add(n, deep)
      for _, ch in ipairs(w:children(n)) do
        if #out < 47 then out[#out + 1] = ch.path; if deep then add(ch, deep) end end
      end
    end
    local root = w:node(d.type == 'asset' and '/assets' or '/objects')
    if root then add(root, d.type == 'node') end
    return out
  end
end
local function range_of(d)  -- its min..max (an angle: -180..180 unless said)
  local lo, hi = tonumber(d.min), tonumber(d.max)
  if d.type == 'angle' then lo, hi = lo or -180, hi or 180 end
  return lo, hi
end
local function type_spec(d, w)  -- for C: 'range lo hi int' / 'choice' / 'color' / 'vec'
  if not d or d.container then return nil end
  if NUMS[d.type] then
    local lo, hi = range_of(d)
    if lo and hi and lo < hi then return string.format('range %.17g %.17g %d', lo, hi, d.type == 'int' and 1 or 0) end
    return nil
  end
  if COLOR[d.type] then return 'color' end
  if VEC[d.type] then return 'vec' end
  if choices(w, d) then return 'choice' end
end
local function fit(d, v)  -- a number kept to its member: whole (int), min..max (an angle: around)
  if d.type == 'int' then v = math.floor(v + 0.5) end
  if d.type == 'angle' and not tonumber(d.min) and not tonumber(d.max) then
    v = v % 360
    if v > 180 then v = v - 360 end
    return v
  end
  if tonumber(d.min) and v < d.min then v = d.min end
  if tonumber(d.max) and v > d.max then v = d.max end
  return v
end
local function vec_text(d, v)  -- a vector in one line: "1, 2, 3" (its names' order)
  local t = {}
  for i, k in ipairs(VEC[d.type]) do t[i] = prop_num(tonumber(v[k]) or 0) end
  return table.concat(t, ', ')
end
local function default_for(w, d, depth)  -- what a member of this description starts with
  if d.container then return {} end
  if PRIM[d.type] or COLOR[d.type] or VEC[d.type] then
    local v = ecs.copy(ecs.BUILTIN[d.type] or (d.type == 'color' and { 255, 255, 255 }))
    if d.type == 'string' and type(d.options) == 'table' and d.options[1] then v = d.options[1] end
    if type(v) == 'number' then v = fit(d, v) end
    return v
  end
  local t = {}
  local c = (depth or 0) < 8 and is_class(w, d.type) and w:node('/classes/' .. d.type)
  for f, raw in pairs(c and c.c or {}) do
    local m = ecs.member(raw)
    t[f] = m.value ~= nil and ecs.copy(m.value) or default_for(w, m, (depth or 0) + 1)
  end
  return t
end
local function check_value(w, d, v, label)  -- v kept to its type -> v, or nil and why not
  if not d then return v end
  if d.container then
    if type(v) ~= 'table' then return nil, label .. ': a ' .. d.container end
    return v
  end
  local nc = COLOR[d.type]
  if nc then
    local ok = type(v) == 'table' and (nc == 0 and (#v == 3 or #v == 4) or #v == nc)
    for i = 1, ok and #v or 0 do if type(v[i]) ~= 'number' or v[i] < 0 or v[i] > 255 then ok = false end end
    if not ok then
      return nil, label .. ': a colour, ' .. (nc == 3 and '{ r, g, b }' or nc == 4 and '{ r, g, b, a }' or '{ r, g, b } or { r, g, b, a }') .. ', each 0..255'
    end
    return v
  end
  local names = VEC[d.type]
  if names then  -- named numbers (or in order: { 1, 2 } is { x = 1, y = 2 })
    local out = {}
    for i, k in ipairs(names) do
      local x = type(v) == 'table' and (v[k] == nil and v[i] or v[k]) or nil
      if type(x) ~= 'number' then return nil, label .. ': a ' .. d.type .. ', ' .. #names .. ' numbers (' .. table.concat(names, ', ') .. ')' end
      out[k] = x
    end
    if d.type == 'quat' then  -- (kept normalized: a rotation)
      local len = math.sqrt(out.x * out.x + out.y * out.y + out.z * out.z + out.w * out.w)
      if len == 0 then out.x, out.y, out.z, out.w = 0, 0, 0, 1
      else for _, k in ipairs(names) do out[k] = tonumber(string.format('%.6g', out[k] / len)) end end
    end
    if d.type == 'rect' and (out.w < 0 or out.h < 0) then return nil, label .. ': a rect, its w and h 0 or more' end
    return out
  end
  local want = PRIM[d.type]
  if want then
    if (d.type == 'asset' or d.type == 'node') and v == 'none' then v = '' end
    if type(v) ~= want or (d.type == 'int' and v ~= math.floor(v)) then
      return nil, label .. ': ' .. (d.type == 'int' and 'a whole number' or d.type == 'bool' and 'true or false' or ('a ' .. d.type))
    end
    if want == 'number' then v = fit(d, v) end
    if d.type == 'asset' and v ~= '' and (v:sub(1, 8) ~= '/assets/' or (w and not w:node(v))) then return nil, label .. ': no asset ' .. v end
    if d.type == 'node' and v ~= '' and w and not w:node(v) then return nil, label .. ': no node ' .. v end
    local list = (d.type == 'string' or d.type == 'key') and choices(w, d)
    if list then
      local ok = false
      for _, o in ipairs(list) do if o == v then ok = true end end
      if not ok then return nil, label .. ': one of ' .. table.concat(list, ', ') end
    end
    return v
  end
  if is_class(w, d.type) and type(v) ~= 'table' then return nil, label .. ': a ' .. d.type .. ' (a table)' end
  return v
end
local function prop_eff(w, n, keys)  -- what a node has there (or inherits from its class)
  local v = get(n, keys)
  if v == nil then v = class_value(w, n, keys) end
  return v
end
local function prop_show(v)  -- a value in one line (a tooltip's)
  if type(v) == 'number' then return prop_num(v) end
  if type(v) == 'string' then return string.format('%q', v) end
  if type(v) == 'table' then return ((ecs.encode(v) or '?'):gsub('^return ', '')) end
  return tostring(v)
end
local function type_names(w, classes_only, builtins_only)  -- the types a member can have: /classes' names (by length)
  local t = {}
  local cs = w:node('/classes')
  for _, c in ipairs(cs and w:children(cs) or {}) do
    local b = ecs.BUILTIN[c.name] ~= nil
    if not (classes_only and b) and not (builtins_only and not b) then t[#t + 1] = c.name end
  end
  table.sort(t, function(a, b) if #a ~= #b then return #a < #b end return a < b end)
  return table.concat(t, '|')
end
local function summary(d)  -- a member in a few words: "int 1..20", "array of string", "map string -> int"
  if d.container == 'map' then return 'map ' .. d.type .. ' -> ' .. (d.values or 'bool') end
  local s = d.type
  if tonumber(d.min) or tonumber(d.max) then s = s .. ' ' .. (d.min and prop_num(d.min) or '') .. '..' .. (d.max and prop_num(d.max) or '') end
  if type(d.options) == 'table' and #d.options > 0 then s = s .. ' ' .. table.concat(d.options, '|') end
  if d.container then s = d.container .. ' of ' .. s end
  return s
end
-- rows: { id, label, text, kind, depth, mixed, over, cls, def, spec, opts, tip, kind_text, kind_opts }
-- kinds: num bool str code table lit info color choice add member (typed
-- from nothing) pick (a drop-down: opts, '|'-separated) member_row (a
-- class's member: its name (label), type (text, opts) and kind (kind_text,
-- kind_opts: "var|[] array|() set|{} map>bool,int,..." -- map opens a list of
-- the values' types)); cls: 'i' / 'd' (above), 'e' an element of a
-- collection (RMB: remove it)
function viewer_props(w, paths)
  if w.builtins then w:builtins() end
  local n = paths[1] and w:node(paths[1])
  if not n then return {} end
  local runs = {}  -- system name -> position in the run order
  for i, name in ipairs(w.order or {}) do runs[name] = i end
  local sw = viewer_script_world()  -- over: differs from what the script builds
  local sn = sw and (sw:node(paths[1]) or false)
  if ecs.is_builtin(n.path) or ecs.is_plugin(n.path) then sn = nil end  -- (built in, a plugin: no script makes them)
  local others = {}
  for i = 2, #paths do others[#others + 1] = w:node(paths[i]) end
  local rows, marks, types = {}, {}, {}  -- marks[id]: { cls, def }; types[id]: its type (a description)
  local cls_name = n.path:match('^/classes/([^/]+)$')
  local function row(id, label, text, kind, depth, opts, tip)
    rows[#rows + 1] = { ecs.encode(id), label, text, kind, depth, false, false, nil, nil, nil, opts, tip }
  end
  if viewer_naming ~= nil and viewer_naming ~= n.path then viewer_naming = nil end
  if viewer_naming == n.path then  -- (renaming it: from the tree's menu, or a copy just made)
    row({ '?name' }, 'name', n.name, 'lit', 0, nil, 'Its name: type it, Enter (ESC: as it is)')
  end
  local plugin = n.path:match('^/plugins/([^/]+)$')  -- a plugin: its code, as links (open it here; run it again)
  if plugin and viewer_plugins_dir then
    local fs = require('fs')
    local src = fs.join(viewer_plugins_dir, plugin, 'editor.lua')
    if fs.read(src) then
      row({ '?source' }, 'source', 'editor.lua', 'action', 0, 'open:' .. src, 'Its code (it runs in the editor): open it here. Saving it reloads the plugin')
      row({ '?reload' }, 'reload', 'run it again', 'action', 0, 'lite:require(\'plugins.projectplugins\').reload(' .. string.format('%q', plugin) .. ')',
          'Run its editor.lua again: its open tabs come back with the new code')
    end
  end
  local file = viewer_asset_files[n.path]  -- an asset file: open it, what it is
  if file and n.path:sub(1, 6) == '/docs/' then  -- a document: open it (the markdown viewer; its tab flips to the text)
    local fs = require('fs')
    local text = fs.read(file) or ''
    local title = text:match('^#+%s*([^\n]+)') or text:match('\n#+%s*([^\n]+)')
    local words = 0
    for _ in text:gmatch('%S+') do words = words + 1 end
    row({ '?open' }, 'edit', n.name, 'action', 0, 'open:' .. file, 'Open it: rendered (the tab\'s icon flips it to its text, to write)')
    if title then row({ '?title' }, 'title', title, 'info', 0) end
    row({ '?size' }, 'size', words .. ' words, ' .. #text .. ' bytes', 'info', 0)
    row({ '?file' }, 'file', file, 'info', 0)
    return rows
  end
  if file and n.path:sub(1, 7) == '/saves/' then  -- a savegame: what's in it (w:savegame wrote it)
    local fs = require('fs')
    local text = fs.read(file)
    row({ '?open' }, 'edit', n.name, 'action', 0, 'open:' .. file, 'Open it as text: a tab in the editor (the game reads it with w:loadgame)')
    local v = text and ecs.decode(text, n.name)
    if type(v) == 'table' then
      local keys = {}
      for k in pairs(v) do keys[#keys + 1] = k end
      table.sort(keys, function(a, b) a, b = tostring(a), tostring(b) return #a < #b or (#a == #b and a < b) end)
      for _, k in ipairs(keys) do row({ '?save', k }, tostring(k), prop_show(v[k]), 'info', 0) end
    elseif v ~= nil then row({ '?save' }, 'value', prop_show(v), 'info', 0) end
    row({ '?size' }, 'size', text and (#text .. ' bytes') or 'gone', 'info', 0)
    row({ '?file' }, 'file', file, 'info', 0)
    return rows
  end
  if file then
    local ext = viewer_asset_ext(file)
    local plug = viewer_asset_exts[ext] or '?'
    local f, size = io.open(file, 'rb'), nil
    if f then size = f:seek('end'); f:close() end
    row({ '?open' }, 'edit', n.name, 'action', 0, 'open:' .. file, 'Open it in its plugin (' .. plug .. '): a tab in the editor')
    row({ '?plugin' }, 'plugin', plug, 'info', 0, nil, 'plugins/' .. plug .. ' opens .' .. ext .. ' files (its files.lua)')
    row({ '?size' }, 'size', size and (size .. ' bytes') or 'gone', 'info', 0)
    row({ '?file' }, 'file', file, 'info', 0)
    return rows
  end
  if cls_name and ecs.BUILTIN[cls_name] ~= nil then
    row({ '?used' }, 'built in', 'a plain type, starts at ' .. prop_show(ecs.BUILTIN[cls_name]), 'info', 0, nil,
        'A plain type, built in: a member can be one (pick it in its type). Starts at ' .. prop_show(ecs.BUILTIN[cls_name]))
  elseif cls_name then  -- a class: who uses it
    local users = {}
    for p, o in pairs(w.nodes) do
      if o.c[cls_name] ~= nil and p:sub(1, 9) ~= '/classes/' then users[#users + 1] = p end
    end
    table.sort(users)
    row({ '?used' }, 'used by', #users == 0 and 'nobody yet' or (#users .. ': ' .. table.concat(users, ', ')), 'info', 0)
  end
  local function add(keys, label, depth, v, kind, text, opts)
    local mixed = false
    for _, o in ipairs(others) do
      if not prop_same(prop_eff(w, o, keys), v) then mixed = true break end
    end
    local over = false
    if sn ~= nil then over = not sn or not prop_same(get(sn, keys), get(n, keys)) end  -- (what the node has: not its class's)
    local id = ecs.encode(keys)
    local m = marks[id]
    rows[#rows + 1] = { id, label, text, kind, depth, mixed, over, m and m[1], m and m[2], type_spec(types[id] or nil, w), opts }
  end
  local walk
  local function items(keys, label, depth, v, d)  -- a collection: its elements, then + item / + key
    local ks = prop_keys(v)
    local what = d.container == 'map' and ('map ' .. d.type .. ' -> ' .. (d.values or 'bool')) or (d.container .. ' of ' .. d.type)
    add(keys, label, depth, v, 'table', what .. ' (' .. #ks .. ')')
    local el = element(d)
    for _, k in ipairs(ks) do
      local sub = {}
      for i, kk in ipairs(keys) do sub[i] = kk end
      sub[#sub + 1] = k
      local id = ecs.encode(sub)
      marks[id] = { 'e' }
      types[id] = el
      if d.container == 'set' then add(sub, tostring(k), depth + 1, v[k], 'info', 'in the set')
      else walk(sub, type(k) == 'number' and ('[' .. k .. ']') or tostring(k), depth + 1, v[k]) end
    end
    local at = { d.container == 'array' and '?item' or '?key' }
    for _, k in ipairs(keys) do at[#at + 1] = k end
    if d.container == 'array' then row(at, '+ item', '', 'add', depth + 1, nil, 'Add an item at the end: what its type starts with')
    else row(at, '+ key', '', 'member', depth + 1, nil, 'Click, type a key (a ' .. d.type .. '), Enter') end
  end
  walk = function(keys, label, depth, v)
    local t = type(v)
    local id0 = ecs.encode(keys)
    if types[id0] == nil then types[id0] = view_at(w, n, keys) or false end
    local ft = types[id0] or nil
    if ft and ft.container and t == 'table' then return items(keys, label, depth, v, ft) end
    local spec = type_spec(ft, w)
    if spec == 'color' and t == 'table' then  -- a colour: one row, a swatch
      local c = {}
      for i = 1, #v do c[i] = prop_num(tonumber(v[i]) or 0) end
      return add(keys, label, depth, v, 'color', table.concat(c, ', '))
    end
    if spec == 'vec' and t == 'table' then return add(keys, label, depth, v, 'lit', vec_text(ft, v)) end  -- (a vector: one row, typed "1, 2, 3")
    if spec == 'choice' and t == 'string' then return add(keys, label, depth, v, 'choice', v == '' and 'none' or v, table.concat(choices(w, ft), '|')) end
    if t == 'number' then add(keys, label, depth, v, 'num', prop_num(v))
    elseif t == 'boolean' then add(keys, label, depth, v, 'bool', tostring(v))
    elseif t == 'string' then add(keys, label, depth, v, 'str', v)
    elseif ecs.is_code(v) then
      local src, lang = ecs.code_source(v)
      local _, nl = src:gsub('\n', '')
      local run = depth == 0 and runs[n.path == '/' and '/' .. keys[1] or n.path .. '/' .. keys[1]]
      add(keys, label, depth, v, 'code', (run and ('#' .. run .. '  ') or '') .. (nl + 1) .. ' lines' .. (lang ~= 'lua' and ('  ' .. lang) or ''))
    elseif t == 'table' then
      local ks = prop_keys(v)
      local cn = depth == 0 and class_node(w, n, keys[1])
      if cn then  -- a class: its members this node lacks, too
        local have, extra = {}, {}
        for _, k in ipairs(ks) do have[k] = true end
        for k in pairs(cn.c) do if not have[k] then extra[#extra + 1] = k end end
        for _, k in ipairs(extra) do ks[#ks + 1] = k end
        table.sort(ks, function(a, b) return tostring(a) < tostring(b) end)  -- (one order: setting one doesn't move it)
        local defs = {}
        for _, k in ipairs(ks) do
          if cn.c[k] ~= nil then defs[k] = ecs.start_value(ecs.member(cn.c[k])) end
          local d = defs[k]
          local id = ecs.encode({ keys[1], k })
          if d ~= nil and v[k] == nil then marks[id] = { 'i', prop_show(d) }
          elseif d ~= nil and not prop_same(v[k], d) then marks[id] = { 'd', prop_show(d) } end
        end
        add(keys, label, depth, v, 'table', 'class')
        for _, k in ipairs(ks) do
          local val = v[k]
          if val == nil then val = defs[k] end
          walk({ keys[1], k }, tostring(k), 1, val)
        end
        return
      end
      if depth >= 4 or #ks > 24 then  -- too big to unfold: one literal row
        local s = (ecs.encode(v) or '?'):gsub('^return ', '')
        add(keys, label, depth, v, 'lit', s)
      else
        add(keys, label, depth, v, 'table', #ks == 0 and '{}' or '')
        for _, k in ipairs(ks) do
          local sub = {}
          for i, kk in ipairs(keys) do sub[i] = kk end
          sub[#sub + 1] = k
          walk(sub, type(k) == 'number' and ('[' .. k .. ']') or tostring(k), depth + 1, v[k])
        end
      end
    else add(keys, label, depth, v, 'lit', tostring(v)) end
  end
  local tnames = type_names(w)
  local function member_rows(f, d, value, vlabel)  -- a member (a class's) or a typed field (a node's meta): its row, range / options, value
    local kind = d.container == 'map' and ('{} map:' .. (d.values or 'bool')) or ({ array = '[] array', set = '() set' })[d.container] or 'var'
    rows[#rows + 1] = { ecs.encode({ '?m', f }), tostring(f), d.type, 'member_row', 0, false, false, nil, nil, nil, tnames, nil,
                        kind, 'var|[] array|() set|{} map>' .. tnames:gsub('|', ',') }
    if NUMS[d.type] and d.container ~= 'map' then
      local r = (tonumber(d.min) or tonumber(d.max)) and ((d.min and prop_num(d.min) or '') .. '..' .. (d.max and prop_num(d.max) or '')) or 'none'
      row({ '?range', f }, 'range', r, 'lit', 1, nil, 'Its range: click, type min..max (1..20, 0.., ..5) or none, Enter. Both ends: a slider')
    elseif d.type == 'string' and d.container ~= 'map' then
      row({ '?options', f }, 'options', type(d.options) == 'table' and #d.options > 0 and table.concat(d.options, ', ') or 'none', 'lit', 1, nil,
          'The values it can have: click, type them with commas (w, up, i), Enter; none: any text')
    end
    walk({ f }, vlabel, 1, value)  -- (last: it keeps to the range / options above)
  end
  if cls_name and ecs.BUILTIN[cls_name] == nil then  -- a class: per member, its row (name, type, kind), its range or options, its default
    local names = {}
    for k in pairs(n.c) do if not RESERVED[k] then names[#names + 1] = k end end
    table.sort(names, function(a, b) return tostring(a) < tostring(b) end)
    for _, f in ipairs(names) do
      local d = ecs.member(n.c[f])
      member_rows(f, d, d.value ~= nil and d.value or default_for(w, d), 'default')
    end
    row({ '?member' }, '+ member', 'its name', 'member', 0, nil, 'Click, type a name, Enter: a new member (a bool; pick its type after)')
    return rows
  end
  local names = {}
  for k in pairs(n.c) do names[#names + 1] = k end
  table.sort(names, function(a, b)  -- systems first, in run order
    local ra = runs[(n.path == '/' and '' or n.path) .. '/' .. tostring(a)] or math.huge
    local rb = runs[(n.path == '/' and '' or n.path) .. '/' .. tostring(b)] or math.huge
    if ra ~= rb then return ra < rb end
    return tostring(a) < tostring(b)
  end)
  for _, k in ipairs(names) do
    if k == 'meta' and meta_of(n) then  -- (hidden: shown as its fields' types)
    elseif own_desc(n, k) then member_rows(k, own_desc(n, k), n.c[k], 'value')
    else walk({ k }, tostring(k), 0, n.c[k]) end
  end
  local under_objects = n.path:sub(1, 9) == '/objects/'
  local under_data = n.path:sub(1, 6) == '/data/'
  local cs = w.layout and w:layout() and (under_data or n.path == '/config' or (w:live(n.path) and n.path ~= '/objects' and n.path ~= '/entities')) and w:node('/classes')
  if cs then  -- an object, a /data node, /config (a setting): + component, a drop-down of the classes it has none of, then the plain types
    local can = {}
    for name in type_names(w, true):gmatch('[^|]+') do if n.c[name] == nil then can[#can + 1] = name end end
    for name in type_names(w, false, true):gmatch('[^|]+') do can[#can + 1] = name end
    if #can > 0 then
      row({ '?add' }, '+ component', 'pick a type', 'pick', 0, table.concat(can, '|'),
          "Add a component: one of your classes (its values), or a plain type (name it: its type is kept, in meta)")
    end
  end
  if n.path == '/objects' or n.path == '/data' or n.path == '/systems' or under_objects or under_data then  -- + object / + data / + system / + child: a new node
    local what = n.path == '/objects' and '+ object' or n.path == '/data' and '+ data' or n.path == '/systems' and '+ system' or '+ child'
    row({ '?new' }, what, 'its name', 'member', 0, nil, 'Click, type a name, Enter: a new node ' .. (n.path == '/' and '' or n.path) .. '/<name>, selected')
  end
  if viewer_disk and (n.path == '/docs' or n.path:sub(1, 6) == '/docs/') then  -- + folder, + document: on disk
    row({ '?folder' }, '+ folder', 'its name', 'member', 0, nil, 'Click, type a name, Enter: a new folder here (on disk, in docs/)')
    row({ '?doc' }, '+ document', 'its name', 'member', 0, nil, 'Click, type a name, Enter: a new markdown document (<name>.md), opened to write')
  end
  if viewer_disk and (n.path == '/assets' or n.path:sub(1, 8) == '/assets/') then  -- + folder, + <kind>: on disk
    row({ '?folder' }, '+ folder', 'its name', 'member', 0, nil, 'Click, type a name, Enter: a new folder here (on disk, in assets/)')
    for _, t in ipairs(viewer_asset_templates) do
      row({ '?asset', t.file }, '+ ' .. t.kind, 'its name', 'member', 0, nil,
          'Click, type a name, Enter: a new ' .. t.kind .. ' (.' .. t.ext .. ', from plugins/' .. t.plugin .. '/templates), opened to edit')
    end
  end
  if n.path == '/classes' then  -- + a class
    row({ '?class' }, '+ class', 'its name', 'member', 0, nil, 'Click, type a name, Enter: a new class (add its members after)')
  end
  return rows
end
-- Reordering (tree drag / system drag): rewrite the root's order list so
-- `paths` come in this order. Their exact lines are removed, and the block
-- goes in before the first line still matching any of them (a glob), so
-- the explicit lines win.
function viewer_reorder(w, paths)
  local root = w:node('/').c
  local list, set = {}, {}
  for _, p in ipairs(paths) do set[p] = true end
  for _, l in ipairs(type(root.order) == 'table' and root.order or {}) do
    if not set[l] then list[#list + 1] = l end
  end
  local at = #list + 1
  for i, l in ipairs(list) do
    for _, p in ipairs(paths) do
      if type(l) == 'string' and ecs.match(l, p) then at = math.min(at, i) end
    end
  end
  for k, p in ipairs(paths) do table.insert(list, at + k - 1, p) end
  root.order = list
end
local function moved(list, item, target, after)  -- list without item, item next to target
  local out = {}
  for _, p in ipairs(list) do if p ~= item then out[#out + 1] = p end end
  for i, p in ipairs(out) do
    if p == target then table.insert(out, after and i + 1 or i, item) return out end
  end
  out[#out + 1] = item
  return out
end
function viewer_tree_move(w, path, target, after)  -- siblings only
  local n, t = w:node(path), w:node(target)
  if not n or not t or n == t or n.parent ~= t.parent or not n.parent then return false end
  if n.parent == w.root and w:layout() then return false end  -- (the layout's roots keep their order)
  local sib = {}
  for _, ch in ipairs(w:children(n.parent)) do sib[#sib + 1] = ch.path end
  if n.parent.path == '/systems' then  -- (the layout's systems: /systems' order, by name, is the run order)
    local names = {}
    for _, p in ipairs(moved(sib, path, target, after)) do names[#names + 1] = p:match('[^/]+$') end
    n.parent.c.order = names
    if w.sync_code then w:sync_code() end
    return true
  end
  viewer_reorder(w, moved(sib, path, target, after))
  return true
end
function viewer_system_move(w, node, comp, target, after)  -- systems of one node
  local base = node == '/' and '' or node
  local sys = {}
  for _, name in ipairs(w.order) do
    if w.systems[name] and w.systems[name].code and name:match('^(.*)/[^/]*$') == base then sys[#sys + 1] = name end
  end
  viewer_reorder(w, moved(sys, base .. '/' .. comp, base .. '/' .. target, after))
  w:sync_code()
  return true
end
-- a class edited (/classes/<name>): its nodes' values that were never
-- overridden follow (ecs: w:upgrade_class); viewer_note says how many
viewer_note = nil
viewer_select = nil
local function class_edited(w, name, before)
  local k = w:upgrade_class(name, before)
  if k > 0 then viewer_note = string.format('/classes/%s: %d value%s upgraded in its nodes (not their own)', name, k, k > 1 and 's' or '') end
  return k
end
local function users_of(w, cname)  -- the nodes with a cname component (a table): their components
  local out = {}
  for p, o in pairs(w.nodes) do
    local v = o.c[cname]
    if type(v) == 'table' and not ecs.is_code(v) and p:sub(1, 9) ~= '/classes/' then out[#out + 1] = v end
  end
  return out
end
local function with_class(w, p, fn)  -- fn() changes node p: a class's nodes follow (upgrade)
  local cname = class_of_path(p)
  local n = w:node(p)
  local before = cname and n and ecs.copy(n.c)
  local r = fn()
  if before then class_edited(w, cname, before) end
  return r
end
local function prop_assign(w, paths, id, fn)  -- fn(old) -> new, on every selected node
  local keys = assert(ecs.decode(id))
  local count = 0
  for _, p in ipairs(paths) do
    local n = not ecs.is_builtin(p) and w:node(p) or nil  -- (built in: read-only)
    if n then
      with_class(w, p, function()
        local sk = store(n, keys)
        local t = n.c
        for i = 1, #sk - 1 do t = type(t) == 'table' and t[sk[i]] or nil end
        local old = type(t) == 'table' and t[sk[#sk]]
        if old == nil and #keys == 2 then  -- inherited: from its class's value (the component, if the node lacks it too)
          old = class_value(w, n, keys)
          if old ~= nil and t == nil and class_node(w, n, keys[1]) and n.c[keys[1]] == nil then n.c[keys[1]] = {}; t = n.c[keys[1]] end
        end
        if type(t) == 'table' and (#sk == 1 or old ~= nil) then
          local v = fn(old)
          if v ~= nil then t[sk[#sk]] = v; count = count + 1 end
        end
      end)
    end
  end
  return count
end
local function node_table(w, n, keys)  -- the table at keys in n (inherited from its class: set on n first)
  local t = prop_get(n, store(n, keys))
  if t == nil and #keys == 2 and type(n.c[keys[1]]) == 'table' then
    local d = class_value(w, n, keys)
    if type(d) == 'table' then n.c[keys[1]][keys[2]] = d; t = d end
  end
  return type(t) == 'table' and t or nil
end
-- Members (a class node's rows): + member (a name: a bool), rename, remove,
-- type / kind (drop-downs; a map's values: in kind's sub-list), range, options. A change keeps the
-- member's value if it still fits, else it starts again (default_for); the
-- class's nodes follow: never-overridden values upgrade, values that don't
-- fit any more start again too.
local function fits(w, d, v) return v ~= nil and (check_value(w, d, v, '')) ~= nil end
local function member_at(w, path, f)  -- member f of a class, or a node's own typed field f -> node, class name (or nil), its description
  local n = path and not ecs.is_builtin(path) and w:node(path)
  if not n then return nil end
  local cname = class_of_path(path)
  if cname then return n.c[f] ~= nil and n or nil, cname, n.c[f] ~= nil and ecs.member(n.c[f]) or nil end
  local d = own_desc(n, f)
  if d then return n, nil, d end
end
local function member_edit(w, path, f, fn)  -- fn(d): d, a copy of member f's description (and value), changed -> ok, err
  local n, cname, d0 = member_at(w, path, f)
  if not n then return false, 'no member ' .. tostring(f) end
  local before = cname and ecs.copy(n.c)
  local d = ecs.copy(d0)
  if not cname then d.value = ecs.copy(n.c[f]) end  -- (a node's field: its value is the component itself)
  local err = fn(d)
  if err then return false, err end
  if d.container ~= 'map' then d.values = nil elseif not d.values then d.values = 'bool' end
  if not NUMS[d.type] or d.container == 'map' then d.min, d.max = nil, nil end
  if d.type ~= 'string' or d.container == 'map' then d.options = nil end
  if not fits(w, d, d.value) then d.value = default_for(w, d) end
  if not cname then
    n.c[f] = d.value
    d.value = nil
    n.c.meta[f] = d
    return true
  end
  n.c[f] = d
  class_edited(w, cname, before)
  local k = 0
  for _, v in ipairs(users_of(w, cname)) do  -- (their own values that don't fit: start again)
    if v[f] ~= nil and not fits(w, d, v[f]) then v[f] = ecs.copy(d.value); k = k + 1 end
  end
  if k > 0 then viewer_note = string.format('/classes/%s: %d node%s had a %s that no longer fits: set to the new default', cname, k, k > 1 and 's' or '', tostring(f)) end
  return true
end
local function new_name(text)
  return tostring(text):match('^%s*([%a_][%w_]*)%s*$')
end
local function member_add(w, path, text)  -- + member: its name; a bool to start with
  local cname = class_of_path(path or '')
  local n = cname and w:node(path)
  if not n then return false, 'members go on a class: /classes/<name>' end
  local name = new_name(text)
  if not name then return false, 'a name: letters, digits and _ (not first a digit)' end
  if RESERVED[name] then return false, name .. ': a reserved name' end
  if n.c[name] ~= nil then return false, cname .. ' already has a ' .. name end
  local before = ecs.copy(n.c)
  n.c[name] = { type = 'bool', value = false }
  class_edited(w, cname, before)
  return true
end
viewer_rename = nil
local function field_add(w, paths, t)  -- + component > a plain type: a field (named after it: renamed at once), its type in meta
  for _, p in ipairs(paths) do
    local n = not ecs.is_builtin(p) and w:node(p)
    if n and not class_of_path(p) then
      local name, k = t, 1
      while n.c[name] ~= nil or RESERVED[name] do k = k + 1; name = t .. k end
      n.c[name] = default_for(w, { type = t })
      if type(n.c.meta) ~= 'table' then n.c.meta = {} end
      n.c.meta[name] = { type = t }
      if p == paths[1] then viewer_rename = ecs.encode({ '?m', name }) end  -- (C: type its name)
    end
  end
  return true
end
local function member_rename(w, path, f, text)
  local n, cname = member_at(w, path, f)
  local name = new_name(text)
  if not n then return false, 'no member ' .. tostring(f) end
  if not name then return false, 'a name: letters, digits and _ (not first a digit)' end
  if name == f then return true end
  if RESERVED[name] then return false, name .. ': a reserved name' end
  if n.c[name] ~= nil then return false, (cname or path) .. ' already has a ' .. name end
  n.c[name], n.c[f] = n.c[f], nil
  if not cname then n.c.meta[name], n.c.meta[f] = n.c.meta[f], nil return true end
  for _, v in ipairs(users_of(w, cname)) do v[name], v[f] = v[f], nil end  -- (its nodes: the same value, renamed)
  return true
end
local function member_remove(w, path, f)
  local n, cname = member_at(w, path, f)
  if not n then return false, 'no member ' .. tostring(f) end
  n.c[f] = nil
  if not cname then
    n.c.meta[f] = nil
    if next(n.c.meta) == nil then n.c.meta = nil end  -- (no typed fields left: no meta)
    return true
  end
  for _, v in ipairs(users_of(w, cname)) do v[f] = nil end  -- (gone from its nodes too)
  return true
end
local function node_new(w, parent, text)  -- + object / + data / + child: a node named so, selected (an object: at 0, 0)
  local name = tostring(text):match('^%s*([%w_%-]+)%s*$')
  if not name then return false, 'a name: letters, digits, _ and -' end
  local path = (parent == '/' and '' or parent) .. '/' .. name
  if w:node(path) then return false, path .. ' is already there' end
  local object = parent == '/objects' or parent:sub(1, 9) == '/objects/'
  if parent == '/systems' then  -- a system: its code, empty, to fill in (and at the end of the run order)
    w:spawn(path, { system = ecs.code('-- ' .. name .. ': runs every tick\nreturn function(w, dt)\nend\n') })
    local sys = w:node('/systems')
    if type(sys.c.order) == 'table' then sys.c.order[#sys.c.order + 1] = name end
    if w.sync_code then w:sync_code() end
    viewer_select = path
    viewer_note = path .. ': new, empty. Click its system row to write it'
    history_made('new ' .. path, path)
    return true
  end
  w:spawn(path, object and { xform = { x = 0, y = 0 } } or {})
  viewer_select = path
  viewer_note = path .. ': new. + component gives it more'
  history_made('new ' .. path, path)
  return true
end
-- The tree's right-click menu: Rename (a "name" row in the panel, typed),
-- Duplicate (a copy beside it, <name>2..., then its name typed), Delete.
-- Not the root, the layout's roots, nor the built-in classes. A class
-- renamed: its nodes' components too; a system: /systems' order too.
viewer_naming = nil
local function editable_node(w, p)
  if not p or p == '/' or ecs.is_builtin(p) or not w:node(p) then return false end
  if w.layout and w:layout() then
    for _, r in ipairs(ecs.ROOTS) do if p == r then return false end end
  end
  return true
end
local function subtree(w, from)  -- a node and all below it, parents first
  local list = {}
  for p in pairs(w.nodes) do if p == from or p:sub(1, #from + 1) == from .. '/' then list[#list + 1] = p end end
  table.sort(list)
  return list
end
local function copy_tree(w, from, to)
  for _, p in ipairs(subtree(w, from)) do w:spawn(to .. p:sub(#from + 1), ecs.copy(w.nodes[p].c)) end
end
local function parent_of(p) local q = p:match('^(.*)/[^/]+$') return q == '' and '/' or q end
-- Assets on disk: a node under /assets is a folder or a file of the game's
-- assets/ folder, and the tree's Rename, Duplicate and Delete happen there at
-- once (no Save needed). A delete moves it into the game's .trash folder (by
-- date: get it back by hand; the editor and Export ignore dot folders).
local function asset_disk(w, path)  -- its file or folder on disk (nil: not an asset, or not there yet), is it a file
  if not viewer_disk or not (path == '/assets' or path:sub(1, 8) == '/assets/' or path:sub(1, 7) == '/saves/' or path:sub(1, 6) == '/docs/') then return nil end
  local fs = require('fs')
  local f = viewer_asset_files[path]
  if f then return fs.read(f) and f or nil, true end
  local d = viewer_disk:dir(path)
  return fs.isdir(d) and d or nil, false
end
local function disk_refresh(w)  -- what's on disk now: the tree's files, and not unsaved changes
  viewer_mount_assets(w, true)
  local ok, b = viewer_disk:read('/**')
  if ok then viewer_last_disk = b end
end
local function copy_disk(from, to)  -- a file, or a folder and all in it
  local fs = require('fs')
  if fs.isdir(from) then
    fs.mkdir(to)
    for _, e in ipairs(fs.list(from)) do
      local ok, err = copy_disk(fs.join(from, e.name), fs.join(to, e.name))
      if not ok then return false, err end
    end
    return true
  end
  local data = fs.read(from)
  if not data then return false, "can't read " .. from end
  return fs.write(to, data)
end
local function dir_of(f) return f:match('^(.*)[/\\][^/\\]+$') end
viewer_rename_queue = {}  -- (several nodes renamed: the ones still to type)
local function rename_next()
  local nxt = table.remove(viewer_rename_queue, 1)
  if nxt then viewer_select, viewer_naming, viewer_rename = nxt, nxt, ecs.encode({ '?name' }) end
end
local function renamed(from, to)  -- (the queue: paths under a renamed node follow it)
  for i, q in ipairs(viewer_rename_queue) do
    if q:sub(1, #from + 1) == from .. '/' then viewer_rename_queue[i] = to .. q:sub(#from + 1) end
  end
end
local function node_rename(w, path, text)
  local dpath, isfile = asset_disk(w, path)
  local ext = isfile and path:match('(%.[^%./]+)$') or ''
  if isfile then text = tostring(text):gsub('%.[%w]+%s*$', '') end  -- (a file keeps its extension)
  local name = tostring(text):match('^%s*([%w_%-]+)%s*$')
  if not name then return false, 'a name: letters, digits, _ and -' end
  local old = path:match('[^/]+$')
  local to = (parent_of(path) == '/' and '' or parent_of(path)) .. '/' .. name .. ext
  viewer_naming = nil
  if to == path then rename_next() return true end
  if w:node(to) then return false, to .. ' is already there' end
  local function record() history_begin('rename ' .. path .. ' -> ' .. to); history_step({ 'renamed', path, to }); history_end() end
  if dpath then  -- an asset: on disk first
    local fs, disk = require('fs'), require('disk')
    local target = fs.join(dir_of(dpath), isfile and (name .. ext) or disk.encode(name))
    if not fs.rename(dpath, target) then return false, "can't rename " .. dpath end
    copy_tree(w, path, to)
    w:remove(path)
    disk_refresh(w)
    renamed(path, to)
    viewer_select, viewer_note = to, path .. ' -> ' .. to .. ' (on disk too)'
    record()
    rename_next()
    return true
  end
  if path:sub(1, 9) == '/classes/' and (RESERVED[name] or not name:match('^[%a_][%w_]*$')) then
    return false, 'a class name: letters, digits and _ (not first a digit; not meta)'
  end
  copy_tree(w, path, to)
  w:remove(path)
  local cname = path:match('^/classes/([^/]+)$')
  if cname then  -- (its nodes' components: renamed too)
    for p, o in pairs(w.nodes) do
      if o.c[cname] ~= nil and p:sub(1, 9) ~= '/classes/' then o.c[name], o.c[cname] = o.c[cname], nil end
    end
  end
  if parent_of(path) == '/systems' then  -- (the run order: by name)
    local sys = w:node('/systems')
    for i, nm in ipairs(type(sys.c.order) == 'table' and sys.c.order or {}) do if nm == old then sys.c.order[i] = name end end
    if w.sync_code then w:sync_code() end
  end
  viewer_select = to
  viewer_note = path .. ' -> ' .. to
  record()
  renamed(path, to)
  rename_next()
  return true
end
local function node_duplicate(w, path, quiet)
  local dpath, isfile = asset_disk(w, path)
  local ext = isfile and path:match('(%.[^%./]+)$') or ''
  local stem = path:match('[^/]+$'):sub(1, -#ext - 1):gsub('%d+$', '')
  local base = (parent_of(path) == '/' and '' or parent_of(path)) .. '/'
  local k = 2
  while w:node(base .. stem .. k .. ext) do k = k + 1 end
  local to = base .. stem .. k .. ext
  if dpath then  -- an asset: its files copied on disk
    local fs, disk = require('fs'), require('disk')
    local ok, err = copy_disk(dpath, fs.join(dir_of(dpath), isfile and (stem .. k .. ext) or disk.encode(stem .. k)))
    if not ok then return false, tostring(err) end
  end
  copy_tree(w, path, to)
  if dpath then disk_refresh(w) end
  history_step({ 'made', to })
  if quiet then return true, to end
  if parent_of(path) == '/systems' and w.sync_code then w:sync_code() end
  viewer_select, viewer_naming = to, to
  viewer_rename = ecs.encode({ '?name' })
  viewer_note = to .. ': a copy of ' .. path
  return true
end
local function node_delete(w, path)
  local below = #subtree(w, path) - 1
  local parent = parent_of(path)
  local dpath = asset_disk(w, path)
  local trashed
  if dpath then  -- an asset: into the game's .trash folder (.trash/<day>/<undo level>/; an undo's: undone/)
    local fs = require('fs')
    local trash
    trash = undo_rec and level_dir(undo_rec) or trash_dir('undone')
    local base, k = dpath:match('[^/\\]+$'), 1
    local target = fs.join(trash, base)
    while fs.isdir(target) or fs.read(target) do k = k + 1; target = fs.join(trash, k .. ' ' .. base) end
    if not fs.rename(dpath, target) then return false, "can't move " .. dpath .. ' to ' .. trash end
    trashed = target
    history_step({ 'moved', dpath, target })
  end
  local snap = {}  -- (for Undo: the nodes as they are)
  for _, p in ipairs(subtree(w, path)) do snap[#snap + 1] = { p, ecs.copy(w.nodes[p].c) } end
  history_step({ 'nodes', snap })
  if parent == '/systems' and type(w:node('/systems').c.order) == 'table' then history_step({ 'order', ecs.copy(w:node('/systems').c.order) }) end
  w:remove(path)
  if trashed then disk_refresh(w) end
  if parent == '/systems' then
    local sys = w:node('/systems')
    local name = path:match('[^/]+$')
    local order = type(sys.c.order) == 'table' and sys.c.order or {}
    for i = #order, 1, -1 do if order[i] == name then table.remove(order, i) end end
    if w.sync_code then w:sync_code() end
  end
  viewer_select = parent
  viewer_note = path .. ' deleted' .. (below > 0 and (' (and ' .. below .. ' below it)') or '')
                .. (trashed and ('. Its files: in ' .. trashed) or '. On disk until you save (not saving keeps it there)')
                .. (undoing and '' or '. Undo: the tree\'s menu, or CTRL+Z over the tree')
  return true
end
function viewer_tree_undo(w)  -- the last thing the tree did, undone -> ok, err
  local r = table.remove(viewer_history)
  if not r then return false, 'nothing to undo' end
  local fs = require('fs')
  local errs, first, files = {}, nil, false
  undoing = true
  for i = #r.steps, 1, -1 do
    local st = r.steps[i]
    if st[1] == 'moved' then  -- back from the trash
      files = true
      if fs.isdir(st[2]) or fs.read(st[2]) then errs[#errs + 1] = st[2] .. ' is there already (left in ' .. st[3] .. ')'
      elseif not fs.rename(st[3], st[2]) then errs[#errs + 1] = "can't move " .. st[3] .. ' back' end
    elseif st[1] == 'nodes' then
      for _, n in ipairs(st[2]) do if not w.nodes[n[1]] then w:spawn(n[1], ecs.copy(n[2])) end end
      first = first or (st[2][1] and st[2][1][1])
    elseif st[1] == 'order' then
      local sys = w:node('/systems')
      if sys then sys.c.order = ecs.copy(st[2]); if w.sync_code then w:sync_code() end end
    elseif st[1] == 'made' then
      if w:node(st[2]) then
        local ok, err = node_delete(w, st[2])
        if not ok then errs[#errs + 1] = err end
      end
      first = first or parent_of(st[2])
    elseif st[1] == 'comps' then  -- values as they were (a property edit, a move in the game view)
      local code = false
      for _, c in ipairs(st[2]) do
        local n = w:node(c[1])
        if n then
          n.c[c[2]] = c[3] ~= nil and ecs.copy(c[3]) or nil
          if c[1] == '/systems' or c[1]:sub(1, 9) == '/systems/' then code = true end
        end
      end
      if code and w.sync_code then w:sync_code() end
      first = first or (st[2][1] and st[2][1][1])
    elseif st[1] == 'renamed' then
      if w:node(st[3]) then
        local ok, err = node_rename(w, st[3], st[2]:match('[^/]+$'))
        if not ok then errs[#errs + 1] = err end
      end
      first = first or st[2]
    end
  end
  undoing = false
  if r.dir and #errs == 0 then  -- (its trash folder: empty now)
    fs.rmfile(fs.join(r.dir, 'undo.lua'))
    fs.rmdir(r.dir)
    fs.rmdir(dir_of(r.dir))  -- (its day too, when nothing else is in it)
  end
  if viewer_disk and (files or r.dir) then disk_refresh(w) end
  if first then viewer_select = first end
  viewer_note = 'undone: ' .. r.what .. (#errs > 0 and ('. But: ' .. table.concat(errs, '; ')) or '')
  return #errs == 0, #errs > 0 and table.concat(errs, '; ') or nil
end
-- new things under a node, typed in their props row at once (as Rename):
-- in /assets a folder or a file of a kind a plugin makes; a node, a component
local function new_items(w, path)
  local list = {}
  if viewer_disk and (path == '/assets' or path:sub(1, 8) == '/assets/') and not viewer_asset_files[path] then
    list[#list + 1] = { 'New folder', { '?folder' } }
    for _, t in ipairs(viewer_asset_templates) do list[#list + 1] = { 'New ' .. t.kind, { '?asset', t.file } } end
  end
  local roots = { ['/objects'] = true, ['/data'] = true, ['/systems'] = true }
  if roots[path] or path:sub(1, 9) == '/objects/' or path:sub(1, 6) == '/data/' then
    list[#list + 1] = { 'New node', { '?new' } }
    if not roots[path] then list[#list + 1] = { 'New component', { '?add' } } end
  end
  if viewer_disk and (path == '/docs' or path:sub(1, 6) == '/docs/') and not viewer_asset_files[path] then  -- (documents: on disk)
    list[#list + 1] = { 'New folder', { '?folder' } }
    list[#list + 1] = { 'New document', { '?doc' } }
  end
  if path == '/config' and w:node('/config') then list[#list + 1] = { 'New component', { '?add' } } end  -- (a setting)
  if path == '/classes' then list[#list + 1] = { 'New class', { '?class' } } end  -- (typed as its + class row)
  return list
end
local function chosen(w, path, paths)  -- the nodes a menu item is for: the selection, if it was right-clicked in it
  local list, inside = {}, false
  for _, p in ipairs(paths or {}) do if p == path then inside = true end end
  if not inside or #paths < 2 then return { path } end
  table.sort(paths)
  for _, p in ipairs(paths) do  -- (one below another: its parent covers it)
    local covered = false
    for _, q in ipairs(list) do if p:sub(1, #q + 1) == q .. '/' then covered = true end end
    if not covered and editable_node(w, p) then list[#list + 1] = p end
  end
  return list
end
-- an asset file's ways to open, as the editor's "Open tab with >" (plugins/openwith.lua
-- there): { name shown, opener key }; a plugin's name: its P.title (its editor.lua)
local plugin_titles = {}
local function plugin_title(key)
  if plugin_titles[key] == nil then
    local src = viewer_plugins_dir and require('fs').read(require('fs').join(viewer_plugins_dir, key, 'editor.lua')) or ''
    plugin_titles[key] = src:match('\nP%.title%s*=%s*"([^"\n,]+)"') or key
  end
  return plugin_titles[key]
end
local function open_with_items(path)
  local file = viewer_asset_files[path]
  if not file then return {} end
  local list, ext = {}, viewer_asset_ext(file)
  local f = io.open(file, 'rb')
  local head = f and f:read(4096) or ''
  if f then f:close() end
  if not head:find('\0', 1, true) then list[#list + 1] = { 'Text', 'text' } end
  local plug = viewer_asset_exts[ext]
  if plug then list[#list + 1] = { plugin_title(plug), plug } end
  if viewer_plugins_dir and require('fs').read(require('fs').join(viewer_plugins_dir, 'hexedit', 'editor.lua')) then
    list[#list + 1] = { plugin_title('hexedit'), 'hexedit' }
  end
  return list
end
local OPEN_TAB, OPEN_BESIDE = 'Open tab with', 'Open beside with'
function viewer_tree_menu(w, path)  -- its menu's items ("" : none)
  local items = {}
  local ways = {}
  for _, it in ipairs(open_with_items(path)) do ways[#ways + 1] = it[1] end
  if #ways > 0 then   -- (sub-lists: editor/tab.h)
    items[#items + 1] = OPEN_TAB .. '>' .. table.concat(ways, ',')
    items[#items + 1] = OPEN_BESIDE .. '>' .. table.concat(ways, ',')
  end
  for _, it in ipairs(new_items(w, path)) do items[#items + 1] = it[1] end
  if editable_node(w, path) then items[#items + 1] = 'Rename|Duplicate|Delete' end
  local last = viewer_history[#viewer_history]
  if last then items[#items + 1] = 'Undo ' .. (#last.what > 48 and (last.what:sub(1, 45) .. '...') or last.what) end
  return table.concat(items, '|')
end
function viewer_tree_delete_what(w, path, paths)  -- what Delete would remove, said for the question
  local list = chosen(w, path, paths)
  if #list > 1 then
    local files = 0
    for _, p in ipairs(list) do if asset_disk(w, p) then files = files + 1 end end
    return #list .. ' nodes (' .. table.concat(list, ', ') .. ')' .. (files > 0 and ('. ' .. files .. " of them: their files go to the game's .trash folder") or '')
  end
  if asset_disk(w, path) then return path .. ": its files go to the game's .trash folder (get them back from there)" end
  local below = #subtree(w, path) - 1
  local cname = path:match('^/classes/([^/]+)$')
  local users = 0
  for p, o in pairs(w.nodes) do if cname and o.c[cname] ~= nil and p:sub(1, 9) ~= '/classes/' then users = users + 1 end end
  return path .. (below > 0 and (' and the ' .. below .. ' node' .. (below > 1 and 's' or '') .. ' below it') or '')
         .. (users > 0 and ('. ' .. users .. ' node' .. (users > 1 and 's keep' or ' keeps') .. ' its ' .. cname .. ' component, without a class') or '')
end
function viewer_tree_action(w, path, item, paths)  -- New ..., Rename / Duplicate / Delete, Undo (paths: the selection)
  if tostring(item):sub(1, 5) == 'Undo ' then return viewer_tree_undo(w) end
  for _, it in ipairs(open_with_items(path)) do      -- (the editor opens it: "lite:" code, replay.c runs it there)
    if OPEN_TAB .. ':' .. it[1] == item then
      return true, string.format("lite:require('plugins.openwith').open(%q, %q)", it[2], viewer_asset_files[path])
    end
    if OPEN_BESIDE .. ':' .. it[1] == item then
      return true, string.format("lite:require('plugins.openwith').open_beside(%q, %q)", it[2], viewer_asset_files[path])
    end
  end
  for _, it in ipairs(new_items(w, path)) do
    if it[1] == item then viewer_select, viewer_rename = path, ecs.encode(it[2]) return true end
  end
  if not editable_node(w, path) then return false, path .. ": can't be changed" end
  local list = chosen(w, path, paths)
  if item == 'Rename' then  -- (several: one after another, each typed when the one before is done)
    viewer_rename_queue = {}
    for i = 2, #list do viewer_rename_queue[#viewer_rename_queue + 1] = list[i] end
    viewer_select, viewer_naming = list[1], list[1]
    viewer_rename = ecs.encode({ '?name' })
    return true
  end
  if item == 'Duplicate' then
    history_begin('duplicate ' .. (#list == 1 and path or (#list .. ' nodes')))
    if #list == 1 then
      local ok, err = node_duplicate(w, path)
      history_end()
      return ok, err
    end
    local made = {}
    for _, p in ipairs(list) do
      local ok, to = node_duplicate(w, p, true)
      if not ok then history_end() return false, to end
      made[#made + 1] = to
    end
    history_end()
    viewer_select, viewer_note = made[1], #made .. ' copies: ' .. table.concat(made, ', ')
    return true
  end
  if item == 'Delete' then
    history_begin('delete ' .. (#list == 1 and path or (#list .. ' nodes')))
    for _, p in ipairs(list) do
      local ok, err = node_delete(w, p)
      if not ok then history_end() return false, err end
    end
    history_end()
    if #list > 1 then viewer_note = #list .. ' deleted: ' .. table.concat(list, ', ') .. ". Undo: the tree's menu, or CTRL+Z over the tree" end
    return true
  end
  return false, 'nothing to do: ' .. tostring(item)
end
local function blank(text)
  local s = tostring(text):match('^%s*(.-)%s*$')
  return s == '' or s == 'none' or s == '-'
end
local function member_range(w, path, f, text)  -- min..max ("1..20", "0..", "..5"), or none
  local lo, hi = nil, nil
  if not blank(text) then
    local a, b = tostring(text):match('^%s*(%-?%d*%.?%d*)%s*%.%.%s*(%-?%d*%.?%d*)%s*$')
    lo, hi = a and tonumber(a), b and tonumber(b)
    if not a or (a ~= '' and not lo) or (b ~= '' and not hi) or (a == '' and b == '') then
      return false, 'a range: min..max (1..20, 0.., ..5), or none'
    end
  end
  return member_edit(w, path, f, function(d)
    d.min, d.max = lo, hi
    if lo and hi and lo > hi then return 'min is more than max' end
    if d.type == 'int' and ((lo and lo ~= math.floor(lo)) or (hi and hi ~= math.floor(hi))) then return 'an int: whole numbers' end
    if type(d.value) == 'number' then d.value = fit(d, d.value) end
  end)
end
local function member_options(w, path, f, text)  -- options: "a, b, c" (or none)
  local o = nil
  if not blank(text) then
    o = {}
    for part in tostring(text):gmatch('[^,|]+') do
      local x = part:match('^%s*(.-)%s*$')
      if x ~= '' then o[#o + 1] = x end
    end
  end
  return member_edit(w, path, f, function(d) d.options = o end)
end
local function class_new(w, text)  -- + class: "name" (or "name other": a copy of other's members)
  local name, from = tostring(text):match('^%s*([%a_][%w_]*)%s*([%w_]*)%s*$')
  if not name then return false, 'a name: letters, digits and _ (not first a digit)' end
  if RESERVED[name] then return false, name .. ': a reserved name' end
  if w:node('/classes/' .. name) then return false, '/classes/' .. name .. ' is already there' end
  local c = {}
  if from ~= '' then
    local b = w:node('/classes/' .. from)
    if not b then return false, 'no class ' .. from .. ' to copy' end
    c = ecs.copy(b.c)
  end
  w:spawn('/classes/' .. name, c)
  viewer_select = '/classes/' .. name
  viewer_note = '/classes/' .. name .. (from ~= '' and (': a copy of ' .. from .. "'s members") or ': new') .. '. + member adds one'
  return true
end
local function parse_key(w, d, text)  -- a set's / map's key, typed: as its type
  local k = text
  if NUMS[d.type] then k = tonumber(text)
  elseif d.type == 'bool' then k = ({ ['true'] = true, ['false'] = false })[text]
  elseif PRIM[d.type] ~= 'string' then return nil, 'keys of type ' .. d.type .. ': not yet' end
  if k == nil then return nil, 'a key: a ' .. d.type end
  return check_value(w, { type = d.type, min = d.min, max = d.max, options = d.options }, k, 'key')
end
local function item_key(w, paths, keys, text)  -- + key (a set or a map): the key typed
  local tk = {}
  for i = 2, #keys do tk[#tk + 1] = keys[i] end
  for _, p in ipairs(paths) do
    local n = not ecs.is_builtin(p) and w:node(p)
    local d = n and view_at(w, n, tk)
    if not d or not d.container then return false, 'not a set or a map' end
    local k, err = parse_key(w, d, text)
    if k == nil then return false, err end
    with_class(w, p, function()
      local t = node_table(w, n, tk)
      if t and t[k] == nil then t[k] = d.container == 'set' or default_for(w, { type = d.values or 'bool' }) end
    end)
  end
  return true
end
function viewer_prop_set(w, paths, id, text, kind)  -- -> ok, err
  local keys = ecs.decode(id) or {}
  local k1, p1 = keys[1], paths[1]
  if k1 == '?member' then return member_add(w, p1, text) end
  if k1 == '?class' then return class_new(w, text) end
  if k1 == '?new' then return node_new(w, p1, text) end
  if k1 == '?folder' then return asset_new_folder(w, p1, text) end
  if k1 == '?asset' then return asset_new(w, p1, keys[2], text) end
  if k1 == '?doc' then return doc_new(w, p1, text) end
  if k1 == '?name' then return node_rename(w, p1, text) end
  if k1 == '?m' then return member_rename(w, p1, keys[2], text) end
  if k1 == '?range' then return member_range(w, p1, keys[2], text) end
  if k1 == '?options' then return member_options(w, p1, keys[2], text) end
  if k1 == '?key' then return item_key(w, paths, keys, text) end
  if p1 and ecs.is_builtin(p1) then return false, p1 .. ': built in (a plain type), not editable' end
  local v
  if kind == 'str' then v = text
  else
    local val, err = ecs.decode('return ' .. text, 'value')
    if err then return false, err end
    if val == nil then return false, 'empty value' end
    v = val
  end
  local ok, err = pcall(ecs.serialize, v)
  if not ok then return false, err end
  local n = p1 and w:node(p1)
  local d = n and view_at(w, n, keys)
  if d and (COLOR[d.type] or VEC[d.type]) and type(v) == 'number' then  -- (typed without braces: 255, 0, 0 / 1, 2, 3)
    local t2 = ecs.decode('return { ' .. text .. ' }', 'value')
    if type(t2) == 'table' then v = t2 end
  end
  if d then
    local err2
    v, err2 = check_value(w, d, v, tostring(keys[#keys]))
    if v == nil then return false, err2 end
  end
  prop_assign(w, paths, id, function() return type(v) == 'table' and ecs.decode(ecs.encode(v)) or v end)
  return true
end
-- a pick from a drop-down: on a member's row (which: 'type', 'kind' --
-- "var", "[] array", "() set", "{} map:<values' type>" -- or its menu: Remove;
-- Rename is typed: C starts it), or a value's option
local function pick_type(w, p1, f, item)
  if not w:node('/classes/' .. tostring(item)) then return false, 'no class ' .. tostring(item) end
  if item == class_of_path(p1 or '') then return false, "a class can't be a member of itself" end
  return member_edit(w, p1, f, function(d) d.type = item end)
end
local function pick_kind(w, p1, f, item)  -- "var" (one value; "single" too), "[] array", "() set", "{} map:<values' type>"
  local word, values = tostring(item):match('(%a+)'), tostring(item):match(':(.+)$')
  if word == 'map' and not values then return false, "a map: pick its values' type" end
  if values and not w:node('/classes/' .. values) then return false, 'no class ' .. values end
  return member_edit(w, p1, f, function(d)
    if word == 'map' then d.container, d.values = 'map', values
    else d.container = (word == 'array' or word == 'set') and word or nil end
  end)
end
function viewer_prop_pick(w, paths, id, item, which)
  local keys = ecs.decode(id) or {}
  local k1, f, p1 = keys[1], keys[2], paths[1]
  if k1 == '?m' then
    if which == 'type' then return pick_type(w, p1, f, item) end
    if which == 'kind' then return pick_kind(w, p1, f, item) end
    if item == 'Remove' then return member_remove(w, p1, f) end
    return false, 'nothing to do: ' .. tostring(item)
  end
  if k1 == '?add' then  -- (+ component: a class picked, or a plain type: a named field)
    if ecs.BUILTIN[item] ~= nil then return field_add(w, paths, item) end
    return viewer_prop_add_class(w, paths, ecs.encode({ '?add', item }))
  end
  return viewer_prop_set(w, paths, id, item, 'str')
end
function viewer_prop_add(w, paths, id, dv)  -- numbers: += dv on each node (kept to its member)
  local keys = ecs.decode(id)
  local n = paths[1] and w:node(paths[1])
  local d = keys and n and view_at(w, n, keys)
  prop_assign(w, paths, id, function(old)
    if type(old) ~= 'number' then return nil end
    if d then return fit(d, old + dv) end
    return old + dv
  end)
end
function viewer_prop_slide(w, paths, id, f)  -- a slider at f (0..1 of min..max)
  local keys = ecs.decode(id)
  local n = paths[1] and w:node(paths[1])
  local d = keys and n and view_at(w, n, keys)
  if not d or not type_spec(d, w) or type_spec(d, w):sub(1, 5) ~= 'range' then return false end
  local lo, hi = range_of(d)
  local v = lo + math.max(0, math.min(1, f)) * (hi - lo)
  if d.type ~= 'int' then  -- (steps of a hundredth of the range, rounded: 0..10 -> 0.1)
    local step = 10 ^ math.floor(math.log((hi - lo) / 100) / math.log(10) + 1e-9)
    v = tonumber(string.format('%.10g', math.floor(v / step + 0.5) * step))
  end
  v = fit(d, v)
  prop_assign(w, paths, id, function() return v end)
  return true
end
function viewer_prop_cycle(w, paths, id, dir)  -- options: the next one (dir -1: the one before)
  local keys = ecs.decode(id)
  local n = paths[1] and w:node(paths[1])
  local d = keys and n and view_at(w, n, keys)
  local list = type_spec(d, w) == 'choice' and choices(w, d)
  if not list then return false end
  prop_assign(w, paths, id, function(old)
    local i = 0
    for k, o in ipairs(list) do if o == old then i = k end end
    local v = list[(i - 1 + (dir or 1)) % #list + 1]
    return v == 'none' and (d.type == 'asset' or d.type == 'node') and '' or v
  end)
  return true
end
function viewer_prop_add_class(w, paths, id)  -- + a component from its class (its members' values), or + item (an array)
  local keys = ecs.decode(id) or {}
  if keys[1] == '?item' then
    local tk = {}
    for i = 2, #keys do tk[#tk + 1] = keys[i] end
    for _, p in ipairs(paths) do
      local n = not ecs.is_builtin(p) and w:node(p)
      local d = n and view_at(w, n, tk)
      if d and d.container == 'array' then
        with_class(w, p, function()
          local t = node_table(w, n, tk)
          if t then t[#t + 1] = default_for(w, element(d)) end
        end)
      end
    end
    return true
  end
  local c = w:node('/classes/' .. tostring(keys[2]))
  if not c then return false, 'no such class' end
  for _, p in ipairs(paths) do
    local n = w:node(p)
    if n and n.c[keys[2]] == nil then
      local t = {}
      for f, d in pairs(c.c) do t[f] = ecs.start_value(ecs.member(d)) end
      n.c[keys[2]] = t
    end
  end
  return true
end
function viewer_prop_remove(w, paths, id)  -- RMB on an element (cls 'e'): out of its collection
  local keys = ecs.decode(id) or {}
  local tk = {}
  for i = 1, #keys - 1 do tk[i] = keys[i] end
  local k = keys[#keys]
  for _, p in ipairs(paths) do
    local n = not ecs.is_builtin(p) and w:node(p)
    local d = n and view_at(w, n, tk)
    if d and d.container then
      with_class(w, p, function()
        local t = node_table(w, n, tk)
        if t and d.container == 'array' and type(k) == 'number' then table.remove(t, k)
        elseif t then t[k] = nil end
      end)
    end
  end
  return true
end
function viewer_prop_revert(w, paths, id)  -- back to the script's value (or gone)
  local sw = viewer_script_world()
  if not sw then return false, 'not a script world' end
  local keys = assert(ecs.decode(id))
  for _, p in ipairs(paths) do
    local n, sn = w:node(p), sw:node(p)
    with_class(w, p, function()
      local sk = n and store(n, keys)
      local t = n and n.c
      for i = 1, sk and #sk - 1 or 0 do t = type(t) == 'table' and t[sk[i]] or nil end
      if type(t) == 'table' then
        local v = sn and get(sn, keys)
        if type(v) == 'table' then v = ecs.decode(ecs.encode(v)) end
        t[sk[#sk]] = v
      end
    end)
  end
  return true
end
function viewer_prop_class_revert(w, paths, id)  -- back to its class's value
  local keys = assert(ecs.decode(id))
  for _, p in ipairs(paths) do
    local n = w:node(p)
    local d = n and class_value(w, n, keys)
    local t = n and type(n.c[keys[1]]) == 'table' and n.c[keys[1]]
    if d ~= nil and t then t[keys[2]] = d end
  end
  return true
end
function viewer_prop_toggle(w, paths, id)
  prop_assign(w, paths, id, function(old) if type(old) == 'boolean' then return not old end end)
end
function viewer_components(w, path)
  local n = w:node(path)
  if not n then return nil end
  local keys = {}
  for k in pairs(n.c) do keys[#keys + 1] = tostring(k) end
  table.sort(keys)
  return keys
end
-- Where is a node written on disk? -> { {file=, line=}, ... }, folder
-- folder world: the node's component leaves (<node>/<component>.lua)
-- script/blob:  the file, at the line that names the node (or the
-- string it is built from, e.g. "/fleet/ship" .. i,
-- or its nearest named parent)
local function find_line(file, needles)
  local f = io.open(file, 'rb')
  if not f then return 1 end
  local lines = {}
  local inblock = false  -- comments don't count: code only
  for l in f:lines() do
    local code = l
    if inblock then
      local e = l:find(']]', 1, true)
      if e then inblock = false; code = l:sub(e + 2) else code = '' end
    end
    local c = code:find('--', 1, true)
    if c then
      if code:sub(c, c + 3):match('^%-%-%[=*%[') and not code:find(']]', c, true) then inblock = true end
      code = code:sub(1, c - 1)
    end
    lines[#lines + 1] = code
  end
  f:close()
  for _, needle in ipairs(needles) do
    for i, l in ipairs(lines) do
      if l:find(needle, 1, true) then return i end
    end
  end
  return 1
end
-- folder worlds: the file of one component (a code leaf), or nil
function viewer_leaf(path, comp)
  if not viewer_disk then return nil end
  local fs = require('fs')
  local base = fs.join(viewer_disk:dir(path), require('disk').encode(comp))
  for lang in pairs(ecs.languages) do  -- name.hurdy, if that is the leaf
    if fs.read(base .. '.' .. lang) then return base .. '.' .. lang end
  end
  return base .. '.lua'
end
function viewer_source(w, path)
  if viewer_asset_files[path] then return { { file = viewer_asset_files[path], line = 1 } }, viewer_asset_files[path]:match('^(.*)[/\\]') end  -- (an asset file: in its plugin)
  local pdir = path:match('^/plugins/[^/]+$') and viewer_plugins_dir and require('fs').join(viewer_plugins_dir, path:sub(10))
  if viewer_disk or pdir then
    local fs = require('fs')
    local dir = pdir or viewer_disk:dir(path)  -- (a plugin: its folder's files, its editor.lua too)
    local out = {}
    for _, e in ipairs(fs.list(dir)) do
      local ext = e.name:match('%.(%w+)$')
      if not e.dir and (ext == 'lua' or ecs.languages[ext]) then
        out[#out + 1] = { file = fs.join(dir, e.name), line = 1 }
      end
    end
    return out, dir
  end
  local needles, p = {}, path
  while p and p ~= '' do
    for _, q in ipairs({ '"', "'" }) do
      needles[#needles + 1] = q .. p .. q
      needles[#needles + 1] = q .. p .. '/'  -- a parent made by its children: the first child

      local stem = p:match('^(.-)%d+$')
      if stem and stem ~= '' then needles[#needles + 1] = q .. stem .. q end
    end
    p = p:match('^(.*)/[^/]+$')
  end
  return { { file = viewer_file, line = find_line(viewer_file, needles) } }, viewer_file
end

-- One undo for everything (the tree's stack, viewer_history): every
-- property edit and every move in the game view is a level too, kept in
-- memory only ({ 'comps', { { path, component, value before }... } }: undo
-- puts those components back). The same edit again within a second or so
-- (a slider dragged, a number nudged) joins its level. Stop drops the levels
-- made while playing.
local pack = table.pack or function(...) return { n = select('#', ...), ... } end
local unpack = table.unpack or unpack
local function comps_of(w, paths)  -- { [path] = { [name] = { text, copy } } }
  local snap = {}
  for _, p in ipairs(paths) do
    local n = not snap[p] and w:node(p)
    if n then
      local c = {}
      for k, v in pairs(n.c) do
        local ok, txt = pcall(ecs.serialize, v)
        c[k] = { ok and txt or tostring(v), ok and ecs.copy(v) or v }
      end
      snap[p] = c
    end
  end
  return snap
end
local last_edit  -- { key, t, r }: the last edit's level (joined by the same edit, soon)
local function edits_record(w, snap, what, key)
  local list = {}
  for p, before in pairs(snap) do
    local n = w:node(p)
    if n then
      local names = {}
      for k in pairs(before) do names[k] = true end
      for k in pairs(n.c) do names[k] = true end
      for k in pairs(names) do
        local b, now = before[k], n.c[k]
        local ok, txt = true, nil
        if now ~= nil then ok, txt = pcall(ecs.serialize, now) end
        if not ok or (b and b[1]) ~= txt then list[#list + 1] = { p, k, b and b[2] } end
      end
    end
  end
  if #list == 0 then return false end
  table.sort(list, function(a, b) return a[1] < b[1] or (a[1] == b[1] and tostring(a[2]) < tostring(b[2])) end)
  local top, now = viewer_history[#viewer_history], os.time()
  if last_edit and last_edit.r == top and last_edit.key == key and now - last_edit.t <= 1 then
    local have = {}                                -- (joined: its first values stay)
    for _, c in ipairs(top.steps[1][2]) do have[c[1] .. '\0' .. tostring(c[2])] = true end
    for _, c in ipairs(list) do if not have[c[1] .. '\0' .. tostring(c[2])] then table.insert(top.steps[1][2], c) end end
    last_edit.t = now
    return true
  end
  local r = { what = what, steps = { { 'comps', list } }, mem = true, level = #viewer_history + 1 }
  viewer_history[#viewer_history + 1] = r
  last_edit = { key = key, t = now, r = r }
  return true
end
local function edit_scope(w, paths, keys)          -- the nodes an edit can change: the selection; a class's: all
  local all = type(keys) == 'table' and type(keys[1]) == 'string' and keys[1]:sub(1, 1) == '?'
  for _, p in ipairs(paths or {}) do if p == '/classes' or p:sub(1, 9) == '/classes/' then all = true end end
  if not all then return paths or {} end
  local list = {}
  for p in pairs(w.nodes) do list[#list + 1] = p end
  return list
end
for _, name in ipairs({ 'viewer_prop_set', 'viewer_prop_pick', 'viewer_prop_add', 'viewer_prop_slide', 'viewer_prop_cycle',
                        'viewer_prop_add_class', 'viewer_prop_remove', 'viewer_prop_revert', 'viewer_prop_class_revert',
                        'viewer_prop_toggle' }) do
  local f = _G[name]
  _G[name] = function(w, paths, id, ...)
    local keys = ecs.decode(id or '') or {}
    local depth = #viewer_history
    local snap = comps_of(w, edit_scope(w, paths, keys))
    local r = pack(f(w, paths, id, ...))
    if #viewer_history == depth then             -- (an edit that keeps its own level, New or Rename: not twice)
      local field = {}
      for _, k in ipairs(keys) do field[#field + 1] = tostring(k) end
      local what = 'edit ' .. tostring(paths and paths[1] or '?') .. ((paths and #paths > 1) and (' (+' .. (#paths - 1) .. ')') or '')
                   .. (#field > 0 and (' .' .. table.concat(field, '.')) or '')
      edits_record(w, snap, what, name .. '|' .. tostring(id) .. '|' .. table.concat(paths or {}, ','))
    end
    return unpack(r, 1, r.n)
  end
end

-- Moving a node in the game view (replay.c: LMB drag on it while stopped or
-- paused; Alt: turn it; the wheel while dragging: scale it): its xform,
-- one undo level per drag. dx, dy: world units (into its parent's space
-- here: the parents' turn and scale undone), dr: radians, ds: a factor.
local moving  -- { path, snap }
function viewer_move_begin(w, path)  -- -> ok
  local n = path and w:node(path)
  if not n or ecs.is_builtin(path) then return false end
  if n.c.xform ~= nil and type(n.c.xform) ~= 'table' then return false end
  moving = { path = path, snap = comps_of(w, { path }) }
  return true
end
function viewer_move_by(w, dx, dy, dr, ds)
  local n = moving and w:node(moving.path)
  if not n then return false end
  local xf = n.c.xform
  if type(xf) ~= 'table' then xf = { x = 0, y = 0 }; n.c.xform = xf end
  local r, sx, sy = 0, 1, 1                        -- (its parents' turn and scale)
  local p = parent_of(moving.path)
  while p do
    local px = w:node(p) and w:node(p).c.xform
    if type(px) == 'table' then
      r = r + (tonumber(px.r) or 0)
      sx, sy = sx * (tonumber(px.sx) or tonumber(px.s) or 1), sy * (tonumber(px.sy) or tonumber(px.s) or 1)
    end
    p = parent_of(p)
  end
  if (dx or 0) ~= 0 or (dy or 0) ~= 0 then
    local c, s = math.cos(-r), math.sin(-r)
    xf.x = (tonumber(xf.x) or 0) + (dx * c - dy * s) / (sx ~= 0 and sx or 1)
    xf.y = (tonumber(xf.y) or 0) + (dx * s + dy * c) / (sy ~= 0 and sy or 1)
  end
  if (dr or 0) ~= 0 then xf.r = (tonumber(xf.r) or 0) + dr end
  if ds and ds ~= 1 then
    if xf.sx or xf.sy then xf.sx, xf.sy = (tonumber(xf.sx) or tonumber(xf.s) or 1) * ds, (tonumber(xf.sy) or tonumber(xf.s) or 1) * ds
    else xf.s = (tonumber(xf.s) or 1) * ds end
  end
  return true
end
function viewer_move_end(w)  -- -> moved?
  local m = moving
  moving = nil
  local n = m and w:node(m.path)
  if not n then return false end
  local xf = n.c.xform
  if type(xf) == 'table' then                      -- (tidy numbers: what's saved)
    local function round(v, q) return v and tonumber(v) and math.floor(v / q + 0.5) * q or v end
    xf.x, xf.y = round(xf.x, 0.01), round(xf.y, 0.01)
    if xf.r then xf.r = round(xf.r, 0.0001) end
    for _, k in ipairs({ 's', 'sx', 'sy' }) do if xf[k] then xf[k] = round(xf[k], 0.001) end end
  end
  local moved = edits_record(w, m.snap, 'move ' .. m.path, 'move|' .. m.path .. '|' .. tostring(os.clock()))
  if moved then viewer_note = 'moved ' .. m.path .. ': Save writes it; CTRL+Z undoes it' end
  return moved
end
