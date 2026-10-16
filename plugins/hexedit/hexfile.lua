-- hexfile.lua - a binary file of any size, read off disk in chunks (1 MiB by
-- default; a few kept, the least used dropped): the hex editor's model. No
-- lite here (the editor draws it; a test checks it). Offsets are 0-based.
--
--   local hex = require "hexfile"
--   local f = assert(hex.open(path))           -- f.size: its bytes
--   f:read(off, n)       -> those bytes (a string), the edits in
--   f:byte(off)          -> one (nil: past the end)
--   f:set(off, b)        -> an edit (kept aside until save; undo: f:unset)
--   f:find(pat, from, back, step) -> the next match's offset (back: the one before), or nil
--   f:replace_all(pat, rep, step) -> how many (same length: edits; else
--                           the file is written again, streamed, at once)
--   f:save()             -> the edits written in place (only those bytes)
--   f:close()
-- step(done, total): called once a chunk (the editor yields there, shows
-- the progress; return true: stop).
local M = {}
local unpack = table.unpack or unpack            -- (luajit / 5.1 too)
M.CHUNK = 1024 * 1024
M.KEEP = 8                                         -- chunks kept in memory

local F = {}
F.__index = F

function M.open(path, opts)
  local h, err = io.open(path, "rb")
  if not h then return nil, err end
  local size = h:seek("end")
  local f = setmetatable({ path = path, h = h, size = size or 0, chunk = (opts and opts.chunk) or M.CHUNK,
                           cache = {}, used = {}, tick = 0, edits = {}, nedits = 0 }, F)
  return f
end
function F:close() if self.h then self.h:close(); self.h = nil end end
function F:reopen()                                -- (after the file was written again)
  self:close()
  local h, err = io.open(self.path, "rb")
  if not h then return nil, err end
  self.h, self.size = h, h:seek("end") or 0
  self.cache, self.used = {}, {}
  return true
end

-- a chunk, from the cache or the disk
function F:_chunk(i)
  local c = self.cache[i]
  self.tick = self.tick + 1
  if c then self.used[i] = self.tick return c end
  self.h:seek("set", i * self.chunk)
  c = self.h:read(self.chunk) or ""
  local n = 0
  for _ in pairs(self.cache) do n = n + 1 end
  if n >= M.KEEP then                              -- (full: the least used goes)
    local old, oldest = nil, math.huge
    for k, t in pairs(self.used) do if t < oldest then old, oldest = k, t end end
    if old then self.cache[old], self.used[old] = nil, nil end
  end
  self.cache[i], self.used[i] = c, self.tick
  return c
end

-- bytes as on disk (no edits)
function F:raw(off, n)
  if off < 0 then n = n + off; off = 0 end
  if off >= self.size or n <= 0 then return "" end
  n = math.min(n, self.size - off)
  local parts, cs = {}, self.chunk
  while n > 0 do
    local i = math.floor(off / cs)
    local at = off - i * cs
    local c = self:_chunk(i)
    local take = math.min(n, #c - at)
    if take <= 0 then break end
    parts[#parts + 1] = c:sub(at + 1, at + take)
    off, n = off + take, n - take
  end
  return table.concat(parts)
end

-- bytes with the edits
function F:read(off, n)
  local s = self:raw(off, n)
  if self.nedits == 0 or #s == 0 then return s end
  local last, offs, ed = off + #s - 1, {}, self.edits
  if self.nedits < #s then                         -- (few edits: look each one up)
    for o in pairs(ed) do if o >= off and o <= last then offs[#offs + 1] = o end end
    table.sort(offs)
  else
    for o = off, last do if ed[o] then offs[#offs + 1] = o end end
  end
  if #offs == 0 then return s end
  local out, prev = {}, 1                          -- (the bytes between the edits as they are, the edits spliced in)
  for _, o in ipairs(offs) do
    local k = o - off + 1
    out[#out + 1] = s:sub(prev, k - 1)
    out[#out + 1] = string.char(ed[o])
    prev = k + 1
  end
  out[#out + 1] = s:sub(prev)
  return table.concat(out)
end
function F:byte(off)
  if off < 0 or off >= self.size then return nil end
  local b = self.edits[off]
  if b then return b end
  return self:raw(off, 1):byte()
end
function F:edited(off) return self.edits[off] ~= nil end

function F:set(off, b)                             -- -> the edit it replaced (nil: none), for undo
  if off < 0 or off >= self.size then return end
  local was = self.edits[off]
  local disk = self:raw(off, 1):byte()
  if b == disk then
    if was then self.edits[off] = nil; self.nedits = self.nedits - 1 end
  else
    if not was then self.nedits = self.nedits + 1 end
    self.edits[off] = b
  end
  return was
end
function F:unset(off, was)                         -- (undo: back to what it was before set)
  local cur = self.edits[off]
  if cur and not was then self.nedits = self.nedits - 1 end
  if not cur and was then self.nedits = self.nedits + 1 end
  self.edits[off] = was
end

-- the edits written into the file, in place: only those bytes (any size)
function F:save()
  if self.nedits == 0 then return true end
  local offs = {}
  for o in pairs(self.edits) do offs[#offs + 1] = o end
  table.sort(offs)
  self:close()
  local w, err = io.open(self.path, "r+b")
  if not w then self:reopen() return nil, err end
  local i = 1
  while i <= #offs do                              -- runs of neighbours: one write each
    local j = i
    while j < #offs and offs[j + 1] == offs[j] + 1 and j - i < 4095 do j = j + 1 end
    local bytes = {}
    for k = i, j do bytes[#bytes + 1] = self.edits[offs[k]] end
    w:seek("set", offs[i])
    w:write(string.char(unpack(bytes)))
    i = j + 1
  end
  w:close()
  self.edits, self.nedits = {}, 0
  return self:reopen()
end

-- what to look for: "DE AD be ef" / "deadbeef" (hex), or text ("abc", quoted
-- or not); -> the bytes, and "hex" / "text"
function M.pattern(s)
  s = tostring(s or "")
  local q = s:match('^"(.*)"$') or s:match("^'(.*)'$")
  if q then return q, "text" end
  local digits = s:gsub("%s", "")
  if #digits > 0 and #digits % 2 == 0 and digits:match("^%x+$") then
    return (digits:gsub("%x%x", function(h) return string.char(tonumber(h, 16)) end)), "hex"
  end
  return s, "text"
end
function M.to_hex(s, sep)
  return (s:gsub(".", function(c) return string.format("%02X", c:byte()) .. (sep or " ") end)):gsub("%s$", "")
end

-- the next match at or after `from` (back: the last one before `from`)
function F:find(pat, from, back, step)
  local n, cs = #pat, self.chunk
  if n == 0 or n > self.size then return nil end
  if not back then
    local off = math.max(0, from or 0)
    while off <= self.size - n do
      local s = self:read(off, cs + n - 1)
      local j = s:find(pat, 1, true)
      if j then return off + j - 1 end
      off = off + cs
      if step and step(math.min(off, self.size), self.size) then return nil, "stopped" end
    end
    return nil
  end
  local stop = math.min((from or self.size) - 1, self.size - n)   -- (a match starting before `from`)
  local hi = stop
  while hi >= 0 do
    local lo = math.max(0, hi - cs + 1)
    local s = self:read(lo, hi - lo + n)
    local best, i = nil, 1
    while true do
      local j = s:find(pat, i, true)
      if not j or lo + j - 1 > hi then break end
      best, i = j, j + 1
    end
    if best then return lo + best - 1 end
    hi = lo - 1
    if step and step(self.size - math.max(0, hi), self.size) then return nil, "stopped" end
  end
  return nil
end

-- every match replaced. The same length: edits (save writes them); another
-- length: the file is written again (a copy beside it, streamed, then put in
-- its place), the edits made so far in it too. -> count | nil, err
function F:replace_all(pat, rep, step)
  local n, cs = #pat, self.chunk
  if n == 0 then return 0 end
  if #rep == n then
    local count, off = 0, 0
    while true do
      local at = self:find(pat, off, false, step)
      if not at then break end
      for k = 1, n do self:set(at + k - 1, rep:byte(k)) end
      count, off = count + 1, at + n
    end
    return count
  end
  local tmp = self.path .. ".hexedit~"
  local w, err = io.open(tmp, "wb")
  if not w then return nil, err end
  local count, pos, carry = 0, 0, ""
  while pos < self.size or #carry > 0 do
    local data = carry .. self:read(pos, cs)
    pos = pos + cs
    local last = pos >= self.size
    local out, i = {}, 1
    while true do
      local j = data:find(pat, i, true)
      if not j then break end
      out[#out + 1] = data:sub(i, j - 1)
      out[#out + 1] = rep
      count, i = count + 1, j + n
    end
    if last then out[#out + 1] = data:sub(i); carry = ""
    else
      local keep = math.max(i, #data - n + 2)      -- (the tail a match could still start in: next time)
      out[#out + 1] = data:sub(i, keep - 1)
      carry = data:sub(keep)
    end
    w:write(table.concat(out))
    if step and step(math.min(pos, self.size), self.size) then w:close(); os.remove(tmp); return nil, "stopped" end
    if last then break end
  end
  w:close()
  self:close()
  local ok, e2 = os.remove(self.path)
  if ok then ok, e2 = os.rename(tmp, self.path) end
  if not ok then self:reopen(); return nil, e2 end
  self.edits, self.nedits = {}, 0
  self:reopen()
  return count
end

-- a value at off, little-endian unless big: u8 i8 u16 i16 u32 i32 f32 f64
function F:values(off, big)
  local s = self:read(off, 8)
  local e = big and ">" or "<"
  local v = {}
  if #s >= 1 then v.u8 = s:byte(1); v.i8 = v.u8 >= 128 and v.u8 - 256 or v.u8 end
  if string.unpack then
    if #s >= 2 then v.u16 = string.unpack(e .. "I2", s); v.i16 = string.unpack(e .. "i2", s) end
    if #s >= 4 then v.u32 = string.unpack(e .. "I4", s); v.i32 = string.unpack(e .. "i4", s); v.f32 = string.unpack(e .. "f", s) end
    if #s >= 8 then v.f64 = string.unpack(e .. "d", s) end
  end
  return v
end

return M
