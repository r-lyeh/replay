-- ecs.lua
-- Minimal Entity-Component-System where every entity is a node in a tree.
--
--   * Nodes are addressed by URL-like paths: "/game/players/mario"
--   * Components are plain data tables stored on a node (no functions),
--     so any part of the world can be saved, loaded and diffed.
--   * Systems are named functions over nodes that own a set of components.
--     Re-registering a system with the same name replaces it in place,
--     which is what makes hot-reloading possible.
--   * Path patterns select parts of the tree:
--       "/game/hello"      exactly that node
--       "/game/*"          direct children of /game
--       "/game/**"         /game and everything below it
--       "/**"              the whole world
--       "/game/p*/m?rio"   * and ? also work inside a segment
--
-- Main API:
--   local w = ecs.world()
--   ok, blob  = ecs.save(w, "/**")        -- serialize matching nodes
--   ok, w     = ecs.load(blob, "/", w)    -- apply blob under a mount point
--                                         -- (w optional: new world if nil)
--   ok, patch = ecs.diff(a, b)            -- blobs or worlds -> patch a->b
--   ok, w     = ecs.patch(patch, "/", w)  -- same as ecs.load
--   ecs.tick(w, "/**", dt)                -- run systems on matching nodes
--
-- Code leaves: a component made with ecs.code(src) is Lua source stored as
-- data ({ __lua = src }), so it saves, diffs and replicates like any other
-- component. Every tick, code components become systems named after their
-- node path + component ("/game/systems/move"); changed source hot-swaps
-- the system (same run-order slot), a removed component removes it. The
-- source runs in a sandbox (math/string/table, no io/os/load/require) and
-- returns either
--   function(w, dt) ... end                         -- once per tick, or
--   { requires = { "pos", "vel" }, run = function(w, node, dt) ... end }
-- Code systems run in the order of the root's `order` list (see rank_of),
-- then by name.
-- The table form may also (or only) have on_key = function(w, key, down, player):
-- w:key(key, down, player) delivers input to every such handler (and to
-- w.on_key); player: who pressed it, 1..4 (1 when not given).
--
-- Players (set by the host, not data): w.players = the players in the game,
-- a set ({ [1] = true, [3] = true }; nil: player 1 alone), w.peer = which one
-- this world is (nil: not in a network session). A node tagged
-- `replicate = true` (the host's, player 1), `replicate = N` (player N's) or
-- `replicate = { by = N, predict = true }` is simulated by its owner (a
-- player not in the game: the host): with w.peer set, per-node systems skip
-- the nodes (and their subtrees) another player owns, unless they're
-- predicted (then everyone simulates them, and the owner's state corrects
-- the guess: net.peer).
-- A compile error keeps the previous version running; a runtime error
-- stops only that system until its source changes. Errors: w.code_err.
-- Other languages: ecs.code(src, "hurdy") is { __hurdy = src }, compiled to
-- Lua by ecs.languages.hurdy (runtime/hurdyl); errors point at hurdy lines.
-- Modules: a code leaf named `module` isn't a system; code leaves load it
-- with require ("space" is /data/lib/space's module; a path works too).
-- Editing one rebuilds the systems that use it. w:owns(node): does this
-- world decide for that node (its replicate tag, or a parent's), or guess?
-- The same calls exist as methods: w:save(pat), w:load(blob, at), w:tick(pat, dt)
--
-- The layout (a world with /systems, /objects or /entities at its root
-- follows it), its roots in this order:
--   /config             the project's settings: its components (config/*.lua),
--                       read by the viewer, e.g. window = { w =, h =, title = }
--                       (the game area's size, the window's title)
--   /docs/...           the game's documents: docs/**/*.md (and .txt) files,
--                       shown as /docs/.../<name>.md (ecs.is_file: never saved)
--   /assets/...         asset folders (files, not world data). A folder
--                       world's assets/ files that a plugin opens show as
--                       /assets/.../<name>.<ext> (ecs.is_file: never saved)
--   /data/...           everything else: rules, state, tables
--   /saves/<name>.sav   savegames (files, like assets): w:savegame(name, t)
--                       writes one, w:loadgame(name) reads it back
--   /classes/<name>     the component <name>: its members, each described
--                       (w:spawn fills a table component's missing fields
--                       with their values; ecs.member):
--                         hp   = { type = "int", value = 10, min = 1, max = 20 }
--                         mode = { type = "string", value = "slow", options = { "slow", "fast" } }
--                         path = { type = "number", container = "array", value = {} }
--                         hits = { type = "string", container = "map", values = "int", value = {} }
--                       type: a class's name; container: none (one value),
--                       "array", "set" ({ [k] = true }) or "map" (keys of
--                       `type`, values of `values`: never a collection);
--                       min / max (int, number), options (string): the value's
--                       (each element's; not a map's). A plain value is short
--                       for one: life = 1.5. Edited, a class upgrades its
--                       nodes' values that were never overridden:
--                       w:upgrade_class(name, before)
--   /classes/bool, int, number, angle, string, key, asset, node, vec2,
--                       vec3, vec4, quat, rect, color3, color4: built in
--                       (w:builtins()), the plain types (ecs.BUILTIN: what
--                       such a member starts with). Never saved (every copy
--                       of the program has them), no component's defaults (a
--                       `rect` component isn't one). "color" (3 or 4) is
--                       still understood, not listed
--   /objects/...        placed in the editor, saved
--   /systems/<name>     a system per node: its code in a `system` component;
--                       the `order` component of /systems lists names: the
--                       run order
--   /entities/...       spawned while playing, never written to disk
--   /tmp/...            temporaries: never saved, sent, nor kept by the timeline
--   /plugins/<name>     the editor's plugins (the viewer mounts each folder of
--                       plugins/ there: its data leaves, e.g. which files it
--                       opens, its config). Like /tmp: never saved with the
--                       world, sent nor kept; the viewer saves them to their
--                       folders
-- Only /objects and /entities are live: per-node systems run on their nodes,
-- and the viewer draws and picks only them. /tmp is left out of every save
-- (and so of diffs, snapshots and replication) and survives every load.
-- /entities is in saves (the timeline, replication) but not in disk saves:
-- w:save(pat, true) (and disk.lua) leave it out, so Stop and quitting lose it.
--
-- Works on Lua 5.1+ and LuaJIT.

local ecs = {}
local VERSION = 1

local unpack  = unpack or table.unpack
-- a deep copy of plain data
function ecs.copy(v)
  if type(v) ~= "table" then return v end
  local o = {}
  for k, x in pairs(v) do o[k] = ecs.copy(x) end
  return o
end
local lua_load, loadstring, setfenv = load, loadstring, setfenv

local World = {}
World.__index = World

---------------------------------------------------------------------------
-- paths
---------------------------------------------------------------------------

-- "/game//players/" -> "/game/players", { "game", "players" }
local function normalize(path)
  assert(type(path) == "string", "path must be a string")
  local parts = {}
  for part in path:gmatch("[^/]+") do parts[#parts + 1] = part end
  return "/" .. table.concat(parts, "/"), parts
end
ecs.normalize = normalize

local function join(base, name)
  if base == "/" then return "/" .. name end
  return base .. "/" .. name
end

-- mount("/backup", "/game/hello") -> "/backup/game/hello"
local function mount(at, path)
  local a = normalize(at)
  local p = normalize(path)
  if a == "/" then return p end
  if p == "/" then return a end
  return a .. p
end

local function parent_of(path)
  if path == "/" then return nil end
  local p = path:match("^(.*)/[^/]*$")
  return (p == "" or p == nil) and "/" or p
end

---------------------------------------------------------------------------
-- glob patterns
---------------------------------------------------------------------------

local compile_now, has_code
local function has_wild(seg) return seg:find("[%*%?]") ~= nil end

-- one path segment with * and ? -> anchored Lua pattern
local function seg_pattern(seg)
  local p = seg:gsub("[%^%$%(%)%%%.%[%]%+%-]", "%%%0")
  p = p:gsub("%*", ".*"):gsub("%?", ".")
  return "^" .. p .. "$"
end

local compiled, ncompiled = {}, 0                 -- (patterns are few: each compiled once)
local function compile(pattern)
  local c = compiled[pattern]
  if c then return c[1], c[2] end
  if ncompiled > 2000 then compiled, ncompiled = {}, 0 end
  local pat, segs = compile_now(pattern)
  compiled[pattern], ncompiled = { pat, segs }, ncompiled + 1
  return pat, segs
end
compile_now = function(pattern)
  local _, segs = normalize(pattern)
  local pat = {}
  for i, s in ipairs(segs) do
    if s == "**" then pat[i] = "**"
    elseif has_wild(s) then pat[i] = seg_pattern(s)
    else pat[i] = { s } end  -- literal
  end
  return pat, segs
end

local function match(pat, i, segs, j)
  if i > #pat then return j > #segs end
  local p = pat[i]
  if p == "**" then
    for k = j, #segs + 1 do
      if match(pat, i + 1, segs, k) then return true end
    end
    return false
  end
  if j > #segs then return false end
  local ok
  if type(p) == "table" then ok = (p[1] == segs[j]) else ok = segs[j]:find(p) ~= nil end
  return ok and match(pat, i + 1, segs, j + 1)
end

-- Does a path match a pattern?
function ecs.match(pattern, path)
  local pat = compile(pattern)
  local _, segs = normalize(path)
  return match(pat, 1, segs, 1)
end

---------------------------------------------------------------------------
-- world
---------------------------------------------------------------------------

function ecs.world()
  local w = setmetatable({
    nodes   = {},  -- path -> node
    systems = {},  -- name -> system
    order   = {},  -- system names, in run order
    frame   = 0,   -- number of ticks so far
    code_err = {}, -- code system name -> last error (see ecs.code)
    _code_dirty = true, -- (code to look for at the next tick)
  }, World)
  w.root = { path = "/", name = "", parent = nil, children = {}, c = {} }
  w.nodes["/"] = w.root
  return w
end

-- (has a component that is code? ecs.code_source is defined further down)
has_code = function(c)
  if type(c) ~= "table" then return false end
  for _, v in pairs(c) do if ecs.code_source(v) then return true end end
  return false
end

-- Get a node by path (or nil).
function World:node(path)
  return self.nodes[(normalize(path))]
end

-- Create a node (and any missing parents, like `mkdir -p`).
-- Optional `components` table is merged onto the node.
function World:spawn(path, components)
  local _, parts = normalize(path)
  local cur = self.root
  for i = 1, #parts do
    local name = parts[i]
    local child = cur.children[name]
    if not child then
      child = { path = join(cur.path, name), name = name,
                parent = cur, children = {}, c = {} }
      cur.children[name] = child
      self.nodes[child.path] = child
      self._gen = (self._gen or 0) + 1            -- (the tree changed: World:_sorted rebuilds)
    end
    cur = child
  end
  if components then
    for k, v in pairs(components) do cur.c[k] = v end
    if has_code(components) then self._code_dirty = true end
    local defs = self.nodes["/classes"]            -- the layout's /classes/<name>: a component's defaults
    if defs and cur.path:sub(1, 9) ~= "/classes/" then
      for k, v in pairs(components) do
        local d = type(v) == "table" and not ecs.is_code(v) and ecs.BUILTIN[k] == nil and defs.children[k]
        if d then
          for f, dv in pairs(d.c) do
            if v[f] == nil and f ~= "meta" then v[f] = ecs.start_value(ecs.member(dv)) end   -- (meta: reserved, a node's own types)
          end
        end
      end
    end
  end
  return cur
end

-- Remove a node and its whole subtree.
function World:remove(path)
  local node = self:node(path)
  if not node or node == self.root then return false end
  local function drop(n)
    for _, ch in pairs(n.children) do drop(ch) end
    if has_code(n.c) then self._code_dirty = true end   -- (a system went: sync_code drops it)
    self.nodes[n.path] = nil
  end
  drop(node)
  node.parent.children[node.name] = nil
  self._gen = (self._gen or 0) + 1
  return true
end

local function resolve(self, target)
  if type(target) == "string" then
    return self:node(target) or error("no such node: " .. target)
  end
  return target
end

-- Components ----------------------------------------------------------------

function World:set(target, name, value)
  resolve(self, target).c[name] = value
  if ecs.code_source(value) then self._code_dirty = true end
  self._shape = (self._shape or 0) + 1             -- (the systems' lists: looked at again)
end

function World:get(target, name)
  local n = type(target) == "string" and self:node(target) or target
  return n and n.c[name]
end

function World:unset(target, name)
  resolve(self, target).c[name] = nil
  self._shape = (self._shape or 0) + 1
end

-- Queries -------------------------------------------------------------------

-- Children of a node, sorted by name (deterministic order matters for p2p).
-- Ordering: the root node's `order` component is a list of paths or globs
-- (order.lua at the top of a world folder):
--   return { "/scene/sun", "/scene/**/ship*", "/game/systems/paddles" }
-- An entry's rank is the first line that matches its path; siblings (and
-- code systems) sort by rank, then by name. Unlisted ones come after.
local HUGE = math.huge
local ROOTS = { "/config", "/docs", "/assets", "/data", "/classes", "/objects", "/systems", "/entities", "/saves", "/tmp", "/plugins" }   -- (the layout's roots, in this order)
ecs.ROOTS = ROOTS
-- (what the ranks depend on, as a string: the sorted order is kept while it stays)
local function joined(t)
  if type(t) ~= "table" then return "" end
  local ok, s = pcall(table.concat, t, "\n")      -- (names: strings; anything else, one by one)
  if ok then return s end
  local o = {}
  for i, x in ipairs(t) do o[i] = tostring(x) end
  return table.concat(o, "\n")
end
function World:_ranks_key()
  local s = self.nodes["/systems"]
  return joined(self.root.c.order) .. "|" .. joined(s and s.c.order) .. (self:layout() and "|L" or "|")
end

function World:rank_of()
  local list = {}
  for _, x in ipairs(type(self.root.c.order) == "table" and self.root.c.order or {}) do list[#list + 1] = x end
  local s = self.nodes["/systems"]
  if s and type(s.c.order) == "table" then         -- /s's order: system names, the run order
    for _, name in ipairs(s.c.order) do
      if type(name) == "string" then list[#list + 1] = name:sub(1, 1) == "/" and name or ("/systems/" .. name .. "/**") end
    end
  end
  if self:layout() then for _, r in ipairs(ROOTS) do list[#list + 1] = r end end
  if #list == 0 then return function() return HUGE end end
  local key = table.concat(list, "\n")
  if self._rank_key ~= key then                    -- the list changed: new cache
    self._rank_key, self._rank_memo = key, {}
  end
  local memo = self._rank_memo
  return function(path)
    local r = memo[path]
    if r == nil then
      self._rank_n = (self._rank_n or 0) + 1      -- (paths come and go, sparks by the hundred: start over now and then)
      if self._rank_n > 20000 then memo = {}; self._rank_memo, self._rank_n = memo, 0 end
      r = HUGE
      for i, pat in ipairs(list) do
        if type(pat) == "string" and ecs.match(pat, path) then r = i break end
      end
      memo[path] = r
    end
    return r
  end
end

-- is `path` `root` or under it?
local function under(path, root) return path == root or path:sub(1, #root + 1) == root .. "/" end

-- Does this world follow the layout (/systems, /objects or /entities at its root)?
function World:layout()
  local k = self.root.children
  return (k.systems or k.objects or k.entities) ~= nil
end
-- Is this path live (simulated, drawn): under /objects or /entities (any
-- path when the world doesn't follow the layout)
function World:live(path)
  if not self:layout() then return true end
  return under(path, "/objects") or under(path, "/entities")
end
local function is_tmp(path) return under(path, "/tmp") end
ecs.is_tmp = is_tmp
-- The built-in classes: the plain types (see the layout above)
ecs.BUILTIN = {
  bool = false, int = 0, number = 0, angle = 0, string = "",   -- (angle: degrees)
  key = "space", asset = "", node = "",                          -- (a key's name, an /assets path, a node's path; "": none)
  vec2 = { x = 0, y = 0 }, vec3 = { x = 0, y = 0, z = 0 }, vec4 = { x = 0, y = 0, z = 0, w = 0 },
  quat = { x = 0, y = 0, z = 0, w = 1 }, rect = { x = 0, y = 0, w = 1, h = 1 },
  color3 = { 255, 255, 255 }, color4 = { 255, 255, 255, 255 },
}
local function is_builtin(path)
  local name = path:match("^/classes/([^/]+)")
  return name ~= nil and ecs.BUILTIN[name] ~= nil
end
ecs.is_builtin = is_builtin
-- add them (a world that follows the layout): /classes/<type>, no members
function World:builtins()
  if not self:layout() then return end
  if not self.nodes["/classes"] then self.auto_classes = true end   -- (made for them: not the game's, until it has a class)
  for name in pairs(ecs.BUILTIN) do
    if not self.nodes["/classes/" .. name] then self:spawn("/classes/" .. name) end
  end
end
-- A class member's description (see the layout above): d itself, or for a
-- plain value (short for one) { type = its type, value = d }
local TYPE_OF = { number = "number", string = "string", boolean = "bool", table = "table" }
function ecs.member(d)
  if type(d) == "table" and type(d.type) == "string" then return d end
  return { type = TYPE_OF[type(d)] or "table", value = d }
end
-- what a member starts with: (a copy of) its value, else {} (a collection)
-- or its plain type's
function ecs.start_value(m)
  if m.value ~= nil then return ecs.copy(m.value) end
  if m.container then return {} end
  return ecs.copy(ecs.BUILTIN[m.type] or (m.type == "color" and { 255, 255, 255 } or nil))
end
-- the editor's plugins (the viewer mounts plugins/<name>/ folders there):
-- never saved with the world (the viewer saves them to their folders)
local function is_plugin(path) return under(path, "/plugins") end
ecs.is_plugin = is_plugin
-- a game's asset files (the viewer mounts its assets/ folder's files there:
-- /assets/.../<name>.<ext>, a name with a dot): the file is the data, never
-- saved with the world (node names are [%w_-]: a dot is never one of ours)
local function is_file(path) return (under(path, "/assets") or under(path, "/saves") or under(path, "/docs")) and path:match("/[^/]*%.[^/]*$") ~= nil end
ecs.is_file = is_file
-- Never saved at all: /tmp, the built-in classes, /plugins, asset files
local function unsaved(path) return is_tmp(path) or is_builtin(path) or is_plugin(path) or is_file(path) end
-- Never written to disk: those, and /entities (spawned while playing)
local function is_scratch(path) return unsaved(path) or under(path, "/entities") end
ecs.is_scratch = is_scratch

-- Every node in order (depth first, parents first, siblings by rank then
-- name), kept until the tree or the ranks change: select, query, children
-- and the ticks read it instead of walking and sorting each time. Each node
-- gets its place (_i), its subtree's end (_e), its sorted children (_kids)
-- and its path's segments (_segs).
function World:_sorted()
  local rkey = self:_ranks_key()
  if self._sorted_list and self._sorted_gen == (self._gen or 0) and self._sorted_rk == rkey then return self._sorted_list end
  local rank, list = self:rank_of(), {}
  local function visit(n)
    list[#list + 1] = n
    n._i = #list
    local _, segs = normalize(n.path)
    n._segs = segs
    local kids = {}
    for _, ch in pairs(n.children) do kids[#kids + 1] = ch end
    table.sort(kids, function(a, b)
      local ra, rb = rank(a.path), rank(b.path)
      if ra ~= rb then return ra < rb end
      return a.name < b.name
    end)
    n._kids = kids
    for _, ch in ipairs(kids) do visit(ch) end
    n._e = #list
  end
  visit(self.root)
  self._sorted_list, self._sorted_gen, self._sorted_rk = list, self._gen or 0, rkey
  return list
end

function World:children(target)
  local n = resolve(self, target)
  self:_sorted()
  local list = {}
  for i, ch in ipairs(n._kids or {}) do list[i] = ch end
  return list
end

-- Depth-first walk, parents before children. fn(node, depth); return
-- false from fn to skip that node's subtree.
function World:walk(target, fn, depth)
  local n = resolve(self, target or "/")
  depth = depth or 0
  if fn(n, depth) == false then return end
  for _, ch in ipairs(self:children(n)) do self:walk(ch, fn, depth + 1) end
end

-- All nodes whose path matches `pattern`, in depth-first sorted order.
-- Only looks at the subtree under the pattern's literal prefix.
function World:select(pattern)
  local pat, segs = compile(pattern or "/**")
  local base = {}
  for i = 1, #segs do
    if type(pat[i]) ~= "table" then break end
    base[#base + 1] = segs[i]
  end
  local list = {}
  local start = self.nodes["/" .. table.concat(base, "/")]
  if not start then return list end
  local all = self:_sorted()
  if #pat == 1 and pat[1] == "**" then             -- (everything)
    for i = 1, #all do list[i] = all[i] end
    return list
  end
  if self._sel_of ~= all then self._sel, self._sel_of = {}, all end   -- (the same tree: the same answer, kept)
  local found = self._sel[pattern]
  if not found then
    found = {}
    local deep = false                             -- (no **: only paths as deep as the pattern)
    for i = 1, #pat do if pat[i] == "**" then deep = true end end
    local depth = #pat
    for i = start._i, start._e do
      local n = all[i]
      if (deep or #n._segs == depth) and match(pat, 1, n._segs, 1) then found[#found + 1] = n end
    end
    self._sel[pattern] = found
  end
  for i = 1, #found do list[i] = found[i] end
  return list
end

local function has_all(n, req)
  for i = 1, #req do if n.c[req[i]] == nil then return false end end
  return true
end

-- All nodes that have every listed component, in sorted path order.
---@param ... string component
function World:query(...)
  local req, list = { ... }, {}
  for _, n in ipairs(self:_sorted()) do
    if has_all(n, req) then list[#list + 1] = n end
  end
  return list
end

-- Code leaves -------------------------------------------------------------

-- Languages that compile to Lua: name -> function(src, name) returning
-- lua_source, linemap (linemap[lua line] = source line) | nil, err.
-- The compiler runs on the host; its output runs in the same sandbox.
ecs.languages = {
  hurdy = function(src, name)
    local found, hurdy = pcall(require, "hurdyl")
    if not found then return nil, name .. ": hurdy compiler not found (runtime/hurdyl)" end
    local target = _VERSION == "Lua 5.1" and (jit and "jit" or "5.1")   -- LuaJIT: no // or bit ops
                   or _VERSION == "Lua 5.2" and "5.2" or "latest"
    local ok, lua = pcall(hurdy.compile, src, name, target)
    if ok then                                     -- every Lua line ends in --[[hurdy line]]
      local map, i, last = {}, 0, 0
      for l in (lua .. "\n"):gmatch("(.-)\n") do
        i = i + 1
        local n = tonumber(l:match("%-%-%[%[(%d+)%]%]%s*$"))
        if n and n > 0 then last = n end
        map[i] = last
      end
      return lua, map
    end
    -- "[hurdy:<name>:12:5] Error near x: ..." -> "name:12: near x: ..." (like Lua's)
    local msg = tostring(lua)
    local line, rest = msg:match("%[hurdy:<.->:(%d+):%d+%] Error (.*)$")
    return nil, line and (name .. ":" .. line .. ": " .. rest) or msg
  end,
}

function ecs.code(src, lang) return { ["__" .. (lang or "lua")] = src } end
-- a code leaf's source and language ("lua", "hurdy"), or nil if v isn't one
function ecs.code_source(v)
  if type(v) ~= "table" then return nil end
  local k, src = next(v)
  if type(k) ~= "string" or type(src) ~= "string" or next(v, k) ~= nil then return nil end
  local lang = k:match("^__(%w+)$")
  if lang == "lua" or (lang and ecs.languages[lang]) then return src, lang end
  return nil
end
function ecs.is_code(v) return ecs.code_source(v) ~= nil end

local SAFE = { "assert", "error", "ipairs", "next", "pairs", "pcall", "print",
               "rawequal", "rawget", "rawlen", "rawset", "select", "setmetatable",
               "getmetatable", "tonumber", "tostring", "type", "unpack", "xpcall" }
local LIBS = { "math", "string", "table", "utf8" }

-- Extra names for code leaves, provided by the host (e.g. the viewer sets
-- ecs.code_globals.dd = its debugdraw API). Default dd: does nothing.
local noop = function() end
ecs.code_globals = { dd = setmetatable({}, { __index = function() return noop end }) }

local function code_env()
  local env = {}
  for k, v in pairs(ecs.code_globals) do env[k] = v end
  for _, k in ipairs(SAFE) do env[k] = _G[k] end
  for _, k in ipairs(LIBS) do                      -- copies: code can't patch shared libs
    if type(_G[k]) == "table" then
      local t = {}
      for kk, vv in pairs(_G[k]) do t[kk] = vv end
      env[k] = t
    end
  end
  env.unpack = env.unpack or table.unpack
  env._G = env
  return env
end

-- "name:7: oops" with Lua line 7 -> the source line it came from
local function remap(msg, name, map)
  if not map or type(msg) ~= "string" then return msg end
  local pat = "(" .. name:gsub("%p", "%%%0") .. "):(%d+):"
  return (msg:gsub(pat, function(n, l)
    local src = tonumber(map[tonumber(l)])
    return n .. ":" .. ((src and src > 0) and src or l) .. ":"
  end))
end
ecs.remap_error = remap

-- compile code-leaf source -> chunk, linemap | nil, err (nothing runs yet).
-- lang: "lua" (default) or a key of ecs.languages.
function ecs.compile(src, name, env, lang)
  if type(src) ~= "string" then return nil, "code must be a string" end
  if src:byte(1) == 27 then return nil, "binary chunks not allowed" end
  if lang and lang ~= "lua" then
    local tr = ecs.languages[lang]
    if not tr then return nil, name .. ": unknown language " .. tostring(lang) end
    local lua, map = tr(src, name)
    if not lua then return nil, map end
    local chunk, err = ecs.compile(lua, name, env)
    if not chunk then return nil, remap(err, name, map) end
    return chunk, map
  end
  env = env or code_env()
  if setfenv then
    local chunk, err = loadstring(src, "=" .. name)
    if chunk then setfenv(chunk, env) end
    return chunk, err
  end
  return lua_load(src, "=" .. name, "t", env)
end

-- Scripts and their text: ecs.loadscript() remembers the source of a script
-- (by chunk name), so ecs.system() inside it can find a function's own text.
ecs.sources = {}                                   -- chunk name -> { text, map, lang }

-- Load a script written in Lua or another language (ecs.languages).
-- name: its path (Lua) or file name. -> chunk, linemap | nil, err
function ecs.loadscript(src, name, lang)
  lang = lang or "lua"
  local lua, map, key = src, nil, "@" .. name
  if lang ~= "lua" then
    local tr = ecs.languages[lang]
    if not tr then return nil, name .. ": unknown language " .. tostring(lang) end
    lua, map = tr(src, name)
    if not lua then return nil, map end
    key = "=" .. name                              -- = : errors read "name:line:"
  end
  ecs.sources[key] = { text = src, map = map, lang = lang }
  local chunk, err = (loadstring or lua_load)(lua, key)
  if not chunk then return nil, remap(err, name, map) end
  return chunk, map
end

local function text_lines(text)
  local t = {}
  for l in (text:gsub("\r\n", "\n") .. "\n"):gmatch("(.-)\n") do t[#t + 1] = l end
  return t
end

-- hurdy: the line of the "}" that closes the "{" ending line `first`
local function closing_brace(L, first)
  local text = table.concat(L, "\n", first) .. "\n"   -- starts at line `first`
  local depth, line, n = 0, first, #text
  local pos = L[first]:find("{%s*$")               -- the "{" itself
  while pos <= n do
    local c = text:sub(pos, pos)
    if c == "\n" then line = line + 1
    elseif c == "-" and text:sub(pos + 1, pos + 1) == "-" then  -- -- comment
      pos = (text:find("\n", pos, true) or n + 1) - 1
    elseif c == "-" and text:sub(pos + 1, pos + 1) == "*" then  -- -* block *-
      local e = text:find("*-", pos + 2, true) or n
      for _ in text:sub(pos, e):gmatch("\n") do line = line + 1 end
      pos = e + 1
    elseif c == '"' or c == "'" then               -- "string" / 'string'
      local j = pos + 1
      while j <= n and text:sub(j, j) ~= c do
        if text:sub(j, j) == "\\" then j = j + 1 end
        j = j + 1
      end
      pos = j
    elseif c == "[" and text:find("^%[=*%[", pos) then   -- [[long]] / [==[long]==]
      local eq = text:match("^%[(=*)%[", pos)
      local e = text:find("]" .. eq .. "]", pos, true) or n
      for _ in text:sub(pos, e):gmatch("\n") do line = line + 1 end
      pos = e + #eq + 1
    elseif c == "{" then depth = depth + 1
    elseif c == "}" then
      depth = depth - 1
      if depth == 0 then return line end
    end
    pos = pos + 1
  end
  return nil
end

-- A system written as real code, kept as a code leaf:
--   local ball = ecs.system(function()
--     local function helper() ... end
--     return { requires = { "xform" }, run = function(w, n, dt) ... end }
--   end)
--   w:spawn("/game/systems", { ball = ball })
-- The function's body (its own source text) becomes the code leaf, so it
-- saves, diffs, replicates and hot-swaps like any other. The body later runs
-- on its own, in the sandbox: it can't use locals from outside it.
-- Works in scripts loaded with ecs.loadscript (Lua, hurdy) or from files.
function ecs.system(f)
  if type(f) ~= "function" then error("ecs.system: expects function() ... end", 2) end
  local info = debug.getinfo(f, "S")
  local where = tostring(info.short_src) .. ":" .. tostring(info.linedefined)
  local bad = {}
  for i = 1, 255 do
    local name = debug.getupvalue(f, i)
    if not name then break end
    if name ~= "_ENV" and not name:match("^_hurdytemp%d+$") then bad[#bad + 1] = name end
  end
  if #bad > 0 then
    error(where .. ": ecs.system uses outer local(s) " .. table.concat(bad, ", ")
          .. ": move them inside the function (it runs on its own, sandboxed)", 2)
  end
  local src = ecs.sources[info.source]
  local text, lang = src and src.text, src and src.lang or "lua"
  if not text and info.source:sub(1, 1) == "@" and io then
    local fh = io.open(info.source:sub(2), "rb")
    if fh then text = fh:read("*a"); fh:close() end
  end
  if not text then error(where .. ": ecs.system can't find the script's text (use ecs.loadscript)", 2) end
  local L = text_lines(text)
  local first, last
  if lang == "lua" then
    first, last = info.linedefined, info.lastlinedefined
    local head = (L[first] or ""):gsub("%-%-.*$", "")   -- a trailing -- comment is fine
    if not head:match("function%s*%(%s*%)%s*$") or not (L[last] or ""):match("^%s*end") then
      error(where .. ": write it as  ecs.system(function()  then the body on its own lines, then  end)", 2)
    end
  else
    first = src.map and tonumber(src.map[info.linedefined])
    if first then L[first] = L[first]:gsub("%-%-.*$", "") end   -- a trailing -- comment is fine
    if not first or not L[first]:match("function%s*%(%s*%)%s*{%s*$") then
      error(where .. ": write it as  ecs.system(function() {  then the body on its own lines, then  })", 2)
    end
    last = closing_brace(L, first)
    if not last or not L[last]:match("^%s*}") then error(where .. ": ecs.system: no closing } on its own line", 2) end
  end
  local body, indent = {}, nil
  for i = first + 1, last - 1 do
    local l = L[i]
    body[#body + 1] = l
    if l:find("%S") then
      local n = #l:match("^%s*")
      if not indent or n < indent then indent = n end
    end
  end
  for i, l in ipairs(body) do body[i] = l:sub((indent or 0) + 1) end
  local text = table.concat(body, "\n") .. "\n"
  if lang == "lua" and info.source:sub(1, 1) == "@" then   -- where its lines live (the editor's probe: values, lines run)
    ecs.code_origins[text] = { file = info.source:sub(2), line = first + 1 }
  end
  return ecs.code(text, lang)
end

-- ecs.on_build(chunk, name): if set, runs a system's setup (its chunk, the
-- code before its run function) instead of calling it directly. For tools
-- (the editor's probe: breakpoints there), nothing else. nil by default.
ecs.on_build = nil
-- what on_build returns to build a system later (in the next tick), not now
ecs.DEFER = setmetatable({}, { __tostring = function() return "deferred" end })

-- a code leaf's text -> the file and line it was cut from (ecs.system), and
-- a system's chunk ("=" .. its name) -> the same: line k of the chunk is line
-- `line + k - 1` of `file`. For tools (the editor's probe), nothing else.
ecs.code_origins, ecs.chunk_origins = {}, {}

-- Game modules: a code leaf named `module` is a module, not a system. Code
-- leaves load one with require: `require "space"` is /data/lib/space's
-- module (a path works too: require "/data/lib/space"). It runs once and its
-- value is shared; when its source changes, the systems (and modules) that
-- required it are built again. Keep state in the world, not in a module.
ecs.MODULES = "/data/lib"
local function module_path(name)
  if type(name) ~= "string" or name == "" then return nil end
  return name:sub(1, 1) == "/" and name or (ecs.MODULES .. "/" .. name)
end
local function module_src(w, path)                 -- its current source (or its plain value), lang
  local n = w.nodes[path]
  local v = n and n.c.module
  if v == nil then return nil end
  local src, lang = ecs.code_source(v)
  if src then return src, lang end
  return v
end

-- a code leaf's environment, with this world's require
local function world_env(w)
  local env = code_env()
  env.require = function(name) return w:require(name) end
  return env
end

function World:require(name)
  local path = module_path(name)
  if not path then error("require: a module's name or path", 2) end
  local src, lang = module_src(self, path)
  if src == nil then error("require: no module " .. path .. " (a `module` code leaf there)", 2) end
  if self._collect then self._collect[path] = true end   -- (the system being built depends on it)
  self._modules = self._modules or {}
  local m = self._modules[path]
  if m and m.loading then error("require: " .. path .. " requires itself (a cycle)", 2) end
  local fresh = m and m.src == src
  for p, was in pairs(fresh and m.deps or {}) do   -- (and what it required hasn't changed either)
    if module_src(self, p) ~= was then fresh = false break end
  end
  if fresh then
    if self._collect then for p in pairs(m.deps) do self._collect[p] = true end end
    return m.value
  end
  if type(src) ~= "string" then                    -- plain data: as it is
    self._modules[path] = { src = src, value = src, deps = {} }
    return src
  end
  m = { src = src, loading = true, deps = {} }
  self._modules[path] = m
  local outer = self._collect
  self._collect = m.deps                           -- (what it requires: its dependents depend on too)
  local chunk, err = ecs.compile(src, path .. "/module", world_env(self), lang)
  local ok, v = chunk ~= nil, err
  if chunk then ok, v = pcall(chunk) end
  self._collect = outer
  m.loading = nil
  if not ok then self._modules[path] = nil; error(tostring(v), 0) end
  m.value = v == nil and true or v
  for p in pairs(m.deps) do m.deps[p] = module_src(self, p) end   -- (their sources now: to tell when it's stale)
  if outer then for p in pairs(m.deps) do outer[p] = true end end
  return m.value
end

-- source -> system fields { once, requires, fn, map, deps } | nil, err
local function build_system(w, src, name, lang)
  ecs.chunk_origins["=" .. name] = ecs.code_origins[src]
  local chunk, map = ecs.compile(src, name, world_env(w), lang)
  if not chunk then return nil, map end
  if type(map) ~= "table" then map = nil end
  local run = ecs.on_build                         -- (tools: the editor's probe runs it, to stop in it)
  local ok, v
  local deps, outer = {}, w._collect
  w._collect = deps                                -- (the modules it requires while it's set up)
  if run then ok, v = pcall(run, chunk, name) else ok, v = pcall(chunk) end
  w._collect = outer
  if ok and v == ecs.DEFER then return nil, ecs.DEFER end
  if not ok then return nil, remap(tostring(v), name, map) end
  if type(v) == "function" then return { once = true, requires = {}, fn = v, map = map, deps = deps } end
  if type(v) == "table" and (type(v.run) == "function" or type(v.on_key) == "function" or type(v.on_event) == "function"
                             or type(v.on_add) == "function" or type(v.on_remove) == "function") then
    local req, f = v.requires or {}, v.filter or {}
    if type(req) ~= "table" or type(f) ~= "table" then return nil, name .. ": requires and filter must be lists" end
    req = { unpack(req) }
    for _, x in ipairs(type(f.all) == "table" and f.all or {}) do req[#req + 1] = x end
    return { once = false, requires = req, any = type(f.any) == "table" and f.any or nil, none = type(f.none) == "table" and f.none or nil,
             fn = v.run, on_key = v.on_key, on_event = v.on_event, on_add = v.on_add, on_remove = v.on_remove,
             interval = tonumber(v.interval), active = v.active, map = map, deps = deps }
  end
  return nil, name .. ": must return function(w, dt) or { requires = {...}, run = function(w, node, dt), on_key = function(w, key, down, player) }"
end

-- Bring systems in line with the world's code components (called by tick).
-- has a code leaf seen by the last sync_code been replaced, or its node gone?
function World:code_moved()
  local seen = self._code_seen
  if not seen then return true end
  for i = 1, #seen do
    local e = seen[i]
    if e[1].c[e[2]] ~= e[3] or self.nodes[e[1].path] ~= e[1] then return true end
  end
  return false
end

function World:sync_code()
  local found, seen = {}, {}
  for path, n in pairs(self.nodes) do
    for cname, v in pairs(n.c) do
      local src, lang = ecs.code_source(v)
      if src then seen[#seen + 1] = { n, cname, v } end   -- (watched: World:code_moved)
      if src and cname ~= "module" then           -- (a module isn't a system: require loads it)
        found[#found + 1] = { key = (path == "/" and "" or path) .. "/" .. tostring(cname), src = src, lang = lang }
      end
    end
  end
  self._code_seen = seen
  table.sort(found, function(a, b) return a.key < b.key end)   -- deterministic order
  local live = {}
  for _, f in ipairs(found) do
    live[f.key] = true
    local s = self.systems[f.key]
    local stale = false                            -- a module it required changed (or went)
    for p, was in pairs(s and s.deps or {}) do
      if module_src(self, p) ~= was then stale = true break end
    end
    if not s or s.src ~= f.src or stale then
      local def, err = build_system(self, f.src, f.key, f.lang)
      if err == ecs.DEFER then self._code_dirty = true   -- (built in the next tick)
      elseif def then
        self:system(f.key, def.requires, def.fn)
        s = self.systems[f.key]
        s.once, s.code, s.src, s.on_key, s.map = def.once, true, f.src, def.on_key, def.map
        s.any, s.none, s.on_event, s.on_add, s.on_remove = def.any, def.none, def.on_event, def.on_add, def.on_remove
        s.interval, s.active = def.interval, def.active
        s.deps = {}
        for p in pairs(def.deps) do s.deps[p] = module_src(self, p) end
        self.code_err[f.key] = nil
      else
        if s then                                  -- keep the old version, don't retry
          s.src = f.src
          for p in pairs(s.deps or {}) do s.deps[p] = module_src(self, p) end
        end
        self.code_err[f.key] = err
      end
    end
  end
  for name, s in pairs(self.systems) do            -- code removed: system removed
    if s.code and not live[name] then
      self:unsystem(name)
      self.code_err[name] = nil
    end
  end
  -- code systems run by (rank in the root's order list, name); their slots
  -- in the run order are reshuffled among themselves only
  local rank = self:rank_of()
  local slots, names = {}, {}
  for i, name in ipairs(self.order) do
    local s = self.systems[name]
    if s and s.code then slots[#slots + 1] = i; names[#names + 1] = name end
  end
  table.sort(names, function(a, b)
    local ra, rb = rank(a), rank(b)
    if ra ~= rb then return ra < rb end
    return a < b
  end)
  for k, i in ipairs(slots) do self.order[i] = names[k] end
  for name in pairs(self.code_err) do
    if not live[name] then self.code_err[name] = nil end
  end
end

-- Systems -------------------------------------------------------------------

-- Register or hot-replace a system.
--   w:system("move", { "pos", "vel" }, function(w, node, dt) ... end)
-- Keeps its original slot in the run order when replaced.
-- A system from a function (not a code leaf). opts: { any, none, on_add,
-- on_remove, on_event, interval, active } as a code system's table (see tick).
function World:system(name, requires, fn, opts)
  if not self.systems[name] then self.order[#self.order + 1] = name end
  local s = { name = name, requires = requires or {}, fn = fn }
  for k, v in pairs(opts or {}) do s[k] = v end
  self.systems[name] = s
end

function World:unsystem(name)
  self.systems[name] = nil
  for i, n in ipairs(self.order) do
    if n == name then table.remove(self.order, i) break end
  end
end

-- The player owning a `replicate` tag: true -> 1 (the host), N -> N,
-- { by = N } -> N (by omitted: 1). With a world w: a player who isn't in
-- the game (w.players) owns nothing, the host does instead.
function ecs.owner(r, w)
  local by = r == true and 1 or type(r) == "number" and r or type(r) == "table" and (r.by or 1) or nil
  if by and by ~= 1 and w and w.players and not w.players[by] then by = 1 end
  return by
end

-- Does this world decide for node n (a node or its path), or only guess?
-- Its nearest `replicate` tag (its own or a parent's) says whose it is (see
-- ecs.owner); untagged, or not in a network session (no w.peer): this world.
function World:owns(n)
  if type(n) == "string" then n = self.nodes[n] end
  if not self.peer or not n then return true end
  local q, r = n, nil
  while q and r == nil do r = q.c.replicate; q = q.parent end
  return r == nil or ecs.owner(r, self) == self.peer
end

-- Does node n pass system s's filter (requires = all of; any = one of; none = none of)?
local function passes(n, s)
  local c = n.c
  local req = s.requires
  for i = 1, #req do if c[req[i]] == nil then return false end end
  local any = s.any
  if any then
    local one = false
    for i = 1, #any do if c[any[i]] ~= nil then one = true break end end
    if not one then return false end
  end
  local none = s.none
  if none then for i = 1, #none do if c[none[i]] ~= nil then return false end end end
  return true
end

-- A component added by hand (n.c.vel = {...}) joins the systems' lists at
-- the next change of the tree, w:set, a load, twice a second, or now:
function World:refresh() self._shape = (self._shape or 0) + 1 end

-- Is system s switched off? (`active = false` in its code, or an `active`
-- component set to false on the node it lives on: its props row)
local function inactive(self, s, name)
  if s.active == false then return true end
  local at = s.code and name:match("^(.+)/[^/]*$")
  local n = at and self.nodes[at]
  return n ~= nil and n.c.active == false
end

-- Advance the simulation one tick, only for nodes matching `pattern`.
-- Each system runs on the nodes that pass its filter, worked out before it
-- runs: a node spawned by one system is run by the systems after it in the
-- same tick (tiny-ecs' rule: structure changes count between systems); a
-- removed node is skipped at once. The lists are kept while the tree, its
-- components (w:set, loads) and who's playing stay the same. Systems may
-- say `filter = { any = {...}, none = {...} }` (with requires: all of),
-- `on_add(w, node)` / `on_remove(w, node)` (a node enters / leaves its
-- list: called before it runs, in the list's order), `interval = 0.5` (it
-- runs every 0.5 s of game time, with the time since its last run as dt),
-- `active = false` (kept, not run; or an `active` component = false on its node).
function World:tick(pattern, dt)
  self.frame = self.frame + 1
  local rk = self.code ~= false and self:_ranks_key()
  if self.code ~= false and (self._code_dirty or self.frame % 30 == 0 or rk ~= self._code_rk or self:code_moved()) then
    self._code_dirty, self._code_rk = false, rk    -- (code came or went: a load, a spawn, a remove, a code leaf
    self:sync_code()                               -- replaced, the order changed; else twice a second: code
  end                                              -- written into a new component. w.code = false: no code leaves)
  dt = dt or 1
  if self.frame % 30 == 0 then self:refresh() end  -- (components added by hand: picked up twice a second at least)
  pattern = pattern or "/**"
  local who = ""
  if self.peer then
    who = tostring(self.peer)
    for k in pairs(self.players or {}) do who = who .. "," .. tostring(k) end
  end
  local function key() return pattern .. "|" .. (self._gen or 0) .. "|" .. (self._shape or 0) .. "|" .. who end
  local function base()                            -- the nodes this tick runs on, any system
    local k = key()
    if self._tick_key == k then return self._tick_nodes end
    local nodes = self:select(pattern)
    if self:layout() then                          -- only /o and /e are live
      local keep = {}
      for _, n in ipairs(nodes) do
        local s1 = n._segs and n._segs[1]
        if s1 == "objects" or s1 == "entities" or (not n._segs and self:live(n.path)) then keep[#keep + 1] = n end
      end
      nodes = keep
    end
    if self.peer then                              -- in a session: not the nodes another player owns (unless predicted,
      local mine, keep = self.peer, {}             -- or driven by our inputs: { input = N }, ours to predict)
      for _, n in ipairs(nodes) do
        local r, q = nil, n
        while q and r == nil do r = q.c.replicate; q = q.parent end
        if r == nil or ecs.owner(r, self) == mine or (type(r) == "table" and (r.predict or r.input == mine)) then keep[#keep + 1] = n end
      end
      nodes = keep
    end
    self._tick_key, self._tick_nodes = k, nodes
    return nodes
  end
  local prof = ecs.profiler                        -- (a tool's: the time each node takes, see below)
  local now, add = prof and prof.now, prof and prof.add
  local function call(s, name, fn, ...)            -- code: errors stay inside it (the system breaks)
    if not s.code then fn(...) return true end
    local ok, err = pcall(fn, ...)
    if not ok then s.broken = true; self.code_err[name] = remap(tostring(err), name, s.map) end
    return ok
  end
  local function members(s, name)                  -- s's list: kept until the tick's nodes change
    local k = key()
    if s._key == k and s._list then return s._list end
    local list, set = {}, {}
    for _, n in ipairs(base()) do if passes(n, s) then list[#list + 1] = n; set[n] = true end end
    local old, oldset = s._list or {}, s._set or {}
    s._key, s._list, s._set = k, list, set
    if s.on_remove then
      for _, n in ipairs(old) do if not set[n] and not s.broken then call(s, name, s.on_remove, self, n) end end
    end
    if s.on_add then
      for _, n in ipairs(list) do if not oldset[n] and not s.broken then call(s, name, s.on_add, self, n) end end
    end
    return list
  end
  for _, name in ipairs({ unpack(self.order) }) do  -- (systems may (un)register while running)
    local s = self.systems[name]
    if s and not s.broken and (s.fn or s.on_add or s.on_remove) and not inactive(self, s, name) then
      local sdt = dt
      if s.interval then                           -- (every `interval` s of game time)
        s.acc = (s.acc or 0) + dt
        if s.acc + 1e-9 < s.interval then sdt = nil else sdt, s.acc = s.acc, 0 end
      end
      if s.once then
        if sdt and s.fn then
          local t0 = now and now()
          call(s, name, s.fn, self, sdt)
          if t0 then add(name:match("^(.+)/[^/]*$") or "/", now() - t0) end   -- (the node it lives on)
        end
      else
        local list = members(s, name)
        if sdt and s.fn and not s.broken then
          for _, node in ipairs(list) do
            if self.nodes[node.path] == node and passes(node, s) then   -- (removed meanwhile, or a component gone)
              local t0 = now and now()
              local ok = call(s, name, s.fn, self, node, sdt)
              if t0 then add(node.path, now() - t0) end
              if not ok then break end
            end
          end
        end
      end
    end
  end
  return true
end
-- ecs.profiler = { now = fn() -> seconds, add = fn(path, seconds) }: when set
-- (by a tool: the editor's tree), tick() reports the time each node's systems
-- took: a system per node, to that node; a system run once, to its own node.

-- Input: a key went down/up. Calls w.on_key(w, key, down, player) if set, then
-- the on_key of every code system (in run order). Returns true if anyone listened.
function World:key(key, down, player)
  player = player or 1
  if self.code ~= false then self:sync_code() end
  local heard = false
  if type(self.on_key) == "function" then self.on_key(self, key, down, player); heard = true end
  for _, name in ipairs({ unpack(self.order) }) do
    local s = self.systems[name]
    if s and s.on_key and not s.broken then
      heard = true
      local ok, err = pcall(s.on_key, self, key, down, player)
      if not ok then s.broken = true; self.code_err[name] = remap(tostring(err), name, s.map) end
    end
  end
  return heard
end

function World:step(dt) return self:tick("/**", dt) end

-- Events: one-shot things (a sound, a burst of sparks, "left wins"), not
-- state. w:event(name, data) hands it at once to w.on_event and to every
-- code system's on_event(w, name, data, player) (in run order), and in a
-- network session sends it to every other player, who get it once, in
-- order (net.lua). Only the host makes events (the others' calls do
-- nothing: they don't decide), and nothing while a tick is replayed.
function World:event(name, data)
  if self.replaying or (self.net and self.peer ~= 1) then return false end
  self:deliver(name, data)
  if self.net and self.net.event then self.net:event(name, data) end
  return true
end
function World:deliver(name, data, player)
  if self.code ~= false and (self._code_dirty or self:code_moved()) then self._code_dirty = false; self:sync_code() end
  if type(self.on_event) == "function" then self.on_event(self, name, data, player) end
  for _, sname in ipairs({ unpack(self.order) }) do
    local s = self.systems[sname]
    if s and s.on_event and not s.broken then
      if s.code then
        local ok, err = pcall(s.on_event, self, name, data, player)
        if not ok then s.broken = true; self.code_err[sname] = remap(tostring(err), sname, s.map) end
      else s.on_event(self, name, data, player) end
    end
  end
end

-- Run a tick again for some nodes only: their per-node systems, in order
-- (no systems that run once or at an interval, no new frame). The network
-- replays a player's inputs with it (reconciliation: net.lua); w.replaying
-- is true meanwhile (a system can skip what it mustn't do twice: spawning a
-- shot). Errors break the system, as tick.
function World:rerun(pattern, dt)
  local nodes = self:select(pattern)
  self.replaying = true
  for _, name in ipairs({ unpack(self.order) }) do
    local s = self.systems[name]
    if s and s.fn and not s.broken and not s.once and not s.interval and not inactive(self, s, name) then
      for _, node in ipairs(nodes) do
        if self.nodes[node.path] == node and passes(node, s) then
          local ok, err = pcall(s.fn, self, node, dt)
          if not ok then s.broken = true; self.code_err[name] = remap(tostring(err), name, s.map) break end
        end
      end
    end
  end
  self.replaying = nil
end

---------------------------------------------------------------------------
-- serialization
---------------------------------------------------------------------------
-- A blob is plain Lua source (diff-friendly, one node per line):
--
--   return { version = 1, scope = "/game/**",   -- set by save(), not diff()
--   removed = {                                 -- set by diff(), optional
--     "/game/old",
--   },
--   nodes = {
--     ["/game/hello"] = { greeting = { text = "Hello" } },
--   } }
--
-- Only data is allowed: nil/boolean/number/string and tables of those.
-- Keys are sorted, so the same world always produces the same blob.

local idents = {}                                  -- (keys are few: each checked once)
local function is_ident(s)
  if type(s) ~= "string" then return false end
  local v = idents[s]
  if v == nil then v = s:match("^[%a_][%w_]*$") ~= nil; idents[s] = v end
  return v
end

local function fmt_number(n)
  if n ~= n then return "0/0" end
  if n == math.huge then return "1/0" end
  if n == -math.huge then return "-1/0" end
  if n == math.floor(n) and math.abs(n) < 2^53 then
    return string.format("%d", n)
  end
  local s = string.format("%.15g", n)       -- short form if it round-trips
  if tonumber(s) == n then return s end
  return string.format("%.17g", n)
end

local function key_less(a, b)
  local ta, tb = type(a), type(b)
  if ta ~= tb then return ta < tb end
  if ta == "boolean" then return (not a) and b end
  return a < b
end

local serialize
local quoted, nquoted = {}, 0

local function ser_table(t, seen)
  if seen[t] then error("cycle in component data", 0) end
  seen[t] = true
  local out, n = {}, #t
  for i = 1, n do out[#out + 1] = serialize(t[i], seen) end
  local keys, strs = {}, true
  for k in pairs(t) do
    if type(k) == "string" then keys[#keys + 1] = k
    else
      local isarr = type(k) == "number" and k >= 1 and k <= n and k == math.floor(k)
      if not isarr then keys[#keys + 1] = k; strs = false end
    end
  end
  if strs then table.sort(keys) else table.sort(keys, key_less) end   -- (names only: the plain, faster sort)
  for _, k in ipairs(keys) do
    local ks = is_ident(k) and k or ("[" .. serialize(k, seen) .. "]")
    out[#out + 1] = ks .. " = " .. serialize(t[k], seen)
  end
  seen[t] = nil
  if #out == 0 then return "{}" end
  return "{ " .. table.concat(out, ", ") .. " }"
end

function serialize(v, seen)
  local tv = type(v)
  if tv == "nil" then return "nil"
  elseif tv == "boolean" then return tostring(v)
  elseif tv == "number" then return fmt_number(v)
  elseif tv == "string" then
    if #v < 64 then return (string.format("%q", v):gsub("\\\n", "\\n")) end
    local q = quoted[v]                            -- (long strings: code leaves' source, quoted once)
    if not q then
      if nquoted > 256 then quoted, nquoted = {}, 0 end
      q = string.format("%q", v):gsub("\\\n", "\\n")
      quoted[v], nquoted = q, nquoted + 1
    end
    return q
  elseif tv == "table" then return ser_table(v, seen or {})
  end
  error("cannot serialize a " .. tv, 0)
end
ecs.serialize = serialize

-- Human-friendly serialization for files people edit: same data and key
-- order as serialize(), but tables that don't fit on one line are split
-- one entry per line.
local function pretty(v, indent, width)
  local one = serialize(v)
  if type(v) ~= "table" or #one + #indent <= width then return one end
  local pad, out, n = indent .. "  ", {}, #v
  local line = nil                              -- pack scalars into lines
  for i = 1, n do
    local item = v[i]
    if type(item) == "table" then
      if line then out[#out + 1] = line; line = nil end
      out[#out + 1] = pad .. pretty(item, pad, width) .. ","
    else
      local sv = serialize(item) .. ","
      -- strings get a line each (paths in order.lua, sprite rows); numbers pack
      if line and type(item) ~= "string" and #line + 1 + #sv <= width then line = line .. " " .. sv
      else
        if line then out[#out + 1] = line end
        line = pad .. sv
      end
    end
  end
  if line then out[#out + 1] = line end
  local keys = {}
  for k in pairs(v) do
    local isarr = type(k) == "number" and k >= 1 and k <= n and k == math.floor(k)
    if not isarr then keys[#keys + 1] = k end
  end
  table.sort(keys, key_less)
  for _, k in ipairs(keys) do
    local ks = is_ident(k) and k or ("[" .. serialize(k) .. "]")
    out[#out + 1] = pad .. ks .. " = " .. pretty(v[k], pad, width) .. ","
  end
  return "{\n" .. table.concat(out, "\n") .. "\n" .. indent .. "}"
end

function ecs.pretty(v, width)
  local ok, s = pcall(pretty, v, "", width or 72)
  if not ok then return nil, s end
  return s
end

-- Build blob text. `nodes` is a sorted array of { path, serialized comps }.
local function emit(scope, nodes, removed, merge)
  local head = "return { version = " .. VERSION
  if scope then head = head .. ", scope = " .. serialize(scope) end
  local lines = { head .. "," }
  if removed and #removed > 0 then
    lines[#lines + 1] = "removed = {"
    for _, p in ipairs(removed) do lines[#lines + 1] = "  " .. serialize(p) .. "," end
    lines[#lines + 1] = "},"
  end
  if merge and #merge > 0 then                     -- (nodes given in part: { path, the components dropped })
    lines[#lines + 1] = "merge = {"
    for _, e in ipairs(merge) do lines[#lines + 1] = "  [" .. serialize(e[1]) .. "] = " .. serialize(e[2]) .. "," end
    lines[#lines + 1] = "},"
  end
  lines[#lines + 1] = "nodes = {"
  for _, e in ipairs(nodes) do
    lines[#lines + 1] = "  [" .. serialize(e[1]) .. "] = " .. e[2] .. ","
  end
  lines[#lines + 1] = "} }"
  return table.concat(lines, "\n") .. "\n"
end

-- Serialize every node matching `pattern`. Returns ok, blob | false, err.
-- The blob remembers its pattern as `scope`: loading it later makes that
-- scope match the blob exactly (nodes in scope but not in the blob are removed).
-- `disk`: what goes to disk only (no /e: see is_scratch).
function World:save(pattern, disk)
  pattern = normalize(pattern or "/**")
  local skip = disk and is_scratch or unsaved
  return pcall(function()
    local nodes = {}
    local function auto(n)                         -- /classes made only to hold the built-in ones: not saved
      if n.path ~= "/classes" or not self.auto_classes or next(n.c) then return false end
      for name in pairs(n.children) do if ecs.BUILTIN[name] == nil then return false end end
      return true
    end
    for _, n in ipairs(self:select(pattern)) do
      if not skip(n.path) and not auto(n) then     -- (temporaries: never saved)
        local ok, s = pcall(serialize, n.c)
        if not ok then error(n.path .. ": " .. s, 0) end
        nodes[#nodes + 1] = { n.path, s }
      end
    end
    return emit(pattern, nodes)
  end)
end

-- Run Lua source that only returns data, in an empty sandbox (no globals,
-- text only). Returns value | nil, err.
local function sandbox_eval(src, name)
  if type(src) ~= "string" then return nil, "expected a string" end
  local chunk, err
  if setfenv then
    if src:byte(1) == 27 then return nil, "binary chunks not allowed" end
    chunk, err = loadstring(src, "=" .. name)
    if chunk then setfenv(chunk, {}) end
  else
    chunk, err = lua_load(src, "=" .. name, "t", {})
  end
  if not chunk then return nil, err end
  local ok, v = pcall(chunk)
  if not ok then return nil, v end
  return v
end

-- Generic data <-> string, used for network messages.
function ecs.encode(v)
  local ok, s = pcall(serialize, v)
  if not ok then return nil, s end
  return "return " .. s
end

function ecs.decode(s, name) return sandbox_eval(s, name or "msg") end

-- Savegames: w:savegame(name, value) -> true | nil, err; w:loadgame(name)
-- -> value | nil. A name is [%w_-]+; the value is data (as messages). Where
-- they go: ecs.saves, { read = fn(name) -> text | nil, write = fn(name,
-- text) -> ok }: in memory here; the viewer's writes <game>/saves/<name>.sav
-- (the tree's /saves). Local to this machine: not part of the world.
local memory_saves = {}
ecs.saves = {
  read = function(name) return memory_saves[name] end,
  write = function(name, text) memory_saves[name] = text return true end,
}
local function save_name(name) return type(name) == "string" and name:match("^[%w_%-]+$") ~= nil end
function World:savegame(name, value)
  if not save_name(name) then return nil, "a savegame's name: letters, digits, _ and -" end
  local text, err = ecs.encode(value)
  if not text then return nil, err end
  if not ecs.saves.write(name, text) then return nil, "can't write the savegame " .. name end
  return true
end
-- the game's assets (a folder world's assets/, a script's beside it): plain
-- data files (a .tmap, a .sfx, an .atlas.lua...) read as Lua data, no code
-- power. ecs.assets.read(name) -> its text (boot.lua sets it; nil: none).
ecs.assets = { read = function() return nil end }
function World:asset(name)                         -- "level1.tmap" or "/assets/level1.tmap" -> its data | nil, err
  name = tostring(name):gsub("^/assets/", ""):gsub("^/", "")
  if name:find("%.%.") then return nil, "an asset's name: inside assets/" end
  local text = ecs.assets.read(name)
  if not text then return nil, "no asset " .. name end
  local v, err = ecs.decode(text, name)
  if v == nil then return nil, err end
  return v
end
-- a sound (an .sfx of assets/: plugins/sfxr makes them), played once: not
-- while replaying (a rewind, a scrub) nor from a peer's copy of the world
-- (w.silent). ecs.sound(w, name, volume) plays it (runtime/sound.lua, set by boot.lua).
ecs.sound = function() end
function World:sound(name, volume)
  if self.replaying or self.silent then return false end
  return ecs.sound(self, name, volume) and true or false
end
-- a conversation (an .dialog of assets/: plugins/dialog), parsed, with its
-- methods to run it (runtime/dialog.lua, set by boot.lua): d:begin(st)...
ecs.dialog = function() return nil, "no dialogs here (runtime/dialog.lua)" end
function World:dialog(name) return ecs.dialog(self, name) end
-- bullet patterns (a .bullets of assets/: plugins/bullets), parsed, with the
-- functions that play them (runtime/bullets.lua, set by boot.lua): d:new(seed),
-- d:emit(st, pattern, x, y, owner), d:step(st, dt, tx, ty), d:hit(...), d:look(st)
ecs.bullets = function() return nil, "no bullets here (runtime/bullets.lua)" end
function World:bullets(name) return ecs.bullets(self, name) end
-- The editor's generators, from a game (plugins/<kind>/gen.lua: no Lite in
-- them): w:generate("dungeon", settings) / w:generate("terrain", settings) ->
-- map data ({ w, h, tileset, layers = { { name, rows } } }), info (the
-- dungeon's: rooms, list = each room's x, y, w, h, cx, cy). Exported games
-- carry plugins/*/gen.lua.
function World:generate(kind, settings)
  if type(kind) ~= "string" or not kind:match("^[%w_]+$") then return nil, "generate: a generator's name (dungeon, terrain)" end
  local ok, G = pcall(require, "plugins." .. kind .. ".gen")
  if not ok or type(G) ~= "table" or type(G.generate) ~= "function" then return nil, "no generator " .. kind .. " (plugins/" .. kind .. "/gen.lua)" end
  return G.generate(settings or {})
end
function World:loadgame(name)
  if not save_name(name) then return nil end
  local text = ecs.saves.read(name)
  if not text then return nil end
  return (ecs.decode(text, name .. ".sav"))
end

-- Evaluate and validate a world blob.
local check_data
local function eval_blob(blob)
  if type(blob) ~= "string" then return nil, "blob must be a string" end
  local data, err = sandbox_eval(blob, "blob")
  if err then return nil, err end
  return check_data(data)
end
-- (a blob's data, decoded: its shape checked; data from the network too)
check_data = function(data)
  if type(data) ~= "table" or type(data.nodes) ~= "table" then
    return nil, "blob is not a world snapshot"
  end
  if data.version ~= VERSION then
    return nil, "unsupported blob version " .. tostring(data.version)
  end
  if data.scope ~= nil and type(data.scope) ~= "string" then
    return nil, "bad scope"
  end
  data.removed = data.removed or {}
  if type(data.removed) ~= "table" then return nil, "bad removed list" end
  for _, p in ipairs(data.removed) do
    if type(p) ~= "string" then return nil, "bad removed path" end
  end
  for path, comps in pairs(data.nodes) do
    if type(path) ~= "string" or type(comps) ~= "table" then
      return nil, "bad node " .. tostring(path)
    end
  end
  if data.merge ~= nil and type(data.merge) ~= "table" then return nil, "bad merge list" end
  for path, drop in pairs(data.merge or {}) do
    if type(path) ~= "string" or type(drop) ~= "table" then return nil, "bad merge " .. tostring(path) end
  end
  return data
end

-- Remove a node; removing the root just empties it.
local function erase(self, path)
  local n = self:node(path)
  if not n then return end
  if n ~= self.root then return self:remove(path) end
  for name in pairs(n.children) do self:remove(join("/", name)) end
  n.c = {}
end

-- Apply a blob under mount point `at` (default "/"). In order:
--   1. every path in `removed` is deleted (with its subtree)
--   2. if the blob has a `scope` (i.e. it came from save), every existing
--      node matching that scope that is not in the blob is deleted
--   3. every node in the blob is created if missing and its components
--      replaced by the blob's
-- Nodes outside all of that are left untouched. The blob is fully validated
-- before anything changes, so a bad blob leaves the world as it was.
function World:load(blob, at)
  local data, err = eval_blob(blob)
  if not data then return false, err end
  return self:_load_data(data, at)
end

-- The nodes matching `pattern` as data, what save writes but as tables:
-- { version, scope = pattern, nodes = { [path] = a copy of its components } }
function World:capture(pattern)
  pattern = normalize(pattern or "/**")
  local nodes = {}
  for _, n in ipairs(self:select(pattern)) do
    local auto = n.path == "/classes" and self.auto_classes and not next(n.c)
    if auto then for name in pairs(n.children) do if ecs.BUILTIN[name] == nil then auto = false end end end
    if not unsaved(n.path) and not auto then nodes[n.path] = ecs.copy(n.c) end
  end
  return { version = VERSION, scope = pattern, nodes = nodes, removed = {} }
end
-- Load data shaped like a blob (World:capture's, or a decoded blob: from
-- the network, so its shape is checked) as load does; its tables are
-- copied, the data stays the caller's.
function World:put(data, at)
  if type(data) == "table" and data.version == nil then data.version = VERSION end
  local d, err = check_data(data)
  if not d then return false, err end
  local nodes = {}
  for p, c in pairs(d.nodes) do nodes[p] = ecs.copy(c) end
  return self:_load_data({ version = d.version, scope = d.scope, removed = d.removed, merge = d.merge, nodes = nodes }, at)
end

function World:_load_data(data, at)
  at = at or "/"

  local paths, keep = {}, {}
  for path in pairs(data.nodes) do
    local full = mount(at, path)
    paths[#paths + 1] = path
    -- keep blob nodes and all their ancestors
    local cur = full
    while cur and not keep[cur] do
      keep[cur] = true
      cur = parent_of(cur)
    end
  end
  table.sort(paths)

  for _, p in ipairs(data.removed) do erase(self, mount(at, p)) end

  if data.scope then
    for _, n in ipairs(self:select(mount(at, data.scope))) do
      if not keep[n.path] and self.nodes[n.path] == n and not unsaved(n.path) then erase(self, n.path) end   -- (/tmp, built-ins survive)
    end
  end

  local merge = data.merge or {}
  for _, path in ipairs(paths) do
    local n = self:spawn(mount(at, path))
    if not self._code_dirty and (has_code(n.c) or has_code(data.nodes[path])) then self._code_dirty = true end
    local drop = merge[path]
    if drop then                                   -- (a node given in part: these components, these gone)
      for k, v in pairs(data.nodes[path]) do n.c[k] = v end
      for _, k in ipairs(drop) do n.c[k] = nil end
    else n.c = data.nodes[path] end
  end
  self._shape = (self._shape or 0) + 1             -- (components came and went: the systems' lists again)
  return true, self
end

-- Compute a patch that turns snapshot `a` into snapshot `b`.
-- a, b: blobs or worlds (worlds are saved with "/**").
-- Returns ok, patch. The patch only carries changed/new nodes plus a
-- `removed` list (no scope), so ecs.load(patch, "/", worldA) makes the
-- nodes of worldA equal to b.
-- fine = true: a node that changed carries only its components that did
-- (and the names of the ones that went: `merge`), not all of them (the
-- network's patches: less to send).
function ecs.diff(a, b, fine)
  return pcall(function()
    local vals = {}
    local function snap(x, keep)
      if type(x) == "table" then
        local ok, blob = x:save("/**"); if not ok then error(blob, 0) end
        x = blob
      end
      local d, err = eval_blob(x); if not d then error(err, 0) end
      local out = {}
      for p, c in pairs(d.nodes) do
        local np = normalize(p)
        out[np] = serialize(c)
        if fine then vals[keep][np] = c end
      end
      return out
    end
    vals.A, vals.B = {}, {}
    local A, B = snap(a, "A"), snap(b, "B")

    -- removed: in A but not in B, skipping ones whose ancestor is removed too
    local removed = {}
    for p in pairs(A) do
      if B[p] == nil then
        local covered, q = false, parent_of(p)
        while q do
          if A[q] and B[q] == nil then covered = true break end
          q = parent_of(q)
        end
        if not covered then removed[#removed + 1] = p end
      end
    end
    table.sort(removed)

    -- changed or new nodes
    local nodes, keys = {}, {}
    for p in pairs(B) do keys[#keys + 1] = p end
    table.sort(keys)
    local merge = {}
    for _, p in ipairs(keys) do
      if A[p] ~= B[p] then
        if fine and A[p] then                      -- (in both: only what changed in it)
          local ca, cb, part, drop = vals.A[p], vals.B[p], {}, {}
          for k, v in pairs(cb) do if ca[k] == nil or serialize(ca[k]) ~= serialize(v) then part[k] = v end end
          for k in pairs(ca) do if cb[k] == nil then drop[#drop + 1] = k end end
          table.sort(drop, function(x, y) return tostring(x) < tostring(y) end)
          nodes[#nodes + 1] = { p, serialize(part) }
          merge[#merge + 1] = { p, drop }
        else nodes[#nodes + 1] = { p, B[p] } end
      end
    end
    return emit(nil, nodes, removed, merge)
  end)
end

-- Module-level functions ----------------------------------------------------

---------------------------------------------------------------------------
-- field-level overrides: what to change on top of a base world, per field
---------------------------------------------------------------------------
-- An overrides blob (plain data, like any blob):
--   return { overrides = 1,
--     nodes   = { ["/scene/box"] = { xform = { x = 380 } } },  -- merged into the node
--     unset   = { ["/scene/box"] = { { "spin" } } },          -- fields removed (key paths)
--     removed = { "/scene/old" },                             -- nodes removed
--   }
-- Unlike diff() (whole nodes), only the fields that differ are stored, so
-- changes to other fields of the base (e.g. a script) still come through.

local function deep_copy(v)
  if type(v) ~= "table" then return v end
  local t = {}
  for k, x in pairs(v) do t[k] = deep_copy(x) end
  return t
end

local function atomic(v) return type(v) ~= "table" or ecs.is_code(v) end

local function same(a, b)
  if a == b then return true end
  if type(a) ~= "table" or type(b) ~= "table" then return false end
  return serialize(a) == serialize(b)
end

-- A class changed: /classes/<name>'s members were `before` (a table: field ->
-- its description). Every node with a `name` component (outside /classes) whose field
-- still holds the class's old value (never overridden: what the class gave
-- it) takes the new one; a value the node changed stays its own. A field the
-- class gained is filled where the node lacks it (like w:spawn). A field the
-- class lost is left alone. -> how many node fields changed
function World:upgrade_class(name, before)
  local cls = self.nodes["/classes/" .. name]
  if not cls or ecs.BUILTIN[name] ~= nil then return 0 end
  local count = 0
  for path, n in pairs(self.nodes) do
    local v = n.c[name]
    if type(v) == "table" and not ecs.is_code(v) and path ~= "/classes" and path:sub(1, 9) ~= "/classes/" then
      for f, d in pairs(cls.c) do
        if f ~= "meta" then                        -- (meta: reserved, not a member)
          local now = ecs.start_value(ecs.member(d))
          local old = nil
          if before[f] ~= nil then old = ecs.start_value(ecs.member(before[f])) end
          if not same(now, old) and ((old == nil and v[f] == nil) or (old ~= nil and same(v[f], old))) then
            v[f] = deep_copy(now)
            count = count + 1
          end
        end
      end
    end
  end
  return count
end

-- fields of b that differ from a -> set (table or nil), unset paths appended
local function field_diff(a, b, prefix, unset)
  local set
  for k, vb in pairs(b) do
    local va = a[k]
    if not same(va, vb) then
      if va ~= nil and not atomic(va) and not atomic(vb) then
        local path = { unpack(prefix) }
        path[#path + 1] = k
        local sub = field_diff(va, vb, path, unset)
        if sub then set = set or {}; set[k] = sub end
      else
        set = set or {}; set[k] = deep_copy(vb)
      end
    end
  end
  for k in pairs(a) do
    if b[k] == nil then
      local path = { unpack(prefix) }
      path[#path + 1] = k
      unset[#unset + 1] = path
    end
  end
  return set
end

-- base, edited: worlds or blobs -> ok, overrides blob
function ecs.overrides(base, edited)
  local ok, err = pcall(function()
    if type(base) == "string" then base = select(2, assert(ecs.load(base))) end
    if type(edited) == "string" then edited = select(2, assert(ecs.load(edited))) end
  end)
  if not ok then return false, err end
  local paths, nodes, unsets, removed = {}, {}, {}, {}
  for p in pairs(edited.nodes) do                  -- (/tmp, /e: never on disk)
    if not is_scratch(p) then paths[#paths + 1] = p end
  end
  table.sort(paths)
  for _, p in ipairs(paths) do
    local nb, na = edited.nodes[p], base.nodes[p]
    if not na then
      nodes[p] = deep_copy(nb.c)
    else
      local u = {}
      local set = field_diff(na.c, nb.c, {}, u)
      if set then nodes[p] = set end
      if #u > 0 then unsets[p] = u end
    end
  end
  local gone = {}
  for p in pairs(base.nodes) do
    if not edited.nodes[p] and p ~= "/" and not is_scratch(p) then gone[#gone + 1] = p end
  end
  table.sort(gone)
  for _, p in ipairs(gone) do                      -- only the top of a removed subtree
    local parent = p:match("^(.*)/[^/]+$")
    if parent == "" then parent = "/" end
    if edited.nodes[parent] then removed[#removed + 1] = p end
  end
  local out = { "return { overrides = 1," }
  local function section(name, t, keys)
    if #keys == 0 then return end
    out[#out + 1] = name .. " = {"
    for _, k in ipairs(keys) do
      out[#out + 1] = "  [" .. serialize(k) .. "] = " .. serialize(t[k]) .. ","
    end
    out[#out + 1] = "},"
  end
  local nk, uk = {}, {}
  for p in pairs(nodes) do nk[#nk + 1] = p end
  for p in pairs(unsets) do uk[#uk + 1] = p end
  table.sort(nk); table.sort(uk)
  section("nodes", nodes, nk)
  section("unset", unsets, uk)
  if #removed > 0 then out[#out + 1] = "removed = " .. serialize(removed) .. "," end
  out[#out + 1] = "}"
  return true, table.concat(out, "\n") .. "\n", #nk + #uk + #removed
end

local function merge(dst, src)
  for k, v in pairs(src) do
    if not atomic(v) and type(dst[k]) == "table" and not ecs.is_code(dst[k]) then merge(dst[k], v)
    else dst[k] = deep_copy(v) end
  end
end

-- apply an overrides blob (or decoded table) to a world. All-or-nothing on
-- format errors; returns ok, err.
function ecs.apply_overrides(w, ov)
  if type(ov) == "string" then
    local t, err = sandbox_eval(ov, "overrides")
    if err then return false, err end
    ov = t
  end
  if type(ov) ~= "table" or ov.overrides ~= 1 then return false, "not an overrides blob" end
  for _, p in ipairs(ov.removed or {}) do
    if w:node(p) then w:remove(p) end
  end
  for p, u in pairs(ov.unset or {}) do
    local n = w:node(p)
    for _, path in ipairs(n and u or {}) do
      local t = n.c
      for i = 1, #path - 1 do t = type(t) == "table" and t[path[i]] or nil end
      if type(t) == "table" then t[path[#path]] = nil end
    end
  end
  local ps = {}
  for p in pairs(ov.nodes or {}) do ps[#ps + 1] = p end
  table.sort(ps)                                   -- parents before children
  for _, p in ipairs(ps) do
    local n = w:node(p) or w:spawn(p, {})
    merge(n.c, ov.nodes[p])
  end
  return true
end

function ecs.save(world, pattern, disk) return world:save(pattern, disk) end

function ecs.load(blob, at, world)
  return (world or ecs.world()):load(blob, at)
end

function ecs.tick(world, pattern, dt) return world:tick(pattern, dt) end

ecs.patch = ecs.load   -- alias, reads better for diffs: ecs.patch(patch, "/", w)

-- Debug ---------------------------------------------------------------------

function World:dump(target)
  local out = {}
  self:walk(target or "/", function(n, d)
    local keys = {}
    for k in pairs(n.c) do keys[#keys + 1] = k end
    table.sort(keys)
    local label = n == self.root and "/" or n.name
    local comps = #keys > 0 and ("  {" .. table.concat(keys, ", ") .. "}") or ""
    out[#out + 1] = string.rep("  ", d) .. label .. comps
  end)
  return table.concat(out, "\n")
end

return ecs
