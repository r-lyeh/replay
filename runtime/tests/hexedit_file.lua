-- hexedit_file.lua: plugins/hexedit/hexfile.lua headless - a file read in
-- chunks (tiny ones here, so matches and edits fall across their edges),
-- edits kept aside and saved in place, find forward / back, replace all
-- (the same length: edits; another: the file written again, streamed).
-- Run from runtime/tests: luajit hexedit_file.lua (or lua5.4)
local hex = dofile("../../plugins/hexedit/hexfile.lua")
local ok, bad = 0, 0
local function check(c, what) if c then ok = ok + 1 else bad = bad + 1; print("FAIL: " .. what) end end

local path = os.tmpname()
local function write(s) local f = assert(io.open(path, "wb")); f:write(s); f:close() end
local function slurp() local f = assert(io.open(path, "rb")); local s = f:read("*a"); f:close(); return s end

-- a file with a pattern on the chunks' edges (chunk = 16 bytes)
local body = {}
for i = 0, 255 do body[#body + 1] = string.char(i) end
local data = table.concat(body) .. "xx@#@#yy" .. string.rep("-", 30) .. "@#@#" .. string.rep(".", 13) .. "@#@#"
write(data)
local f = assert(hex.open(path, { chunk = 16 }))
check(f.size == #data, "size")
check(f:read(0, 4) == "\0\1\2\3", "read the start")
check(f:read(14, 4) == "\14\15\16\17", "read across a chunk edge")
check(f:read(#data - 2, 10) == "@#", "read past the end: what's there")
check(f:byte(255) == 255 and f:byte(#data) == nil, "byte")

-- find: forward, back, across edges
local a1 = f:find("@#@#", 0)
check(a1 == 258, "find the first (" .. tostring(a1) .. ")")
local a2 = f:find("@#@#", a1 + 1)
check(a2 == 258 + 4 + 2 + 30, "find the next")
local a3 = f:find("@#@#", a2 + 1)
check(a3 == #data - 4, "find the last, at the very end")
check(f:find("@#@#", a3 + 1) == nil, "nothing after it")
check(f:find("@#@#", a3, true) == a2, "back: the one before")
check(f:find("@#@#", #data, true) == a3, "back from the end")
check(f:find("\15\16", 0) == 15, "a match split by a chunk edge")
check(f:find("nope", 0) == nil, "no match")

-- patterns
check(hex.pattern("DE AD be ef") == "\222\173\190\239", "hex pattern")
check(select(2, hex.pattern("hello")) == "text", "text pattern")
check(hex.pattern('"ab cd"') == "ab cd", "quoted text")
check(hex.to_hex("\1\255") == "01 FF", "to_hex")

-- edits: kept aside, read through, undone, saved in place
local was = f:set(3, 0x41)
check(was == nil and f:byte(3) == 0x41 and f.nedits == 1, "an edit")
check(f:read(2, 3) == "\2A\4", "read sees it")
check(slurp():byte(4) == 3, "the disk doesn't, yet")
f:set(3, 3)
check(f.nedits == 0, "set back to the disk's: no edit")
f:set(16, 0x42); f:set(17, 0x43)
check(f:find("BC", 0) == 16, "find sees edits")
local w = f:set(17, 0x44)
f:unset(17, w)
check(f:byte(17) == 0x43 and f.nedits == 2, "unset: undo")
check(f:save(), "save")
local disk = slurp()
check(disk:sub(17, 18) == "BC" and #disk == #data, "saved in place, same size")
check(f.nedits == 0 and f:read(16, 2) == "BC", "reopened, clean")

-- replace all, the same length: edits
local n = f:replace_all("@#@#", "%&%&")
check(n == 3 and f.nedits == 12, "replace all (same length): 3, as edits")
check(f:find("%&%&", 0) == a1, "... read back")
f:save()
check(not slurp():find("@#@#", 1, true), "... saved")

-- replace all, another length: the file written again (streamed)
local n2 = f:replace_all("%&%&", "\0\0")
check(n2 == 3, "replace all (shorter): 3")
check(f.size == #data - 6 and f.size == #slurp(), "the file shrank")
check(not slurp():find("%&%&", 1, true), "... the old bytes out")
local n3 = f:replace_all("\0\0", "LONGER!")
check(n3 == 3 and f.size == #data + 9 and f.size == #slurp(), "replace all (longer)")
check(slurp():sub(-7) == "LONGER!", "... the last one, at the very end")

-- a bigger file, default chunk size: the edges of 1 MiB chunks
f:close()
local big = string.rep("a", hex.CHUNK - 2) .. "NEEDLE" .. string.rep("b", 100)
write(big)
f = assert(hex.open(path))
check(f:find("NEEDLE", 0) == hex.CHUNK - 2, "1 MiB edge: found")
f:set(hex.CHUNK - 1, 0x21)
check(f:read(hex.CHUNK - 2, 3) == "N!E", "1 MiB edge: an edit read back")
local stops = 0
f:find("zzz", 0, false, function() stops = stops + 1 end)
check(stops >= 1, "step: called per chunk")
check(f:find("zzz", 0, false, function() return true end) == nil, "step: stops")
local v = f:values(0)
check(v.u8 == 97 and (not string.unpack or v.u16 == 0x6161), "values")
f:close()
os.remove(path)
print(string.format("hexedit file: %s", bad == 0 and ("all ok (" .. ok .. ")") or (bad .. " failed")))
