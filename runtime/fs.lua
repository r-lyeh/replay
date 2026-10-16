-- fs.lua
-- Tiny filesystem layer: the few directory operations plain Lua lacks.
--
-- Backends, picked in order:
--   1. `hostfs`, a global table the host program registers (replay.c does,
--      using SDL3). Fast and portable.
--   2. LuaFileSystem (`lfs`), if installed.
--   3. Shell fallback via io.popen / os.execute (Windows cmd or POSIX sh).
--      Works everywhere plain Lua runs, but spawns a process per call.
--
-- API (paths use "/" or "\"; results never include "." or ".."):
--   fs.list(dir)     -> { {name=, dir=true|false}, ... } sorted by name, or {} if missing
--                       (the host backend: files also have mtime= and size=)
--   fs.isdir(path)   -> bool
--   fs.mkdir(path)   -> creates path and missing parents
--   fs.rmfile(path)  -> removes a file
--   fs.rmdir(path)   -> removes an EMPTY directory
--   fs.read(path)    -> string | nil, err
--   fs.write(path, s)-> true | nil, err
--   fs.join(a, b, ...)
--   fs.backend       -> "host" | "lfs" | "shell"

local fs = {}

local WIN = package.config:sub(1, 1) == "\\"

function fs.join(...)
  local parts = {}
  for i = 1, select("#", ...) do
    local p = select(i, ...)
    if p ~= nil and p ~= "" then parts[#parts + 1] = p end
  end
  local s = table.concat(parts, "/")
  return (s:gsub("[/\\]+", "/"))
end

function fs.read(path)
  local f, err = io.open(path, "rb")
  if not f then return nil, err end
  local s = f:read("*a")
  f:close()
  return s
end

function fs.write(path, s)
  local f, err = io.open(path, "wb")
  if not f then return nil, err end
  f:write(s)
  f:close()
  return true
end

local function sorted(list)
  table.sort(list, function(a, b) return a.name < b.name end)
  return list
end

---------------------------------------------------------------------------
-- backends
---------------------------------------------------------------------------

local host = rawget(_G, "hostfs")
local ok_lfs, lfs = false, nil
if not host then ok_lfs, lfs = pcall(require, "lfs") end

if host then
  fs.backend = "host"
  function fs.list(dir) return sorted(host.list(dir) or {}) end
  function fs.isdir(p) return host.isdir(p) and true or false end
  function fs.mkdir(p) return host.mkdir(p) end
  function fs.rmfile(p) return host.remove(p) end
  function fs.rmdir(p) return host.remove(p) end
  function fs.rename(a, b) return host.rename(a, b) end

elseif ok_lfs and lfs then
  fs.backend = "lfs"
  function fs.isdir(p) return lfs.attributes(p, "mode") == "directory" end
  function fs.list(dir)
    local out = {}
    if not fs.isdir(dir) then return out end
    for name in lfs.dir(dir) do
      if name ~= "." and name ~= ".." then
        out[#out + 1] = { name = name, dir = fs.isdir(fs.join(dir, name)) }
      end
    end
    return sorted(out)
  end
  function fs.mkdir(p)
    local cur = p:match("^/") and "/" or ""
    for part in p:gmatch("[^/\\]+") do
      cur = cur == "" and part or fs.join(cur, part)
      if not fs.isdir(cur) then lfs.mkdir(cur) end
    end
    return fs.isdir(p)
  end
  function fs.rmfile(p) return os.remove(p) end
  function fs.rmdir(p) return lfs.rmdir(p) end
  function fs.rename(a, b) return os.rename(a, b) and true or false end

else
  fs.backend = "shell"
  local function q(p)                        -- quote for the shell
    if WIN then return '"' .. p:gsub("/", "\\") .. '"' end
    return "'" .. p:gsub("'", "'\\''") .. "'"
  end
  local function lines(cmd)
    local out = {}
    local h = io.popen(cmd)
    if not h then return out end
    for raw in h:lines() do
      local l = raw:gsub("\r$", "")
      if l ~= "" then out[#out + 1] = l end
    end
    h:close()
    return out
  end
  local function exec(cmd)
    local r = os.execute(cmd)
    return r == true or r == 0
  end

  function fs.isdir(p)
    if WIN then return exec("if exist " .. q(p .. "/") .. " (exit 0) else (exit 1)") end
    return exec("test -d " .. q(p))
  end

  function fs.list(dir)
    local out = {}
    if WIN then
      for _, n in ipairs(lines("dir /b /ad " .. q(dir) .. " 2>nul")) do out[#out + 1] = { name = n, dir = true } end
      for _, n in ipairs(lines("dir /b /a-d " .. q(dir) .. " 2>nul")) do out[#out + 1] = { name = n, dir = false } end
    else
      for _, n in ipairs(lines("ls -1Ap " .. q(dir) .. " 2>/dev/null")) do
        if n:sub(-1) == "/" then out[#out + 1] = { name = n:sub(1, -2), dir = true }
        else out[#out + 1] = { name = n, dir = false } end
      end
    end
    return sorted(out)
  end

  function fs.mkdir(p)
    if WIN then return exec("if not exist " .. q(p .. "/") .. " mkdir " .. q(p) .. " >nul 2>nul") end
    return exec("mkdir -p " .. q(p))
  end

  function fs.rmfile(p) return os.remove(p) end

  function fs.rmdir(p)
    if WIN then return exec("rmdir " .. q(p) .. " 2>nul") end
    return os.remove(p)
  end

  function fs.rename(a, b) return os.rename(a, b) and true or false end
end

return fs
