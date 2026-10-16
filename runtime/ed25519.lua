-- ed25519.lua - signatures in plain Lua (LuaJIT and Lua 5.4 alike, no 64-bit
-- integers needed): SHA-512 on pairs of 32-bit halves, and Ed25519 (RFC 8032)
-- on field elements of 16 limbs of 16 bits held in doubles, as TweetNaCl does
-- them (public domain; the products stay under 2^53). For who's who between
-- peers (runtime/players.lua: a peer ID is its public key's hash), not for
-- secrets: not constant-time, and slow-ish (a signature: a few ms in LuaJIT,
-- tens in Lua 5.4).
--
--   local E = require "ed25519"
--   E.sha512(s) -> 64 bytes       E.keypair(seed32) -> public32, seed32
--   E.sign(seed32, msg) -> 64 bytes (the public key is worked out from the seed)
--   E.verify(public32, msg, sig64) -> true / false
--   E.hex(s) / E.unhex(h)
local E = {}
local floor = math.floor

-- 32-bit bit operations, unsigned results, on either Lua
local band, bor, bxor, bnot, shr, shl
if rawget(_G, "bit") or (pcall(require, "bit") and package.loaded.bit) then
  local b = rawget(_G, "bit") or require("bit")
  local function u(x) return x % 4294967296 end
  band = function(a, c) return u(b.band(a, c)) end
  bor = function(a, c) return u(b.bor(a, c)) end
  bxor = function(a, c) return u(b.bxor(a, c)) end
  bnot = function(a) return u(b.bnot(a)) end
  shr = function(a, n) return u(b.rshift(a, n)) end
  shl = function(a, n) return u(b.lshift(a, n)) end
else                                               -- (Lua 5.3+: its own operators; loaded, so LuaJIT never parses them)
  band = load("return function(a, c) return (a & c) & 0xffffffff end")()
  bor = load("return function(a, c) return (a | c) & 0xffffffff end")()
  bxor = load("return function(a, c) return (a ~ c) & 0xffffffff end")()
  bnot = load("return function(a) return (~a) & 0xffffffff end")()
  shr = load("return function(a, n) return (a & 0xffffffff) >> n end")()
  shl = load("return function(a, n) return (a << n) & 0xffffffff end")()
end

-- SHA-512 ---------------------------------------------------------------------
local K = {
0x428a2f98,0xd728ae22, 0x71374491,0x23ef65cd, 0xb5c0fbcf,0xec4d3b2f, 0xe9b5dba5,0x8189dbbc,
0x3956c25b,0xf348b538, 0x59f111f1,0xb605d019, 0x923f82a4,0xaf194f9b, 0xab1c5ed5,0xda6d8118,
0xd807aa98,0xa3030242, 0x12835b01,0x45706fbe, 0x243185be,0x4ee4b28c, 0x550c7dc3,0xd5ffb4e2,
0x72be5d74,0xf27b896f, 0x80deb1fe,0x3b1696b1, 0x9bdc06a7,0x25c71235, 0xc19bf174,0xcf692694,
0xe49b69c1,0x9ef14ad2, 0xefbe4786,0x384f25e3, 0x0fc19dc6,0x8b8cd5b5, 0x240ca1cc,0x77ac9c65,
0x2de92c6f,0x592b0275, 0x4a7484aa,0x6ea6e483, 0x5cb0a9dc,0xbd41fbd4, 0x76f988da,0x831153b5,
0x983e5152,0xee66dfab, 0xa831c66d,0x2db43210, 0xb00327c8,0x98fb213f, 0xbf597fc7,0xbeef0ee4,
0xc6e00bf3,0x3da88fc2, 0xd5a79147,0x930aa725, 0x06ca6351,0xe003826f, 0x14292967,0x0a0e6e70,
0x27b70a85,0x46d22ffc, 0x2e1b2138,0x5c26c926, 0x4d2c6dfc,0x5ac42aed, 0x53380d13,0x9d95b3df,
0x650a7354,0x8baf63de, 0x766a0abb,0x3c77b2a8, 0x81c2c92e,0x47edaee6, 0x92722c85,0x1482353b,
0xa2bfe8a1,0x4cf10364, 0xa81a664b,0xbc423001, 0xc24b8b70,0xd0f89791, 0xc76c51a3,0x0654be30,
0xd192e819,0xd6ef5218, 0xd6990624,0x5565a910, 0xf40e3585,0x5771202a, 0x106aa070,0x32bbd1b8,
0x19a4c116,0xb8d2d0c8, 0x1e376c08,0x5141ab53, 0x2748774c,0xdf8eeb99, 0x34b0bcb5,0xe19b48a8,
0x391c0cb3,0xc5c95a63, 0x4ed8aa4a,0xe3418acb, 0x5b9cca4f,0x7763e373, 0x682e6ff3,0xd6b2b8a3,
0x748f82ee,0x5defb2fc, 0x78a5636f,0x43172f60, 0x84c87814,0xa1f0ab72, 0x8cc70208,0x1a6439ec,
0x90befffa,0x23631e28, 0xa4506ceb,0xde82bde9, 0xbef9a3f7,0xb2c67915, 0xc67178f2,0xe372532b,
0xca273ece,0xea26619c, 0xd186b8c7,0x21c0c207, 0xeada7dd6,0xcde0eb1e, 0xf57d4f7f,0xee6ed178,
0x06f067aa,0x72176fba, 0x0a637dc5,0xa2c898a6, 0x113f9804,0xbef90dae, 0x1b710b35,0x131c471b,
0x28db77f5,0x23047d84, 0x32caab7b,0x40c72493, 0x3c9ebe0a,0x15c9bebc, 0x431d67c4,0x9c100d4c,
0x4cc5d4be,0xcb3e42b6, 0x597f299c,0xfc657e2a, 0x5fcb6fab,0x3ad6faec, 0x6c44198c,0x4a475817
}
local H0 = { 0x6a09e667,0xf3bcc908, 0xbb67ae85,0x84caa73b, 0x3c6ef372,0xfe94f82b, 0xa54ff53a,0x5f1d36f1, 0x510e527f,0xade682d1, 0x9b05688c,0x2b3e6c1f, 0x1f83d9ab,0xfb41bd6b, 0x5be0cd19,0x137e2179 }

local function rotr(h, l, n)                       -- a 64-bit word (h, l) rotated right n bits
  if n >= 32 then h, l, n = l, h, n - 32 end
  if n == 0 then return h, l end
  return bor(shr(h, n), shl(l, 32 - n)), bor(shr(l, n), shl(h, 32 - n))
end
local function shr64(h, l, n) return shr(h, n), bor(shr(l, n), shl(h, 32 - n)) end   -- (n < 32)

function E.sha512(msg)
  local len = #msg
  local pad = 128 - ((len + 17) % 128)
  if pad == 128 then pad = 0 end
  local bits = len * 8
  local lenbytes = {}
  for i = 8, 1, -1 do lenbytes[i] = string.char(bits % 256); bits = floor(bits / 256) end
  msg = msg .. "\128" .. string.rep("\0", pad) .. string.rep("\0", 8) .. table.concat(lenbytes)
  local h = {}
  for i = 1, 16 do h[i] = H0[i] end
  local w = {}
  for chunk = 1, #msg, 128 do
    for i = 0, 15 do
      local a, b, c, d, e, f, g, k = msg:byte(chunk + i * 8, chunk + i * 8 + 7)
      w[2 * i + 1] = ((a * 256 + b) * 256 + c) * 256 + d
      w[2 * i + 2] = ((e * 256 + f) * 256 + g) * 256 + k
    end
    for i = 16, 79 do
      local h15, l15 = w[2 * (i - 15) + 1], w[2 * (i - 15) + 2]
      local a1, a2 = rotr(h15, l15, 1); local b1, b2 = rotr(h15, l15, 8); local c1, c2 = shr64(h15, l15, 7)
      local s0h, s0l = bxor(bxor(a1, b1), c1), bxor(bxor(a2, b2), c2)
      local h2, l2 = w[2 * (i - 2) + 1], w[2 * (i - 2) + 2]
      a1, a2 = rotr(h2, l2, 19); b1, b2 = rotr(h2, l2, 61); c1, c2 = shr64(h2, l2, 6)
      local s1h, s1l = bxor(bxor(a1, b1), c1), bxor(bxor(a2, b2), c2)
      local lo = w[2 * (i - 16) + 2] + s0l + w[2 * (i - 7) + 2] + s1l
      local hi = w[2 * (i - 16) + 1] + s0h + w[2 * (i - 7) + 1] + s1h + floor(lo / 4294967296)
      w[2 * i + 1], w[2 * i + 2] = hi % 4294967296, lo % 4294967296
    end
    local ah, al, bh, bl, ch, cl, dh, dl = h[1], h[2], h[3], h[4], h[5], h[6], h[7], h[8]
    local eh, el, fh, fl, gh, gl, hh, hl = h[9], h[10], h[11], h[12], h[13], h[14], h[15], h[16]
    for i = 0, 79 do
      local a1, a2 = rotr(eh, el, 14); local b1, b2 = rotr(eh, el, 18); local c1, c2 = rotr(eh, el, 41)
      local S1h, S1l = bxor(bxor(a1, b1), c1), bxor(bxor(a2, b2), c2)
      local chh = bxor(band(eh, fh), band(bnot(eh), gh))
      local chl = bxor(band(el, fl), band(bnot(el), gl))
      local t1l = hl + S1l + chl + K[2 * i + 2] + w[2 * i + 2]
      local t1h = hh + S1h + chh + K[2 * i + 1] + w[2 * i + 1] + floor(t1l / 4294967296)
      t1l = t1l % 4294967296
      a1, a2 = rotr(ah, al, 28); b1, b2 = rotr(ah, al, 34); c1, c2 = rotr(ah, al, 39)
      local S0h, S0l = bxor(bxor(a1, b1), c1), bxor(bxor(a2, b2), c2)
      local mjh = bxor(bxor(band(ah, bh), band(ah, ch)), band(bh, ch))
      local mjl = bxor(bxor(band(al, bl), band(al, cl)), band(bl, cl))
      local t2l = S0l + mjl
      local t2h = S0h + mjh + floor(t2l / 4294967296)
      t2l = t2l % 4294967296
      hh, hl, gh, gl, fh, fl = gh, gl, fh, fl, eh, el
      local nl = dl + t1l
      eh, el = (dh + t1h + floor(nl / 4294967296)) % 4294967296, nl % 4294967296
      dh, dl, ch, cl, bh, bl = ch, cl, bh, bl, ah, al
      nl = t1l + t2l
      ah, al = (t1h + t2h + floor(nl / 4294967296)) % 4294967296, nl % 4294967296
    end
    local v = { ah, al, bh, bl, ch, cl, dh, dl, eh, el, fh, fl, gh, gl, hh, hl }
    for i = 1, 16, 2 do
      local lo = h[i + 1] + v[i + 1]
      h[i] = (h[i] + v[i] + floor(lo / 4294967296)) % 4294967296
      h[i + 1] = lo % 4294967296
    end
  end
  local out = {}
  for i = 1, 16 do
    local x = h[i]
    out[i] = string.char(floor(x / 16777216) % 256, floor(x / 65536) % 256, floor(x / 256) % 256, x % 256)
  end
  return table.concat(out)
end

-- the field: 16 limbs of 16 bits (index 0..15) ---------------------------------
local function gf(t) local r = {} for i = 0, 15 do r[i] = t and t[i + 1] or 0 end return r end
local gf0, gf1 = gf(), gf({ 1 })
local D = gf({ 0x78a3, 0x1359, 0x4dca, 0x75eb, 0xd8ab, 0x4141, 0x0a4d, 0x0070, 0xe898, 0x7779, 0x4079, 0x8cc7, 0xfe73, 0x2b6f, 0x6cee, 0x5203 })
local D2 = gf({ 0xf159, 0x26b2, 0x9b94, 0xebd6, 0xb156, 0x8283, 0x149a, 0x00e0, 0xd130, 0xeef3, 0x80f2, 0x198e, 0xfce7, 0x56df, 0xd9dc, 0x2406 })
local X = gf({ 0xd51a, 0x8f25, 0x2d60, 0xc956, 0xa7b2, 0x9525, 0xc760, 0x692c, 0xdc5c, 0xfdd6, 0xe231, 0xc0a4, 0x53fe, 0xcd6e, 0x36d3, 0x2169 })
local Y = gf({ 0x6658, 0x6666, 0x6666, 0x6666, 0x6666, 0x6666, 0x6666, 0x6666, 0x6666, 0x6666, 0x6666, 0x6666, 0x6666, 0x6666, 0x6666, 0x6666 })
local I = gf({ 0xa0b0, 0x4a0e, 0x1b27, 0xc4ee, 0xe478, 0xad2f, 0x1806, 0x2f43, 0xd7a7, 0x3dfb, 0x0099, 0x2b4d, 0xdf0b, 0x4fc1, 0x2480, 0x2b83 })
local L = { [0] = 0xed, 0xd3, 0xf5, 0x5c, 0x1a, 0x63, 0x12, 0x58, 0xd6, 0x9c, 0xf7, 0xa2, 0xde, 0xf9, 0xde, 0x14,
            0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x10 }

local function cp(a) local r = {} for i = 0, 15 do r[i] = a[i] end return r end
local function car(o)
  for i = 0, 15 do
    o[i] = o[i] + 65536
    local c = floor(o[i] / 65536)
    if i < 15 then o[i + 1] = o[i + 1] + c - 1 else o[0] = o[0] + 38 * (c - 1) end
    o[i] = o[i] - c * 65536
  end
end
local function sel(p, q, b) if b == 1 then for i = 0, 15 do p[i], q[i] = q[i], p[i] end end end
local function pack25519(n)                        -- -> 32 bytes (a table, 0..31)
  local t, m = cp(n), {}
  car(t); car(t); car(t)
  for _ = 1, 2 do
    m[0] = t[0] - 0xffed
    for i = 1, 14 do
      m[i] = t[i] - 0xffff - (floor(m[i - 1] / 65536) % 2)
      m[i - 1] = m[i - 1] % 65536
    end
    m[15] = t[15] - 0x7fff - (floor(m[14] / 65536) % 2)
    local b = floor(m[15] / 65536) % 2
    m[14] = m[14] % 65536
    sel(t, m, 1 - b)
  end
  local o = {}
  for i = 0, 15 do o[2 * i] = t[i] % 256; o[2 * i + 1] = floor(t[i] / 256) % 256 end
  return o
end
local function unpack25519(n)                      -- 32 bytes (0..31) ->
  local o = {}
  for i = 0, 15 do o[i] = n[2 * i] + n[2 * i + 1] * 256 end
  o[15] = o[15] % 32768
  return o
end
local function A(a, b) local o = {} for i = 0, 15 do o[i] = a[i] + b[i] end return o end
local function Z(a, b) local o = {} for i = 0, 15 do o[i] = a[i] - b[i] end return o end
local function M(a, b)
  local t = {}
  for i = 0, 30 do t[i] = 0 end
  for i = 0, 15 do
    local ai = a[i]
    for j = 0, 15 do t[i + j] = t[i + j] + ai * b[j] end
  end
  for i = 0, 14 do t[i] = t[i] + 38 * t[i + 16] end
  local o = {}
  for i = 0, 15 do o[i] = t[i] end
  car(o); car(o)
  return o
end
local function S(a) return M(a, a) end
local function inv25519(i)
  local c = cp(i)
  for a = 253, 0, -1 do
    c = S(c)
    if a ~= 2 and a ~= 4 then c = M(c, i) end
  end
  return c
end
local function pow2523(i)
  local c = cp(i)
  for a = 250, 0, -1 do
    c = S(c)
    if a ~= 1 then c = M(c, i) end
  end
  return c
end
local function neq(a, b)
  local x, y = pack25519(a), pack25519(b)
  for i = 0, 31 do if x[i] ~= y[i] then return true end end
  return false
end
local function par(a) return pack25519(a)[0] % 2 end

-- points: { X, Y, Z, T } -------------------------------------------------------
local function add(p, q)
  local a = M(Z(p[2], p[1]), Z(q[2], q[1]))
  local b = M(A(p[1], p[2]), A(q[1], q[2]))
  local c = M(M(p[4], q[4]), D2)
  local d = M(p[3], q[3]); d = A(d, d)
  local e, f, g, h = Z(b, a), Z(d, c), A(d, c), A(b, a)
  p[1], p[2], p[3], p[4] = M(e, f), M(h, g), M(g, f), M(e, h)
end
local function cswap(p, q, b) for i = 1, 4 do sel(p[i], q[i], b) end end
local function pack(p)
  local zi = inv25519(p[3])
  local tx, ty = M(p[1], zi), M(p[2], zi)
  local r = pack25519(ty)
  r[31] = r[31] + 128 * par(tx)
  return r
end
local function scalarmult(q, s)                    -- s: 32 bytes (0..31)
  local p = { gf(), gf({ 1 }), gf({ 1 }), gf() }
  q = { cp(q[1]), cp(q[2]), cp(q[3]), cp(q[4]) }
  for i = 255, 0, -1 do
    local b = floor(s[floor(i / 8)] / 2 ^ (i % 8)) % 2
    cswap(p, q, b)
    add(q, p)
    add(p, p)
    cswap(p, q, b)
  end
  return p
end
local function scalarbase(s) return scalarmult({ cp(X), cp(Y), cp(gf1), M(X, Y) }, s) end

local function modL(x)                             -- x: 64 numbers (0..63) -> 32 bytes (0..31)
  for i = 63, 32, -1 do
    local carry = 0
    local j = i - 32
    while j < i - 12 do
      x[j] = x[j] + carry - 16 * x[i] * L[j - (i - 32)]
      carry = floor((x[j] + 128) / 256)
      x[j] = x[j] - carry * 256
      j = j + 1
    end
    x[j] = x[j] + carry
    x[i] = 0
  end
  local carry = 0
  for j = 0, 31 do
    x[j] = x[j] + carry - floor(x[31] / 16) * L[j]
    carry = floor(x[j] / 256)
    x[j] = x[j] % 256
  end
  for j = 0, 31 do x[j] = x[j] - carry * L[j] end
  local r = {}
  for i = 0, 31 do
    x[i + 1] = x[i + 1] + floor(x[i] / 256)
    r[i] = x[i] % 256
  end
  return r
end
local function bytes(s) local t = {} for i = 1, #s do t[i - 1] = s:byte(i) end return t end
local function str(t, n) local o = {} for i = 0, (n or 32) - 1 do o[i + 1] = string.char(t[i]) end return table.concat(o) end
local function reduce(h64) local x = bytes(h64) return modL(x) end

local function expand(seed)                        -- the secret scalar (clamped) and the prefix
  local d = bytes(E.sha512(seed))
  d[0] = d[0] - d[0] % 8
  d[31] = d[31] % 128 + 64 - (floor(d[31] / 64) % 2) * 64
  return d
end

function E.keypair(seed)
  assert(type(seed) == "string" and #seed == 32, "ed25519: a 32-byte seed")
  local d = expand(seed)
  return str(pack(scalarbase(d))), seed
end

function E.sign(seed, msg)
  local d = expand(seed)
  local pk = str(pack(scalarbase(d)))
  local prefix = {}
  for i = 32, 63 do prefix[#prefix + 1] = string.char(d[i]) end
  local r = reduce(E.sha512(table.concat(prefix) .. msg))
  local R = str(pack(scalarbase(r)))
  local h = reduce(E.sha512(R .. pk .. msg))
  local x = {}
  for i = 0, 63 do x[i] = 0 end
  for i = 0, 31 do x[i] = r[i] end
  for i = 0, 31 do for j = 0, 31 do x[i + j] = x[i + j] + h[i] * d[j] end end
  return R .. str(modL(x))
end

local function unpackneg(p)                        -- the point -P from its 32 bytes -> nil: not a point
  local r = { gf(), gf(), gf({ 1 }), gf() }        -- (X, Y, Z = 1, T)
  local pb = bytes(p)
  r[2] = unpack25519(pb)
  local num = S(r[2])
  local den = M(num, D)
  num = Z(num, r[3])
  den = A(r[3], den)
  local den2 = S(den)
  local den4 = S(den2)
  local den6 = M(den4, den2)
  local t = M(M(den6, num), den)
  t = pow2523(t)
  t = M(M(M(t, num), den), den)
  r[1] = M(t, den)
  local chk = M(S(r[1]), den)
  if neq(chk, num) then r[1] = M(r[1], I) end
  chk = M(S(r[1]), den)
  if neq(chk, num) then return nil end
  if par(r[1]) == floor(pb[31] / 128) then r[1] = Z(gf0, r[1]) end
  r[4] = M(r[1], r[2])
  return r
end

function E.verify(pk, msg, sig)
  if type(pk) ~= "string" or #pk ~= 32 or type(sig) ~= "string" or #sig ~= 64 then return false end
  local q = unpackneg(pk)
  if not q then return false end
  local h = reduce(E.sha512(sig:sub(1, 32) .. pk .. msg))
  local p = scalarmult(q, h)
  local s = bytes(sig:sub(33, 64))
  if s[31] >= 16 then return false end             -- (S must be under L: no second form of one signature)
  local b = scalarbase(s)
  add(p, b)
  return str(pack(p)) == sig:sub(1, 32)
end

function E.hex(s) return (s:gsub(".", function(c) return string.format("%02x", c:byte()) end)) end
function E.unhex(h) return (h:gsub("%x%x", function(x) return string.char(tonumber(x, 16)) end)) end

return E
