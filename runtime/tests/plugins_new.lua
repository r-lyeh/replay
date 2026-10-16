-- plugins_new.lua - the hex editor, the particle editor and the sfxr editor
-- in lite: each opens its files in its own tab, and works there.
--   play games/pong.lua --stopped --lite "dofile('runtime/tests/plugins_new.lua')@3" --frames 100000 --shot x.bmp
-- NG_EXIT exits when done. SHOW=hexedit|particles|sfxr: leaves that tab in
-- front and doesn't exit (for a screenshot: --frames 400 --shot x.bmp).
local core = require "core"
core.add_thread(function()
  local ok_n, fail_n = 0, 0
  local function check(c, m) if c then ok_n = ok_n + 1 else fail_n = fail_n + 1; print("  FAIL: " .. m) end end
  local show = os.getenv("SHOW")
  local function open(path)
    core.root_view:open_doc(core.open_doc(path))
    coroutine.yield(0.2)
    return core.active_view
  end
  local function errors_since(n)
    for k = n + 1, #(core.log_items or {}) do
      local it = core.log_items[k]
      if tostring(it.text):lower():find("error", 1, true) or tostring(it.text):find("attempt to", 1, true) then return it.text end
    end
  end
  local log0 = #(core.log_items or {})

  -- sfxr: a sample opens in its tab; the generators, undo, save, a .wav
  local tmp = os.tmpname()
  local sfx = tmp .. ".sfx"
  local src = io.open("plugins/sfxr/samples/laser.sfx", "rb"):read("*a")
  local f = io.open(sfx, "wb"); f:write(src); f:close()
  local v = open(sfx)
  check(v and v.p and v.samples, "sfxr: a .sfx opens in the sfxr tab")
  if v and v.p then
    local n0 = #v.samples
    check(n0 > 1000, "sfxr: it rendered (" .. n0 .. " samples)")
    v:generate("explosion")
    check(v.p.wave == 3 and v.dirty, "sfxr: Explosion: a noise sound, the tab dirty")
    v:undo_step(true)
    check(#v.samples == n0, "sfxr: undo: the laser again")
    v:value("base_freq", 0.6)
    check(math.abs(v.p.base_freq - 0.6) < 1e-9, "sfxr: a slider's value")
    v:save()
    local back = load(io.open(sfx, "rb"):read("*a"), "=sfx", "t", {})()
    check(back and math.abs(back.base_freq - 0.6) < 1e-9 and not v.dirty, "sfxr: saved, reads back")
    v:export()
    local wav = io.open(tmp .. ".wav", "rb")
    check(wav and wav:read(4) == "RIFF", "sfxr: Export .wav")
    if wav then wav:close() end
    coroutine.yield(0.3)
  end
  if show == "sfxr" then return end

  -- particles: a sample, its sim running, a preset, save
  local pfx = tmp .. ".pfx"
  src = io.open("plugins/particles/samples/fire.pfx", "rb"):read("*a")
  f = io.open(pfx, "wb"); f:write(src); f:close()
  v = open(pfx)
  check(v and v.e and v.def, "particles: a .pfx opens in the particle tab")
  if v and v.e then
    coroutine.yield(0.6)
    check(#v.e.ps > 5, "particles: it plays (" .. #v.e.ps .. " alive)")
    v:use_preset("snow")
    check(v.def.shape == "box" and v.dirty, "particles: the Snow preset")
    v:edit(function(d) d.rate = 123 end)
    v:save()
    local back = load(io.open(pfx, "rb"):read("*a"), "=pfx", "t", {})()
    check(back and back.rate == 123 and back.shape == "box", "particles: saved, reads back")
    v:undo_step(true)
    check(v.def.rate ~= 123, "particles: undo")
    coroutine.yield(0.5)
  end
  if show == "particles" then return end

  -- hexedit: a 3 MiB file (chunks across), find, an edit, save in place
  local bin = tmp .. ".bin"
  f = io.open(bin, "wb")
  f:write(string.rep("\0", 1024 * 1024 * 2 - 3), "NEEDLE", string.rep("\1", 1024 * 1024))
  f:close()
  v = open(bin)
  check(v and v.f and v.f.size == 3 * 1024 * 1024 + 3, "hexedit: a .bin opens in the hex tab")
  if v and v.f then
    v.pat, v.pat_text = "NEEDLE", '"NEEDLE"'
    v:find_next(false)
    local t0 = system.get_time()
    repeat coroutine.yield(0.05) until not v.job or system.get_time() - t0 > 10
    check(v.cur == 1024 * 1024 * 2 - 3, "hexedit: found across the 2 MiB edge (" .. tostring(v.cur) .. ")")
    v.side = "hex"
    v:on_text_input("41")
    check(v.f:byte(1024 * 1024 * 2 - 3) == 0x41 and v.dirty, "hexedit: typed 41: an edit")
    v.side = "text"
    v:on_text_input("Z")
    check(v.f:byte(1024 * 1024 * 2 - 2) == string.byte("Z"), "hexedit: typed Z on the text side")
    v:undo_step()
    check(v.f:byte(1024 * 1024 * 2 - 2) == string.byte("E"), "hexedit: undo")
    v:save()
    local h = io.open(bin, "rb"); h:seek("set", 1024 * 1024 * 2 - 3); local got = h:read(6); local size = h:seek("end"); h:close()
    check(got == "AEEDLE" and size == 3 * 1024 * 1024 + 3 and not v.dirty, "hexedit: saved in place")
    v:move(10)
    check(v.cur == 10, "hexedit: the cursor moves")
    local m = v:metrics()
    check(m.rows > 3, "hexedit: rows on screen")
    coroutine.yield(0.3)
  end
  local err = errors_since(log0)
  check(not err, "no errors logged: " .. tostring(err))
  if show == "hexedit" then return end
  for _, p in ipairs({ sfx, pfx, bin, tmp .. ".wav", tmp }) do os.remove(p) end
  print(string.format("plugins new: %d checks ok, %d failed", ok_n, fail_n))
  if os.getenv("NG_EXIT") then os.exit(fail_n == 0 and 0 or 1) end
end)
