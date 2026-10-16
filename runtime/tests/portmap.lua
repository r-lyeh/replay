-- portmap.lua - asking a router to open a port (runtime/portmap.lua), on real
-- sockets (editor/udp.h's udp and tcp), against a pretend router on this
-- computer that speaks PCP, NAT-PMP or UPnP-IGD (or nothing).
--   replay games/pong.lua --headless --ticks 2 --type "dofile('runtime/tests/portmap.lua')@1"
-- Prints the failures and a count; a failure fails the run (an assert).
local portmap = require "portmap"
local n, fails = 0, 0
local function check(c, m) n = n + 1; if not c then fails = fails + 1; print("  FAIL: " .. m) end end

local function u16(v) return string.char(math.floor(v / 256) % 256, v % 256) end
local function u32(v) return u16(math.floor(v / 65536)) .. u16(v % 65536) end
local function g16(s, i) local a, b = s:byte(i, i + 1); return a * 256 + b end
local function g32(s, i) return g16(s, i) * 65536 + g16(s, i + 2) end

-- the pretend router: mode "pcp" | "nat-pmp" | "upnp" | "none"; ext: its public address
local function router(mode, ext)
  local R = { mode = mode, ext = ext or "203.0.113.9", maps = {}, deleted = {}, adds = 0 }
  R.pmp = assert(udp.open(0, "4"))
  R.ssdp = assert(udp.open(0, "4"))
  R.http = assert(tcp.listen(0))
  R.conns = {}
  function R:tick()
    while true do                                   -- PCP / NAT-PMP
      local b, h, p = self.pmp:recv()
      if not b then break end
      if self.mode == "pcp" and b:byte(1) == 2 and #b >= 60 then
        local life, inport, want = g32(b, 5), g16(b, 41), g16(b, 43)
        if life == 0 then self.deleted[#self.deleted + 1] = inport else self.maps[want] = inport end
        local ip = { self.ext:match("(%d+)%.(%d+)%.(%d+)%.(%d+)") }
        self.pmp:send(h, p, "\2\129\0\0" .. u32(life) .. u32(1) .. ("\0"):rep(12) .. b:sub(25, 40) .. u16(inport) .. u16(want)
          .. ("\0"):rep(10) .. "\255\255" .. string.char(ip[1], ip[2], ip[3], ip[4]))
      elseif self.mode == "nat-pmp" and b:byte(1) == 2 then
        self.pmp:send(h, p, "\0\129\0\1" .. u32(1))  -- (unsupported version: a NAT-PMP router)
      elseif self.mode == "nat-pmp" and b:byte(1) == 0 and b:byte(2) == 0 then
        local ip = { self.ext:match("(%d+)%.(%d+)%.(%d+)%.(%d+)") }
        self.pmp:send(h, p, "\0\128\0\0" .. u32(1) .. string.char(ip[1], ip[2], ip[3], ip[4]))
      elseif self.mode == "nat-pmp" and b:byte(1) == 0 and b:byte(2) == 1 then
        local inport, want, life = g16(b, 5), g16(b, 7), g32(b, 9)
        if life == 0 then self.deleted[#self.deleted + 1] = inport else self.maps[want] = inport end
        self.pmp:send(h, p, "\0\129\0\0" .. u32(1) .. u16(inport) .. u16(want) .. u32(life))
      end
    end
    while true do                                   -- SSDP: where its description is
      local b, h, p = self.ssdp:recv()
      if not b then break end
      if self.mode == "upnp" and b:find("M-SEARCH", 1, true) and b:find("InternetGatewayDevice:1", 1, true) then
        self.ssdp:send(h, p, "HTTP/1.1 200 OK\r\nCACHE-CONTROL: max-age=120\r\nST: urn:schemas-upnp-org:device:InternetGatewayDevice:1\r\n"
          .. "LOCATION: http://127.0.0.1:" .. self.http:port() .. "/rootDesc.xml\r\nSERVER: pretend/1.0 UPnP/1.1\r\n\r\n")
      end
    end
    local c = self.http:accept()                    -- HTTP: the description, SOAP
    if c then self.conns[#self.conns + 1] = { c = c, buf = "" } end
    for i = #self.conns, 1, -1 do
      local k = self.conns[i]
      local b = k.c:recv()
      if b then k.buf = k.buf .. b end
      local head, body = k.buf:match("^(.-)\r\n\r\n(.*)$")
      local len = head and tonumber(head:lower():match("content%-length:%s*(%d+)")) or 0
      if head and #body >= len then
        local status, out = 200, ""
        if head:find("^GET /rootDesc.xml") then
          out = [[<?xml version="1.0"?><root><device><deviceType>urn:schemas-upnp-org:device:InternetGatewayDevice:1</deviceType><deviceList>
<device><serviceList><service><serviceType>urn:schemas-upnp-org:service:WANPPPConnection:1</serviceType><controlURL>/ctl/PPP</controlURL></service>
<service><serviceType>urn:schemas-upnp-org:service:WANIPConnection:1</serviceType><serviceId>urn:upnp-org:serviceId:WANIPConn1</serviceId><controlURL>/ctl/IPConn</controlURL></service></serviceList></device>
</deviceList></device></root>]]
        elseif head:find("POST /ctl/PPP", 1, true) then
          status, out = 500, "<s:Envelope><s:Body><s:Fault><detail><UPnPError><errorCode>501</errorCode></UPnPError></detail></s:Fault></s:Body></s:Envelope>"
        elseif head:find("#AddPortMapping", 1, true) then
          self.adds = self.adds + 1
          local ext = tonumber(body:match("<NewExternalPort>(%d+)<"))
          local lease = tonumber(body:match("<NewLeaseDuration>(%d+)<"))
          if lease ~= 0 then status, out = 500, "<errorCode>725</errorCode>"              -- (permanent leases only)
          elseif self.taken == ext then status, out = 500, "<errorCode>718</errorCode>"   -- (taken)
          else self.maps[ext] = tonumber(body:match("<NewInternalPort>(%d+)<")); self.client = body:match("<NewInternalClient>(.-)<")
            out = "<s:Envelope><s:Body><u:AddPortMappingResponse/></s:Body></s:Envelope>" end
        elseif head:find("#GetExternalIPAddress", 1, true) then
          out = "<s:Envelope><s:Body><u:GetExternalIPAddressResponse><NewExternalIPAddress>" .. self.ext .. "</NewExternalIPAddress></u:GetExternalIPAddressResponse></s:Body></s:Envelope>"
        elseif head:find("#DeletePortMapping", 1, true) then
          self.deleted[#self.deleted + 1] = tonumber(body:match("<NewExternalPort>(%d+)<"))
        else status = 404 end
        local resp = "HTTP/1.1 " .. status .. " X\r\nContent-Type: text/xml\r\nContent-Length: " .. #out .. "\r\nConnection: close\r\n\r\n" .. out
        while #resp > 0 do local m = k.c:send(resp) or #resp; resp = resp:sub(m + 1) end
        k.c:close(); table.remove(self.conns, i)
      end
    end
  end
  function R:close() self.pmp:close(); self.ssdp:close(); self.http:close() end
  return R
end

local function run(R, pm, until_fn, secs)
  local t0 = udp.clock()
  local last = t0
  while udp.clock() - t0 < (secs or 6) do
    R:tick()
    local now = udp.clock()
    pm:tick(now - last); last = now
    if until_fn() then return true end
    udp.sleep(0.005)
  end
  return false
end
local function new(R, extra)
  local o = { port = 7777, gateway = "127.0.0.1", localip = "192.168.1.10", pmp_port = R.pmp:port(),
              ssdp = { "127.0.0.1", R.ssdp:port() }, wait = 0.1, ssdp_wait = 0.6 }
  for k, v in pairs(extra or {}) do o[k] = v end
  return portmap.new(o)
end

for _, mode in ipairs({ "pcp", "nat-pmp", "upnp" }) do
  local R = router(mode)
  if mode == "upnp" then R.taken = 7777 end
  local pm = new(R)
  run(R, pm, function() return pm.result or pm.failed end)
  local r = pm.result
  check(r and r.how == mode and r[1] == "203.0.113.9", mode .. ": the router opened a port: " .. pm:status())
  if mode == "upnp" then
    check(r and r[2] == 7778 and R.maps[7778] == 7777 and R.client == "192.168.1.10", "upnp: 7777 was taken, 7778 then; to us: " .. tostring(r and r[2]))
  else
    check(r and r[2] == 7777 and R.maps[7777] == 7777, mode .. ": port 7777 to our 7777")
  end
  check(r and not r.private, mode .. ": a public address")
  pm:close()
  run(R, pm, function() return pm.closed end, 3)
  check(#R.deleted == 1, mode .. ": closing it: released (" .. #R.deleted .. ")")
  R:close()
end
do                                                  -- a router behind another NAT: open, but no use
  local R = router("pcp", "100.64.3.4")
  local pm = new(R)
  run(R, pm, function() return pm.result or pm.failed end)
  check(pm.result and pm.result.private and pm:status():find("private", 1, true), "an ISP's NAT in front: said so: " .. pm:status())
  R:close()
end
do                                                  -- nothing answers: each way tried, said so, quickly
  local R = router("none")
  local pm = new(R)
  local t0 = udp.clock()
  run(R, pm, function() return pm.result or pm.failed end)
  check(pm.failed and not pm.result and pm.failed:find("pcp", 1, true) and pm.failed:find("UPnP", 1, true), "no answer: failed, each tried: " .. tostring(pm.failed))
  check(udp.clock() - t0 < 3, "...in under 3 s: " .. string.format("%.1f", udp.clock() - t0))
  R:close()
end
check(portmap.private("10.1.2.3") and portmap.private("172.20.0.1") and portmap.private("100.100.1.1") and not portmap.private("8.8.8.8"), "private addresses")
check(udp.gateway == nil or udp.gateway() == nil or tostring(udp.gateway()):match("^%d+%.%d+%.%d+%.%d+$"), "udp.gateway: an IPv4 address or nil: " .. tostring(udp.gateway and udp.gateway()))

print(string.format("portmap: %s", fails == 0 and ("all ok (" .. n .. " checks)") or (fails .. " failed")))
assert(fails == 0, "portmap: " .. fails .. " failed")
