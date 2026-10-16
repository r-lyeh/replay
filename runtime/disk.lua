-- disk.lua
-- The world as a folder tree:  node = folder,  component = <name>.lua leaf
-- (or <name>.hurdy: code in hurdy, compiled to Lua; see ecs.languages).
--
--   /players/p2          ->  <root>/players/p2/
--   /players/p2 .pos     ->  <root>/players/p2/pos.lua   ("return { x = 1, y = 2 }")
--
-- Leaves are plain data, read back in an empty sandbox (no code runs with
-- any power). Files that aren't *.lua, and names we would never write
-- (".workspace.lua", ".git"), are ignored and never deleted. Flushing
-- rewrites a leaf only when its value changed, so hand formatting and
-- comments survive.
-- A leaf that isn't plain data (it returns a function, or needs globals
-- like math) is a code leaf: it is kept as source, ecs.code(src), and
-- becomes a system when the world ticks. It is written back verbatim.
--
--   local d = disk.new("world")
--   ok, err       = d:flush(world, "/**")      -- world -> folder (mirror)
--   ok, blob      = d:read("/players/p2/**")   -- folder -> scoped blob
--   ok, changed   = d:pull(world, "/players/p2/**")  -- read + apply
--   paths         = d:changes("/**")           -- nodes edited on disk since flush
--
-- Names are escaped so any node/component name is a safe file name on every
-- OS: anything outside [A-Za-z0-9_-] becomes %XX, e.g. "x.lua" -> "x%2Elua".
-- Known limit: Windows/macOS folders are case-insensitive, so "Mario" and
-- "mario" under the same parent would collide.

local ecs = require("ecs")
local fs = require("fs")

local disk = {}
local Disk = {}
Disk.__index = Disk

---------------------------------------------------------------------------
-- names
---------------------------------------------------------------------------

local RESERVED = { CON = 1, PRN = 1, AUX = 1, NUL = 1 }

local function hex(c) return string.format("%%%02X", c:byte()) end

function disk.encode(name)
  local s = tostring(name):gsub("[^%w_%-]", hex)
  local up = s:upper()
  if RESERVED[up] or up:match("^COM%d$") or up:match("^LPT%d$") then
    s = hex(s:sub(1, 1)) .. s:sub(2)             -- "CON" -> "%43ON"
  end
  return s
end

function disk.decode(s)
  return (s:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end))
end

-- Is this a file/folder name we could have written? ("pos.lua", "%43ON")
-- Anything else (".workspace.lua", ".git", "Notes.txt") isn't part of
-- the world: never read as a node/component, never deleted.
local function canonical(name) return disk.encode(disk.decode(name)) == name end
-- Leaves: name.lua (data or Lua code), or name.<lang> for code in another
-- language that compiles to Lua (name.hurdy, see ecs.languages).
-- leaf file name -> component name (encoded), language | nil
local function leaf_parts(name)
  local stem, ext = name:match("^(.+)%.(%w+)$")
  if not stem or not canonical(stem) then return nil end
  if ext == "lua" or ecs.languages[ext] then return stem, ext end
  return nil
end
local function is_leaf(e) return not e.dir and leaf_parts(e.name) ~= nil end
local function is_node_dir(e) return e.dir and canonical(e.name) end

-- the value a leaf file holds: data, or ecs.code(src[, lang]) for code
local function leaf_value(src, file, lang)
  if lang and lang ~= "lua" then                   -- always code
    local chunk, cerr = ecs.compile(src, file, nil, lang)
    if not chunk then return nil, cerr end
    return ecs.code(src, lang)
  end
  local v, derr = ecs.decode(src, file)
  if derr or not pcall(ecs.serialize, v) then      -- not plain data: code?
    local chunk, cerr = ecs.compile(src, file)
    if not chunk then return nil, cerr end         -- syntax error
    v = ecs.code(src)
  end
  return v
end

local function segments(path)
  local out = {}
  for p in path:gmatch("[^/]+") do out[#out + 1] = p end
  return out
end

-- folder for a node path
function Disk:dir(path)
  local parts = { self.root }
  for _, seg in ipairs(segments(path)) do parts[#parts + 1] = disk.encode(seg) end
  return fs.join(table.concat(parts, "/"))
end

local function child_path(path, name)
  return path == "/" and ("/" .. name) or (path .. "/" .. name)
end

-- literal prefix of a pattern: "/players/p*/**" -> "/players"
local function prefix(pattern)
  local out = {}
  for _, seg in ipairs(segments(ecs.normalize(pattern))) do
    if seg:find("[%*%?]") then break end
    out[#out + 1] = seg
  end
  return "/" .. table.concat(out, "/")
end

---------------------------------------------------------------------------

function disk.new(root)
  return setmetatable({ root = root, flushed = {}, leaves = {} }, Disk)
end

-- What the folder holds, in one string: every folder and leaf file's name,
-- with each file's time and size. The same string: nothing changed on
-- disk (no file is opened). nil: this fs can't tell (read it all).
function Disk:stamp(pattern)
  local parts, ok = {}, true
  local function walk(dirpath)
    for _, e in ipairs(fs.list(dirpath)) do
      if is_node_dir(e) then
        parts[#parts + 1] = e.name .. "/"
        walk(fs.join(dirpath, e.name))
        parts[#parts + 1] = ".."
      elseif is_leaf(e) then
        if not e.mtime then ok = false return end
        parts[#parts + 1] = e.name .. " " .. e.mtime .. " " .. e.size
      end
    end
  end
  local start = self:dir(prefix(ecs.normalize(pattern or "/**")))
  if fs.isdir(start) then walk(start) end
  return ok and table.concat(parts, "\n") or nil
end

-- Read one folder: components from *.lua leaves, child folder names.
local function read_folder(self, dirpath, nodepath)
  local comps, kids = {}, {}
  for _, e in ipairs(fs.list(dirpath)) do
    if is_node_dir(e) then
      kids[#kids + 1] = e.name
    elseif is_leaf(e) then
      local file = fs.join(dirpath, e.name)
      local stem, lang = leaf_parts(e.name)
      local name = disk.decode(stem)
      if comps[name] ~= nil then return nil, nil, file .. ": another leaf is already named " .. name end
      local c = self.leaves[file]                  -- (unchanged since the last read: its value again, not read nor compiled)
      local v
      if c and e.mtime and c.mtime == e.mtime and c.size == e.size then
        v = ecs.copy(c.v)
      else
        local src, err = fs.read(file)
        if not src then return nil, nil, file .. ": " .. tostring(err) end
        local verr
        v, verr = leaf_value(src, file, lang)
        if verr then return nil, nil, verr end
        if e.mtime then self.leaves[file] = { mtime = e.mtime, size = e.size, v = ecs.copy(v) } end
      end
      if v ~= nil then comps[name] = v end
    end
  end
  return comps, kids
end

-- Folder -> blob with scope = pattern. All-or-nothing: any bad leaf fails
-- the whole read with "file: error".
function Disk:read(pattern)
  pattern = ecs.normalize(pattern or "/**")
  return pcall(function()
    local w = ecs.world()
    local function walk(nodepath)
      local dirpath = self:dir(nodepath)
      local comps, kids, err = read_folder(self, dirpath, nodepath)
      if err then error(err, 0) end
      if ecs.match(pattern, nodepath) then w:spawn(nodepath, comps) end
      for _, k in ipairs(kids) do walk(child_path(nodepath, disk.decode(k))) end
    end
    local start = prefix(pattern)
    if fs.isdir(self:dir(start)) then walk(start) end
    local ok, blob = w:save(pattern, true)          -- (/tmp, /e on disk: ignored)
    if not ok then error(blob, 0) end
    return blob
  end)
end

-- World -> folder, for nodes matching `pattern`. Mirrors: leaves and
-- folders (within the pattern) that no longer exist in the world are
-- removed; files that aren't *.lua are left alone. Unchanged files are
-- not rewritten, so their timestamps stay put.
function Disk:flush(world, pattern)
  pattern = ecs.normalize(pattern or "/**")
  return pcall(function()
    local live = {}
    local nodes = {}
    for _, n in ipairs(world:select(pattern)) do   -- (/tmp, /e: never written)
      if not ecs.is_scratch(n.path) then nodes[#nodes + 1] = n end
    end
    for _, n in ipairs(nodes) do
      live[n.path] = true
      local dirpath = self:dir(n.path)
      fs.mkdir(dirpath)
      local want = {}
      for name, v in pairs(n.c) do
        if type(name) ~= "string" then error(n.path .. ": component names must be strings", 0) end
        local code, lang = ecs.code_source(v)
        if code then                               -- code leaf: the source itself
          want[disk.encode(name) .. "." .. lang] = code
        else
          local src, err = ecs.pretty(v)
          if not src then error(n.path .. "." .. name .. ": " .. err, 0) end
          want[disk.encode(name) .. ".lua"] = "return " .. src .. "\n"
        end
      end
      for _, e in ipairs(fs.list(dirpath)) do             -- stale leaves
        if is_leaf(e) and not want[e.name] then
          fs.rmfile(fs.join(dirpath, e.name))
        end
      end
      for file, src in pairs(want) do
        local full = fs.join(dirpath, file)
        local old = fs.read(full)
        -- rewrite only if the VALUE changed: a hand-formatted (commented)
        -- leaf that still holds the same data keeps its formatting
        local same = old == src
        if not same and old then
          local _, lang = leaf_parts(file)
          local ov = leaf_value(old, full, lang)
          local nv = leaf_value(src, full, lang)
          if ov ~= nil and nv ~= nil then
            if ecs.is_code(ov) or ecs.is_code(nv) then same = false
            else same = ecs.serialize(ov) == ecs.serialize(nv) end
          end
        end
        if not same then assert(fs.write(full, src)) end
      end
    end

    -- stale folders: walk the disk under the prefix, remove matching nodes
    -- the world doesn't have (their .lua leaves, then the folder if empty)
    local function prune(nodepath)
      local dirpath = self:dir(nodepath)
      for _, e in ipairs(fs.list(dirpath)) do
        if is_node_dir(e) then prune(child_path(nodepath, disk.decode(e.name))) end
      end
      if ecs.match(pattern, nodepath) and not live[nodepath] and nodepath ~= "/" and not ecs.is_scratch(nodepath) then
        for _, e in ipairs(fs.list(dirpath)) do
          if is_leaf(e) then fs.rmfile(fs.join(dirpath, e.name)) end
        end
        if #fs.list(dirpath) == 0 then fs.rmdir(dirpath) end
      end
    end
    local start = prefix(pattern)
    if fs.isdir(self:dir(start)) then prune(start) end

    local ok, blob = world:save(pattern, true)
    if not ok then error(blob, 0) end
    self.flushed[pattern] = blob
    return true
  end)
end

-- Read the folder and apply it to the world. The pattern is authoritative:
-- nodes deleted on disk are deleted in the world. Returns ok, changed.
function Disk:pull(world, pattern)
  pattern = ecs.normalize(pattern or "/**")
  local ok, blob = self:read(pattern)
  if not ok then return false, blob end
  local _, current = world:save(pattern, true)
  if blob == current then return true, false end
  local ok2, err = world:load(blob, "/")
  if not ok2 then return false, err end
  return true, true
end

-- Node paths edited on disk (added, changed or removed) since the last
-- flush of `pattern`. Returns list | nil, err.
function Disk:changes(pattern)
  pattern = ecs.normalize(pattern or "/**")
  local base = self.flushed[pattern]
  if not base then return nil, "pattern was never flushed: " .. pattern end
  local ok, now = self:read(pattern)
  if not ok then return nil, now end
  local ok2, patch = ecs.diff(base, now)
  if not ok2 then return nil, patch end
  local p = ecs.decode(patch)
  local out = {}
  for _, path in ipairs(p.removed or {}) do out[#out + 1] = path end
  for path in pairs(p.nodes) do out[#out + 1] = path end
  table.sort(out)
  return out
end

return disk
