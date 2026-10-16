-- portmap.lua - asking the home router to open a port (no forwarding by
-- hand): PCP (RFC 6887), then NAT-PMP (RFC 6886), then UPnP-IGD. Whatever
-- answers first opens our UDP port on the router's public address; the
-- mapping is renewed halfway through its lease and released on close.
--
--   local pm = portmap.new { port = 7777 }   -- (the game's socket's port)
--   pm:tick(dt)                               -- every frame; never blocks
--   pm.result  -> { host, port, how = "pcp" | "nat-pmp" | "upnp", private = true? } once open
--   pm.failed  -> why not (nothing answered, the router said no)
--   pm:close()                                -- release it (tick on until pm.closed)
--
-- result.private: the router's own public address is a private one (an
-- ISP's NAT in front of it, carrier-grade NAT, or a router behind a router):
-- the port is open on the router but nobody outside can reach it. Compare
-- result.host with what an introducer sees too (nat.lua: c.public).
--
-- Options (tests): gateway (else udp.gateway(), else this computer's
-- address ending in .1), localip, lifetime (s, 3600), pmp_port (5351),
-- ssdp = { host, port } (239.255.255.250:1900), wait (s a try: 0.25),
-- ssdp_wait (2), open = function(port, v4) -> a udp socket,
-- connect = function(host, port) -> a tcp connection (editor/udp.h's API).
local portmap = {}
local PM = {}
PM.__index = PM

local function u16(n) n = math.floor(n) % 65536; return string.char(math.floor(n / 256), n % 256) end
local function u32(n) n = math.floor(n) % 4294967296; return u16(math.floor(n / 65536)) .. u16(n % 65536) end
local function g16(s, i) local a, b = s:byte(i, i + 1); return (a or 0) * 256 + (b or 0) end
local function g32(s, i) return g16(s, i) * 65536 + g16(s, i + 2) end
local function ip4(s) local a, b, c, d = tostring(s):match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$"); if a then return string.char(a, b, c, d) end end
local function ip4s(b, i) return string.format("%d.%d.%d.%d", b:byte(i, i + 3)) end
local MAPPED0 = ("\0"):rep(10) .. "\255\255"

-- an address nobody on the internet can reach (behind another NAT)
function portmap.private(ip)
  local a, b = tostring(ip):match("^(%d+)%.(%d+)%.")
  a, b = tonumber(a), tonumber(b)
  if not a then return false end
  return a == 10 or a == 127 or a == 0 or (a == 172 and b >= 16 and b <= 31) or (a == 192 and b == 168)
      or (a == 100 and b >= 64 and b <= 127) or (a == 169 and b == 254)
end

function portmap.new(o)
  o = o or {}
  local U, T = rawget(_G, "udp"), rawget(_G, "tcp")
  local me = o.localip or (U and U.localip and U.localip()) or "0.0.0.0"
  local gw = o.gateway or (U and U.gateway and U.gateway())
  if not gw and me:match("^%d+%.%d+%.%d+%.%d+$") then gw = me:gsub("%d+$", "1") end   -- (a guess: most home routers)
  local p = setmetatable({
    port = assert(tonumber(o.port), "portmap.new{ port = }"), me = me, gw = gw, lifetime = o.lifetime or 3600,
    pmp_port = o.pmp_port or 5351, ssdp = o.ssdp or { "239.255.255.250", 1900 },
    wait = o.wait or 0.25, ssdp_wait = o.ssdp_wait or 2, desc = o.desc or "Replay",
    open = o.open or function(port, v4) return U.open(port, v4 and "4" or nil) end,
    connect = o.connect or function(h, port) return T.connect(h, port) end,
    t = 0, steps = {}, log = {},
  }, PM)
  p.nonce = ""
  for i = 1, 12 do p.nonce = p.nonce .. string.char(math.random(0, 255)) end
  if not gw then p.failed = "no router address" return p end
  if not (U and U.open) then p.failed = "no sockets here" return p end
  p:_start("pcp")
  return p
end
function PM:_say(fmt, ...) self.log[#self.log + 1] = string.format(fmt, ...) end

---------------------------------------------------------------------------
-- PCP and NAT-PMP: one UDP request to the router's port 5351, an answer
---------------------------------------------------------------------------
function PM:_pcp_map(lifetime)
  local me = ip4(self.me) or "\0\0\0\0"
  return "\2\1\0\0" .. u32(lifetime) .. MAPPED0 .. me
      .. self.nonce .. "\17\0\0\0" .. u16(self.port) .. u16(self.result and self.result.port or self.port) .. MAPPED0 .. "\0\0\0\0"
end
function PM:_pmp_map(lifetime) return "\0\1\0\0" .. u16(self.port) .. u16(lifetime > 0 and (self.result and self.result.port or self.port) or 0) .. u32(lifetime) end

function PM:_start(how)
  self.how, self.tries, self.next_try = how, 0, 0
  if how == "upnp" then return self:_upnp_start() end
  if not self.us then
    self.us = self.open(0, true)
    if not self.us then return self:_next("no socket") end
  end
end
function PM:_next(why)                             -- this way didn't work: the next one
  if why then self:_say("%s: %s", self.how, why) end
  if self.how == "pcp" then return self:_start("nat-pmp") end
  if self.how == "nat-pmp" then return self:_start("upnp") end
  self.how = nil
  self.failed = table.concat(self.log, "; ")
end
function PM:_got(host, port, lifetime)
  self.result = { host, port, how = self.how, private = portmap.private(host) or nil }
  self.renew_at = (lifetime and lifetime > 0) and (self.t + lifetime / 2) or nil
  self.failed, self.busy = nil, nil
  self:_say("%s: %s:%d for %s s", self.how, host, port, tostring(lifetime))
end

function PM:_pmp_tick()
  -- (answers first)
  while true do
    local b = self.us:recv()
    if not b then break end
    if self.how == "pcp" and #b >= 60 and b:byte(1) == 2 and b:byte(2) == 0x81 and b:sub(25, 36) == self.nonce then
      local rc = b:byte(4)
      if self.closing then self.closed = true return end
      if rc ~= 0 then return self:_next("refused (" .. rc .. ")") end
      return self:_got(ip4s(b, 57), g16(b, 43), g32(b, 5))
    elseif self.how == "pcp" and #b >= 2 and b:byte(1) == 0 then   -- (a NAT-PMP router: "not that version")
      return self:_start("nat-pmp")
    elseif self.how == "nat-pmp" and #b >= 12 and b:byte(2) == 128 then
      if g16(b, 3) == 0 then self.pmp_ip = ip4s(b, 9) end
    elseif self.how == "nat-pmp" and #b >= 16 and b:byte(2) == 129 then
      local rc = g16(b, 3)
      if self.closing then self.closed = true return end
      if rc ~= 0 then return self:_next("refused (" .. rc .. ")") end
      if not self.pmp_ip then self.pmp_port_got = { g16(b, 11), g32(b, 13) } -- (the address: next answer)
      else return self:_got(self.pmp_ip, g16(b, 11), g32(b, 13)) end
    end
  end
  if self.how == "nat-pmp" and self.pmp_ip and self.pmp_port_got then
    return self:_got(self.pmp_ip, self.pmp_port_got[1], self.pmp_port_got[2])
  end
  if self.t >= self.next_try then
    if self.tries >= 2 then
      if self.closing then self.closed = true return end
      if self.busy then self.busy = false; self.renew_at = self.t + 60 return end   -- (renewing: again in a minute; it's still open)
      return self:_next("no answer")
    end
    self.tries = self.tries + 1
    self.next_try = self.t + self.wait * 2 ^ (self.tries - 1)
    local life = self.closing and 0 or self.lifetime
    if self.how == "pcp" then self.us:send(self.gw, self.pmp_port, self:_pcp_map(life))
    else
      if not self.closing then self.us:send(self.gw, self.pmp_port, "\0\0") end   -- (its public address)
      self.us:send(self.gw, self.pmp_port, self:_pmp_map(life))
    end
  end
end

---------------------------------------------------------------------------
-- UPnP-IGD: find the router (SSDP), read its description (HTTP), ask it
-- (SOAP): AddPortMapping, GetExternalIPAddress, DeletePortMapping
---------------------------------------------------------------------------
local function search(st)
  return "M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\nMAN: \"ssdp:discover\"\r\nMX: 2\r\nST: " .. st .. "\r\n\r\n"
end
local function parse_url(u)
  local h, port, path = tostring(u):match("^http://([^:/]+):?(%d*)(.*)$")
  if not h then return nil end
  return h, tonumber(port) or 80, path ~= "" and path or "/"
end
function PM:_upnp_start()
  self.up = { phase = "search", t0 = self.t, next_search = self.t, sent = 0 }
  self.ss = self.ss or self.open(0, true)
  if not self.ss then return self:_next("no socket") end
end
-- one HTTP exchange, a step a tick: -> body (done), nil (not yet), false, err
function PM:_http(req)
  local h = self.http
  if not h then
    local c, err = self.connect(req.host, req.port)
    if not c then return false, err end
    local body = req.body or ""
    local head = (req.method or "GET") .. " " .. req.path .. " HTTP/1.1\r\nHost: " .. req.host .. ":" .. req.port .. "\r\nConnection: close\r\n"
    for k, v in pairs(req.headers or {}) do head = head .. k .. ": " .. v .. "\r\n" end
    if req.body then head = head .. "Content-Length: " .. #body .. "\r\n" end
    h = { c = c, out = head .. "\r\n" .. body, got = {}, t0 = self.t }
    self.http = h
  end
  if self.t - h.t0 > 4 then h.c:close(); self.http = nil; return false, "timeout" end
  if h.c:status() == "failed" then h.c:close(); self.http = nil; return false, "can't connect" end
  if #h.out > 0 then
    local n, err = h.c:send(h.out)
    if not n then h.c:close(); self.http = nil; return false, err end
    h.out = h.out:sub(n + 1)
    if #h.out > 0 then return nil end
  end
  while true do
    local b, why = h.c:recv()
    if b then h.got[#h.got + 1] = b
    elseif why == "wait" then
      local all = table.concat(h.got)          -- (done early when Content-Length says so)
      local head, rest = all:match("^(.-\r\n)\r\n(.*)$")
      local len = head and tonumber(head:lower():match("content%-length:%s*(%d+)"))
      if not (len and #rest >= len) then return nil end
      break
    else break end
  end
  h.c:close(); self.http = nil
  local all = table.concat(h.got)
  local status = tonumber(all:match("^HTTP/%d%.%d (%d+)"))
  local body = all:match("\r\n\r\n(.*)$") or ""
  return body, status
end
local function soap(service, action, args)
  local x = {}
  for _, kv in ipairs(args) do x[#x + 1] = "<" .. kv[1] .. ">" .. kv[2] .. "</" .. kv[1] .. ">" end
  return '<?xml version="1.0"?>\r\n<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/"><s:Body>'
      .. '<u:' .. action .. ' xmlns:u="' .. service .. '">' .. table.concat(x) .. '</u:' .. action .. '></s:Body></s:Envelope>\r\n'
end
function PM:_soap(action, args)
  local svc = self.up.svc
  return { method = "POST", host = svc.host, port = svc.port, path = svc.path, body = soap(svc.type, action, args),
           headers = { ["Content-Type"] = 'text/xml; charset="utf-8"', SOAPAction = '"' .. svc.type .. "#" .. action .. '"' } }
end
function PM:_add_args()
  local up = self.up
  return { { "NewRemoteHost", "" }, { "NewExternalPort", up.ext }, { "NewProtocol", "UDP" }, { "NewInternalPort", self.port },
           { "NewInternalClient", self.me }, { "NewEnabled", 1 }, { "NewPortMappingDescription", self.desc }, { "NewLeaseDuration", up.lease } }
end
function PM:_upnp_tick()
  local up = self.up
  if up.phase == "search" then
    while true do
      local b = self.ss:recv()
      if not b then break end
      local loc = b:match("[Ll][Oo][Cc][Aa][Tt][Ii][Oo][Nn]:%s*(%S+)")
      if loc and b:find("InternetGatewayDevice", 1, true) or (loc and b:find("WAN", 1, true)) then
        local h, port, path = parse_url(loc)
        if h then up.loc, up.phase = { host = h, port = port, path = path }, "describe" break end
      end
    end
    if up.phase == "search" then
      if self.t - up.t0 > self.ssdp_wait then return self:_next("no UPnP router answered") end
      if self.t >= up.next_search and up.sent < 2 then   -- (twice: multicast gets lost)
        up.next_search, up.sent = self.t + self.ssdp_wait / 2, up.sent + 1
        for _, st in ipairs({ "urn:schemas-upnp-org:device:InternetGatewayDevice:1", "urn:schemas-upnp-org:device:InternetGatewayDevice:2" }) do
          self.ss:send(self.ssdp[1], self.ssdp[2], search(st))
        end
      end
      return
    end
  end
  if up.phase == "describe" then
    local body, st = self:_http(up.loc)
    if body == nil then return end
    if body == false then return self:_next("description: " .. tostring(st)) end
    local base = body:match("<URLBase>%s*(.-)%s*</URLBase>")
    local bh, bp = parse_url(base or "")
    up.svcs = {}
    for blk in body:gmatch("<service>(.-)</service>") do
      local typ = blk:match("<serviceType>%s*(.-)%s*</serviceType>")
      local ctl = blk:match("<controlURL>%s*(.-)%s*</controlURL>")
      if typ and ctl and (typ:find("WANIPConnection", 1, true) or typ:find("WANPPPConnection", 1, true)) then
        local h, port, path = parse_url(ctl)
        if not h then h, port, path = bh or up.loc.host, bp or up.loc.port, (ctl:sub(1, 1) == "/" and ctl or "/" .. ctl) end
        local s = { type = typ, host = h, port = port, path = path }
        if typ:find("WANIPConnection", 1, true) then table.insert(up.svcs, 1, s) else up.svcs[#up.svcs + 1] = s end
      end
    end
    if #up.svcs == 0 then return self:_next("no WAN service in its description") end
    up.svc = table.remove(up.svcs, 1)
    up.ext, up.lease, up.phase, up.conflicts = self.result and self.result.port or self.port, self.lifetime, "add", 0
    return
  end
  if up.phase == "add" then
    local body, st = self:_http(self:_soap("AddPortMapping", self:_add_args()))
    if body == nil then return end
    if body == false then return self:_next("AddPortMapping: " .. tostring(st)) end
    if st == 200 then up.phase = "ip" return end
    local code = tonumber(body:match("<errorCode>%s*(%d+)%s*</errorCode>"))
    if code == 725 and up.lease ~= 0 then up.lease = 0 return end   -- (permanent leases only: 0, released on close)
    if (code == 718 or code == 724) and up.conflicts < 4 then         -- (taken by someone else: the next port)
      up.conflicts = up.conflicts + 1; up.ext = up.ext + 1 return
    end
    if #up.svcs > 0 then up.svc = table.remove(up.svcs, 1) return end
    return self:_next("AddPortMapping refused (" .. tostring(code or st) .. ")")
  end
  if up.phase == "ip" then
    local body, st = self:_http(self:_soap("GetExternalIPAddress", {}))
    if body == nil then return end
    local ip = body and body:match("<NewExternalIPAddress>%s*(.-)%s*</NewExternalIPAddress>")
    if not ip or ip == "" then return self:_next("no external address (" .. tostring(st) .. ")") end
    up.phase = "done"
    return self:_got(ip, up.ext, up.lease)
  end
  if up.phase == "delete" then
    local body = self:_http(self:_soap("DeletePortMapping", { { "NewRemoteHost", "" }, { "NewExternalPort", up.ext }, { "NewProtocol", "UDP" } }))
    if body == nil then return end
    self.closed = true
  end
end

---------------------------------------------------------------------------
function PM:tick(dt)
  self.t = self.t + dt
  if self.closed then return end
  if self.closing and self.t - self.closing > 3 then self.closed = true return end
  if self.result and not self.closing then          -- (open: renewed halfway through its lease)
    if self.renew_at and self.t >= self.renew_at then
      self.renew_at = nil
      if self.how == "upnp" then self.up.phase = "add" else self.tries, self.next_try, self.busy = 0, self.t, true end
    elseif not (self.busy or (self.how == "upnp" and self.up.phase ~= "done")) then return end
  end
  if not self.how then return end
  if self.how == "upnp" then self:_upnp_tick() else self:_pmp_tick() end
end
function PM:close()
  if self.closing or self.closed then return end
  self.closing = self.t
  if not self.result then self.closed = true
  elseif self.how == "upnp" then self.up.phase = "delete"
  else self.tries, self.next_try = 0, self.t end
end
function PM:status()                               -- -> a line for the log
  if self.result then
    return string.format("the router opened %s:%d (%s)%s", self.result[1], self.result[2], self.result.how,
      self.result.private and " - but that's a private address: another NAT is in front (no use from outside)" or "")
  end
  if self.failed then return "the router didn't open a port: " .. self.failed end
  return "asking the router (" .. tostring(self.how) .. ")..."
end

return portmap
