-- sfxr.lua - sfxr in Lua: DrPetter's sound effect generator (2007, MIT:
-- www.drpetter.se/project_sfxr.html; its licence below), its synth and its generators,
-- ported from the original C++ (main.cpp: ResetParams, ResetSample,
-- SynthSample, the seven buttons, Randomize, Mutate). No lite here: the sfxr
-- plugin draws it, games play it (runtime/sound.lua), a test can check it.
--
--   local sfxr = require "sfxr"               -- (runtime/sfxr.lua; the sfxr plugin loads it too)
--   local p = sfxr.preset("coin", seed)       -- a sound's parameters (a table: plain data)
--   local s = sfxr.render(p)                  -- its samples: floats -1..1, 44100 a second
--   local pcm = sfxr.pcm16(s)                 -- 16-bit little-endian PCM (a string)
--   local wav = sfxr.wav(s)                   -- a .wav file (a string)
--
-- A sound is a table of the original's parameters (names without p_), all
-- 0..1 except the ones marked both ways (-1..1), plus wave (0 square, 1 saw,
-- 2 sine, 3 noise) and volume. sfxr.PARAMS lists them, in the original's
-- order, with their ranges: the editor's sliders.
--
-- sfxr's licence (sfxr/LICENSE.txt, 2007; github.com/grimfang4/sfxr):
--   sfxr - sound effect generator, by DrPetter, 2007-12-14, developed for LD48#10
--   "Basically, I don't care what you do with it, anything goes. To please all
--   the troublesome folks who request a formal license, I attach the "MIT
--   license" as follows:"
--
--   Copyright (c) 2007 Tomas Pettersson
--
--   Permission is hereby granted, free of charge, to any person obtaining a
--   copy of this software and associated documentation files (the
--   "Software"), to deal in the Software without restriction, including
--   without limitation the rights to use, copy, modify, merge, publish,
--   distribute, sublicense, and/or sell copies of the Software, and to permit
--   persons to whom the Software is furnished to do so, subject to the
--   following conditions:
--
--   The above copyright notice and this permission notice shall be included
--   in all copies or substantial portions of the Software.
--
--   THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS
--   OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
--   MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN
--   NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM,
--   DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR
--   OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE
--   USE OR OTHER DEALINGS IN THE SOFTWARE.
local M = {}

M.RATE = 44100
M.WAVES = { [0] = "square", "sawtooth", "sine", "noise" }
M.PARAMS = {                                       -- name, label, min, max, group
  { "env_attack",   "Attack time",       0, 1, "Envelope" },
  { "env_sustain",  "Sustain time",      0, 1, "Envelope" },
  { "env_punch",    "Sustain punch",     0, 1, "Envelope" },
  { "env_decay",    "Decay time",        0, 1, "Envelope" },
  { "base_freq",    "Start frequency",   0, 1, "Frequency" },
  { "freq_limit",   "Min frequency",     0, 1, "Frequency" },
  { "freq_ramp",    "Slide",            -1, 1, "Frequency" },
  { "freq_dramp",   "Delta slide",      -1, 1, "Frequency" },
  { "vib_strength", "Vibrato depth",     0, 1, "Vibrato" },
  { "vib_speed",    "Vibrato speed",     0, 1, "Vibrato" },
  { "arp_mod",      "Change amount",    -1, 1, "Arpeggio" },
  { "arp_speed",    "Change speed",      0, 1, "Arpeggio" },
  { "duty",         "Square duty",       0, 1, "Duty" },
  { "duty_ramp",    "Duty sweep",       -1, 1, "Duty" },
  { "repeat_speed", "Repeat speed",      0, 1, "Retrigger" },
  { "pha_offset",   "Phaser offset",    -1, 1, "Phaser" },
  { "pha_ramp",     "Phaser sweep",     -1, 1, "Phaser" },
  { "lpf_freq",     "LP filter cutoff",  0, 1, "Filters" },
  { "lpf_ramp",     "LP cutoff sweep",  -1, 1, "Filters" },
  { "lpf_resonance","LP resonance",      0, 1, "Filters" },
  { "hpf_freq",     "HP filter cutoff",  0, 1, "Filters" },
  { "hpf_ramp",     "HP cutoff sweep",  -1, 1, "Filters" },
}
local RANGE = {}
for _, d in ipairs(M.PARAMS) do RANGE[d[1]] = d end

-- the original's ResetParams
function M.defaults()
  return {
    wave = 0, base_freq = 0.3, freq_limit = 0, freq_ramp = 0, freq_dramp = 0,
    duty = 0, duty_ramp = 0, vib_strength = 0, vib_speed = 0, vib_delay = 0,
    env_attack = 0, env_sustain = 0.3, env_decay = 0.4, env_punch = 0,
    filter_on = false, lpf_resonance = 0, lpf_freq = 1, lpf_ramp = 0, hpf_freq = 0, hpf_ramp = 0,
    pha_offset = 0, pha_ramp = 0, repeat_speed = 0, arp_speed = 0, arp_mod = 0,
    volume = 0.5,
  }
end

-- a sound read from a file (anything missing or wrong: the default)
function M.check(t)
  local p = M.defaults()
  if type(t) ~= "table" then return p end
  for k, v in pairs(p) do
    if type(t[k]) == type(v) then p[k] = t[k] end
  end
  if type(t.wave) == "string" then                 -- (a wave by name too: "noise")
    for i, n in pairs(M.WAVES) do if n == t.wave then p.wave = i end end
  end
  p.wave = math.max(0, math.min(3, math.floor(tonumber(p.wave) or 0)))
  for k, d in pairs(RANGE) do p[k] = math.max(d[3], math.min(d[4], p[k])) end
  p.volume = math.max(0, math.min(1, p.volume))
  return p
end

-- random numbers: the generators', repeatable (a seed: the same sound)
local function rng(seed)
  local s = math.floor(tonumber(seed) or os.time()) % 2147483647
  if s <= 0 then s = s + 2147483646 end
  local r = {}
  for _ = 1, 3 do s = s * 48271 % 2147483647 end   -- (small seeds: their first numbers would be tiny)
  function r.f(range) s = s * 16807 % 2147483647; return (s - 1) / 2147483646 * (range or 1) end   -- frnd: 0..range
  function r.i(n) return math.floor(r.f(n + 1 - 1e-9)) end                                       -- rnd: 0..n
  return r
end
M.rng = rng

-- the seven buttons ---------------------------------------------------
M.PRESETS = { "coin", "laser", "explosion", "powerup", "hit", "jump", "blip" }
M.PRESET_NAMES = { coin = "Pickup / coin", laser = "Laser / shoot", explosion = "Explosion",
                   powerup = "Powerup", hit = "Hit / hurt", jump = "Jump", blip = "Blip / select" }
local GEN = {}
function GEN.coin(p, R)
  p.base_freq = 0.4 + R.f(0.5)
  p.env_attack = 0
  p.env_sustain = R.f(0.1)
  p.env_decay = 0.1 + R.f(0.4)
  p.env_punch = 0.3 + R.f(0.3)
  if R.i(1) == 1 then p.arp_speed = 0.5 + R.f(0.2); p.arp_mod = 0.2 + R.f(0.4) end
end
function GEN.laser(p, R)
  p.wave = R.i(2)
  if p.wave == 2 and R.i(1) == 1 then p.wave = R.i(1) end
  p.base_freq = 0.5 + R.f(0.5)
  p.freq_limit = p.base_freq - 0.2 - R.f(0.6)
  if p.freq_limit < 0.2 then p.freq_limit = 0.2 end
  p.freq_ramp = -0.15 - R.f(0.2)
  if R.i(2) == 0 then p.base_freq = 0.3 + R.f(0.6); p.freq_limit = R.f(0.1); p.freq_ramp = -0.35 - R.f(0.3) end
  if R.i(1) == 1 then p.duty = R.f(0.5); p.duty_ramp = R.f(0.2)
  else p.duty = 0.4 + R.f(0.5); p.duty_ramp = -R.f(0.7) end
  p.env_attack = 0
  p.env_sustain = 0.1 + R.f(0.2)
  p.env_decay = R.f(0.4)
  if R.i(1) == 1 then p.env_punch = R.f(0.3) end
  if R.i(2) == 0 then p.pha_offset = R.f(0.2); p.pha_ramp = -R.f(0.2) end
  if R.i(1) == 1 then p.hpf_freq = R.f(0.3) end
end
function GEN.explosion(p, R)
  p.wave = 3
  if R.i(1) == 1 then p.base_freq = 0.1 + R.f(0.4); p.freq_ramp = -0.1 + R.f(0.4)
  else p.base_freq = 0.2 + R.f(0.7); p.freq_ramp = -0.2 - R.f(0.2) end
  p.base_freq = p.base_freq * p.base_freq
  if R.i(4) == 0 then p.freq_ramp = 0 end
  if R.i(2) == 0 then p.repeat_speed = 0.3 + R.f(0.5) end
  p.env_attack = 0
  p.env_sustain = 0.1 + R.f(0.3)
  p.env_decay = R.f(0.5)
  if R.i(1) == 0 then p.pha_offset = -0.3 + R.f(0.9); p.pha_ramp = -R.f(0.3) end
  p.env_punch = 0.2 + R.f(0.6)
  if R.i(1) == 1 then p.vib_strength = R.f(0.7); p.vib_speed = R.f(0.6) end
  if R.i(2) == 0 then p.arp_speed = 0.6 + R.f(0.3); p.arp_mod = 0.8 - R.f(1.6) end
end
function GEN.powerup(p, R)
  if R.i(1) == 1 then p.wave = 1 else p.duty = R.f(0.6) end
  if R.i(1) == 1 then
    p.base_freq = 0.2 + R.f(0.3); p.freq_ramp = 0.1 + R.f(0.4); p.repeat_speed = 0.4 + R.f(0.4)
  else
    p.base_freq = 0.2 + R.f(0.3); p.freq_ramp = 0.05 + R.f(0.2)
    if R.i(1) == 1 then p.vib_strength = R.f(0.7); p.vib_speed = R.f(0.6) end
  end
  p.env_attack = 0
  p.env_sustain = R.f(0.4)
  p.env_decay = 0.1 + R.f(0.4)
end
function GEN.hit(p, R)
  p.wave = R.i(2)
  if p.wave == 2 then p.wave = 3 end
  if p.wave == 0 then p.duty = R.f(0.6) end
  p.base_freq = 0.2 + R.f(0.6)
  p.freq_ramp = -0.3 - R.f(0.4)
  p.env_attack = 0
  p.env_sustain = R.f(0.1)
  p.env_decay = 0.1 + R.f(0.2)
  if R.i(1) == 1 then p.hpf_freq = R.f(0.3) end
end
function GEN.jump(p, R)
  p.wave = 0
  p.duty = R.f(0.6)
  p.base_freq = 0.3 + R.f(0.3)
  p.freq_ramp = 0.1 + R.f(0.2)
  p.env_attack = 0
  p.env_sustain = 0.1 + R.f(0.3)
  p.env_decay = 0.1 + R.f(0.2)
  if R.i(1) == 1 then p.hpf_freq = R.f(0.3) end
  if R.i(1) == 1 then p.lpf_freq = 1 - R.f(0.6) end
end
function GEN.blip(p, R)
  p.wave = R.i(1)
  if p.wave == 0 then p.duty = R.f(0.6) end
  p.base_freq = 0.2 + R.f(0.4)
  p.env_attack = 0
  p.env_sustain = 0.1 + R.f(0.1)
  p.env_decay = R.f(0.2)
  p.hpf_freq = 0.1
end
function M.preset(name, seed)                      -- -> a new sound of that kind (nil: no such kind)
  local g = GEN[name]
  if not g then return nil end
  local p = M.defaults()
  g(p, rng(seed))
  return M.check(p)
end

-- Randomize: anything (the wave kept)
function M.randomize(p, seed)
  local R = rng(seed)
  local function sr() return R.f(2) - 1 end
  local q = M.defaults()
  q.wave, q.volume = p and p.wave or 0, p and p.volume or q.volume
  q.base_freq = sr() ^ 2
  if R.i(1) == 1 then q.base_freq = sr() ^ 3 + 0.5 end
  q.freq_limit = 0
  q.freq_ramp = sr() ^ 5
  if q.base_freq > 0.7 and q.freq_ramp > 0.2 then q.freq_ramp = -q.freq_ramp end
  if q.base_freq < 0.2 and q.freq_ramp < -0.05 then q.freq_ramp = -q.freq_ramp end
  q.freq_dramp = sr() ^ 3
  q.duty = sr()
  q.duty_ramp = sr() ^ 3
  q.vib_strength = sr() ^ 3
  q.vib_speed = sr()
  q.vib_delay = sr()
  q.env_attack = sr() ^ 3
  q.env_sustain = sr() ^ 2
  q.env_decay = sr()
  q.env_punch = R.f(0.8) ^ 2
  if q.env_attack + q.env_sustain + q.env_decay < 0.2 then
    q.env_sustain = q.env_sustain + 0.2 + R.f(0.3)
    q.env_decay = q.env_decay + 0.2 + R.f(0.3)
  end
  q.lpf_resonance = sr()
  q.lpf_freq = 1 - R.f(1) ^ 3
  q.lpf_ramp = sr() ^ 3
  if q.lpf_freq < 0.1 and q.lpf_ramp < -0.05 then q.lpf_ramp = -q.lpf_ramp end
  q.hpf_freq = R.f(1) ^ 5
  q.hpf_ramp = sr() ^ 5
  q.pha_offset = sr() ^ 3
  q.pha_ramp = sr() ^ 3
  q.repeat_speed = sr()
  q.arp_speed = sr()
  q.arp_mod = sr()
  return M.check(q)                                -- (to the sliders' ranges)
end

-- Mutate: every value nudged a little, or not (the frequency limit kept)
function M.mutate(p, seed)
  local R = rng(seed)
  local q = M.check(p)
  for _, d in ipairs(M.PARAMS) do
    if d[1] ~= "freq_limit" and R.i(1) == 1 then q[d[1]] = q[d[1]] + R.f(0.1) - 0.05 end
  end
  return M.check(q)
end

-- the synth -----------------------------------------------------------
-- ResetSample + SynthSample, as the original: 8x supersampled, an envelope
-- (attack, sustain + punch, decay), a slide, vibrato, arpeggio, duty sweep,
-- retrigger, a low-pass and a high-pass filter, a phaser. opts.noise_seed:
-- the noise wave's numbers (the same each time it renders); opts.gain (4, as
-- the original's WAV export; 1: as its live playback)
function M.render(p, opts)
  p = M.check(p)
  opts = opts or {}
  local R = rng(opts.noise_seed or 1)
  local floor, sin, abs, pi = math.floor, math.sin, math.abs, math.pi
  local master_vol, max_len = 0.05, opts.max_samples or M.RATE * 10

  local phase, fperiod, fmaxperiod, fslide, fdslide, period
  local square_duty, square_slide, arp_mod, arp_time, arp_limit
  local fltp, fltdp, fltw, fltw_d, fltdmp, fltphp, flthp, flthp_d
  local vib_phase, vib_speed, vib_amp, env_vol, env_stage, env_time
  local env_length = {}
  local fphase, fdphase, iphase, ipp, rep_time, rep_limit
  local phaser = {}
  local noise = {}

  local function reset(restart)
    if not restart then phase = 0 end
    fperiod = 100 / (p.base_freq * p.base_freq + 0.001)
    period = floor(fperiod)
    fmaxperiod = 100 / (p.freq_limit * p.freq_limit + 0.001)
    fslide = 1 - (p.freq_ramp ^ 3) * 0.01
    fdslide = -(p.freq_dramp ^ 3) * 0.000001
    square_duty = 0.5 - p.duty * 0.5
    square_slide = -p.duty_ramp * 0.00005
    if p.arp_mod >= 0 then arp_mod = 1 - (p.arp_mod ^ 2) * 0.9 else arp_mod = 1 + (p.arp_mod ^ 2) * 10 end
    arp_time = 0
    arp_limit = floor((1 - p.arp_speed) ^ 2 * 20000 + 32)
    if p.arp_speed == 1 then arp_limit = 0 end
    if not restart then
      fltp, fltdp = 0, 0
      fltw = (p.lpf_freq ^ 3) * 0.1
      fltw_d = 1 + p.lpf_ramp * 0.0001
      fltdmp = 5 / (1 + (p.lpf_resonance ^ 2) * 20) * (0.01 + fltw)
      if fltdmp > 0.8 then fltdmp = 0.8 end
      fltphp = 0
      flthp = (p.hpf_freq ^ 2) * 0.1
      flthp_d = 1 + p.hpf_ramp * 0.0003
      vib_phase = 0
      vib_speed = (p.vib_speed ^ 2) * 0.01
      vib_amp = p.vib_strength * 0.5
      env_vol, env_stage, env_time = 0, 0, 0
      env_length[0] = floor(p.env_attack * p.env_attack * 100000)
      env_length[1] = floor(p.env_sustain * p.env_sustain * 100000)
      env_length[2] = floor(p.env_decay * p.env_decay * 100000)
      fphase = (p.pha_offset ^ 2) * 1020
      if p.pha_offset < 0 then fphase = -fphase end
      fdphase = (p.pha_ramp ^ 2) * 1
      if p.pha_ramp < 0 then fdphase = -fdphase end
      iphase = abs(floor(fphase))
      ipp = 0
      for i = 0, 1023 do phaser[i] = 0 end
      for i = 0, 31 do noise[i] = R.f(2) - 1 end
      rep_time = 0
      rep_limit = floor((1 - p.repeat_speed) ^ 2 * 20000 + 32)
      if p.repeat_speed == 0 then rep_limit = 0 end
    end
  end

  reset(false)
  local out, n = {}, 0
  local playing = true
  local wave, punch = p.wave, p.env_punch
  local gain = 2 * p.volume * master_vol / 8 * (opts.gain or 4)   -- (x4: the original's export gain, "to get reasonable output volume")
  while playing and n < max_len do
    rep_time = rep_time + 1
    if rep_limit ~= 0 and rep_time >= rep_limit then rep_time = 0; reset(true) end
    arp_time = arp_time + 1                          -- (the frequency jumps once)
    if arp_limit ~= 0 and arp_time >= arp_limit then arp_limit = 0; fperiod = fperiod * arp_mod end
    fslide = fslide + fdslide
    fperiod = fperiod * fslide
    if fperiod > fmaxperiod then
      fperiod = fmaxperiod
      if p.freq_limit > 0 then playing = false end
    end
    local rfperiod = fperiod
    if vib_amp > 0 then
      vib_phase = vib_phase + vib_speed
      rfperiod = fperiod * (1 + sin(vib_phase) * vib_amp)
    end
    period = floor(rfperiod)
    if period < 8 then period = 8 end
    square_duty = square_duty + square_slide
    if square_duty < 0 then square_duty = 0 end
    if square_duty > 0.5 then square_duty = 0.5 end
    env_time = env_time + 1                          -- the volume envelope
    if env_time > env_length[env_stage] then
      env_time = 0
      env_stage = env_stage + 1
      if env_stage == 3 then playing = false; env_stage = 2 end
    end
    if env_stage == 0 then env_vol = env_length[0] > 0 and env_time / env_length[0] or 0 end
    if env_stage == 1 then env_vol = 1 + (1 - (env_length[1] > 0 and env_time / env_length[1] or 0)) * 2 * punch end
    if env_stage == 2 then env_vol = 1 - (env_length[2] > 0 and env_time / env_length[2] or 1) end
    if not playing then break end
    fphase = fphase + fdphase                        -- the phaser's step
    iphase = abs(floor(fphase))
    if iphase > 1023 then iphase = 1023 end
    if flthp_d ~= 0 then
      flthp = flthp * flthp_d
      if flthp < 0.00001 then flthp = 0.00001 end
      if flthp > 0.1 then flthp = 0.1 end
    end
    local ssample = 0
    for _ = 1, 8 do                                  -- 8x supersampling
      local sample = 0
      phase = phase + 1
      if phase >= period then
        phase = phase % period
        if wave == 3 then for i = 0, 31 do noise[i] = R.f(2) - 1 end end
      end
      local fp = phase / period
      if wave == 0 then sample = fp < square_duty and 0.5 or -0.5
      elseif wave == 1 then sample = 1 - fp * 2
      elseif wave == 2 then sample = sin(fp * 2 * pi)
      else sample = noise[floor(phase * 32 / period)] or 0 end
      local pp = fltp                                -- the low-pass filter
      fltw = fltw * fltw_d
      if fltw < 0 then fltw = 0 end
      if fltw > 0.1 then fltw = 0.1 end
      if p.lpf_freq ~= 1 then
        fltdp = fltdp + (sample - fltp) * fltw
        fltdp = fltdp - fltdp * fltdmp
      else
        fltp = sample; fltdp = 0
      end
      fltp = fltp + fltdp
      fltphp = fltphp + fltp - pp                    -- the high-pass filter
      fltphp = fltphp - fltphp * flthp
      sample = fltphp
      phaser[ipp % 1024] = sample                    -- the phaser
      sample = sample + phaser[(ipp - iphase + 1024) % 1024]
      ipp = (ipp + 1) % 1024
      ssample = ssample + sample * env_vol
    end
    ssample = ssample * gain
    if ssample > 1 then ssample = 1 elseif ssample < -1 then ssample = -1 end
    n = n + 1
    out[n] = ssample
  end
  return out
end

-- samples -> 16-bit little-endian PCM (a string): host_audio_play's, a WAV's
function M.pcm16(s)
  local parts, chunk = {}, {}
  local char, floor = string.char, math.floor
  for i = 1, #s do
    local v = floor(s[i] * 32767 + 0.5)
    if v < 0 then v = v + 65536 end
    chunk[#chunk + 1] = char(v % 256, floor(v / 256))
    if #chunk == 4096 then parts[#parts + 1] = table.concat(chunk); chunk = {} end
  end
  parts[#parts + 1] = table.concat(chunk)
  return table.concat(parts)
end
local function u32(n) return string.char(n % 256, math.floor(n / 256) % 256, math.floor(n / 65536) % 256, math.floor(n / 16777216) % 256) end
local function u16(n) return string.char(n % 256, math.floor(n / 256) % 256) end
function M.wav(s, rate)                            -- a mono 16-bit .wav file, as a string
  rate = rate or M.RATE
  local data = M.pcm16(s)
  return "RIFF" .. u32(36 + #data) .. "WAVE" .. "fmt " .. u32(16) .. u16(1) .. u16(1) .. u32(rate)
      .. u32(rate * 2) .. u16(2) .. u16(16) .. "data" .. u32(#data) .. data
end

return M
