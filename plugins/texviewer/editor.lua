-- editor.lua - the texture viewer's tab (runs in lite; see
-- editor/3rd/lite/data/plugins/projectplugins.lua for what P gives). A canvas view
-- (editor/3rd/lite/data/plugins/canvas): the world is the image, one unit a pixel.
-- The wheel (CTRL too) zooms around the mouse, dragging pans, double-click
-- toggles fit / 100%, right-click: its menu (search, fit, zoom, background,
-- pixel grid, reload, its source). Its settings (config.lua) and the files it
-- opens (files.lua) are read again when they change on disk (a Save in the
-- tree's /plugins/texviewer); this file, saved, reloads the plugin.
local P = ...
P.title = "Texture viewer"                         -- (its name in menus: Open with, the main menu's Plugins)
local core = require "core"
local style = require "core.style"
local canvas = require "plugins.canvas"
local D = canvas.draw

local DEFAULTS = { background = "checker", checker = 1.5, fit = true, grid = 8, zoom_step = 1.25, zoom_max = 64 }
local cfg = {}
local function load_config()
  local c = P.read("config")
  cfg = {}
  for k, v in pairs(DEFAULTS) do cfg[k] = v end
  if type(c) == "table" then for k, v in pairs(c) do if DEFAULTS[k] ~= nil and type(v) == type(DEFAULTS[k]) then cfg[k] = v end end end
  cfg.checker = math.max(0.1, math.min(50, cfg.checker))   -- (% of the monitor's height)
  cfg.zoom_step = math.max(1.01, cfg.zoom_step)
end

local TexView = canvas.View:extend()
TexView.wheel_zooms = true                          -- (an image viewer: the wheel zooms)
TexView.grid = false                                -- (no canvas grid: the pixel grid, when zoomed in)
TexView.zoom_min = 0.01
TexView.fit_frac = 0.94

function TexView:new(state)
  TexView.super.new(self)
  self.filename = state and state.filename or ""
  self.zoom_max, self.zoom_step = cfg.zoom_max, cfg.zoom_step
  if state then
    self.bg, self.grid_on = state.bg, state.grid_on   -- (the menu's, for this tab)
    self:set_camera(state.cam)
  end
  if not cfg.fit and not (state and state.cam) then self.fitting = false; self.start_100 = true end
  self:reload()
end

function TexView:reload()
  local info = system.get_file_info(self.filename)
  self.mtime = info and info.modified
  self.img, self.err = renderer.image.load(self.filename)
  self.iw, self.ih = 0, 0
  if self.img then self.iw, self.ih = self.img:get_size() end
  core.redraw = true
end

function TexView:get_name() return self.filename:match("[^/\\]*$") end
function TexView:get_state()
  return { filename = self.filename, cam = self:camera_state(), bg = self.bg, grid_on = self.grid_on }
end

function TexView:bounds()
  if self.iw == 0 then return nil end
  return 0, 0, self.iw, self.ih
end

local function background(self) return self.bg or cfg.background end   -- (the menu sets them per tab)
local function grid_on(self) if self.grid_on ~= nil then return self.grid_on end return cfg.grid > 0 end

function TexView:actual_size()                      -- 100%, the image centred
  self.cam.zoom = 1
  self:center_on(self.iw / 2, self.ih / 2)
end

function TexView:on_canvas_pressed(button, wx, wy, clicks)
  if button == "left" and clicks >= 2 then          -- fit <-> 100%
    if self.fitting then self:actual_size() else self:fit() end
    return true
  end
  return false                                      -- (else: the canvas pans)
end

local next_check = 0
function TexView:update()
  if self.start_100 and self.size.x > 0 and self.iw > 0 then self.start_100 = nil; self:actual_size() end
  TexView.super.update(self)
  local now = system.get_time()
  if now < (self.next_check or 0) then return end
  self.next_check = now + 0.5                      -- the file changed on disk: read it again
  local info = system.get_file_info(self.filename)
  if info and info.modified ~= self.mtime then self:reload() end
  if now >= next_check then                        -- (once for all tabs) its settings / files changed
    next_check = now + 0.5
    if P.changed("config") then load_config(); core.redraw = true end
    if P.changed("files") then P.open_with(P.read("files") or {}, TexView) end
  end
  self.zoom_max, self.zoom_step = cfg.zoom_max, cfg.zoom_step
end

function TexView:draw_background_color()
  local bg = background(self)
  return bg == "light" and { 236, 236, 236, 255 } or bg == "dark" and { 24, 24, 24, 255 } or style.background
end

function TexView:draw_canvas()
  local px, py, pw, ph = self.position.x, self.position.y, self.size.x, self.size.y
  if not self.img then
    renderer.draw_text(style.font, "can't show " .. self:get_name() .. ": " .. tostring(self.err),
                       px + style.padding.x, py + style.padding.y, style.text)
    return
  end
  local z = self:z()
  local x, y = self:to_screen(0, 0)
  local w, h = math.floor(self.iw * z), math.floor(self.ih * z)
  x, y = math.floor(x), math.floor(y)
  local vx1, vy1 = math.max(x, px), math.max(y, py)   -- what of it is on screen
  local vx2, vy2 = math.min(x + w, px + pw), math.min(y + h, py + ph)
  if background(self) == "checker" and vx2 > vx1 and vy2 > vy1 then   -- squares: a share of the monitor, the same everywhere
    local light = { style.background3[1], style.background3[2], style.background3[3], 255 }
    local dark = { math.floor(light[1] * 0.82), math.floor(light[2] * 0.82), math.floor(light[3] * 0.82), 255 }
    D.checker(vx1, vy1, vx2 - vx1, vy2 - vy1, math.max(2, math.floor(D.vh(cfg.checker) + 0.5)), lite_bg(light), lite_bg(dark), x, y)   -- (a background: the game shows through)
  end
  renderer.draw_image(self.img, x, y, w, h)
  if grid_on(self) and z >= math.max(cfg.grid, 4) and vx2 > vx1 and vy2 > vy1 then   -- pixels big enough: lines between them
    local c = { style.dim[1], style.dim[2], style.dim[3], 110 }
    local i0, i1 = math.floor((vx1 - x) / z), math.ceil((vx2 - x) / z)
    for i = i0, i1 do renderer.draw_rect(x + math.floor(i * z), vy1, 1, vy2 - vy1, c) end
    local j0, j1 = math.floor((vy1 - y) / z), math.ceil((vy2 - y) / z)
    for j = j0, j1 do renderer.draw_rect(vx1, y + math.floor(j * z), vx2 - vx1, 1, c) end
  end
end

function TexView:draw_overlay()
  if not self.img then return end
  self:draw_status(string.format("%s   %d x %d   %d%%%s", self:get_name(), self.iw, self.ih,
                                 math.floor(self:z() * 100 + 0.5), self.fitting and "  (fit)" or ""))
end

-- the right-click menu (the canvas's standard one: typing filters it)
function TexView:menu_items()
  local DIV = require("plugins.contextmenu").DIVIDER
  local function set(f) return function() f(self); core.redraw = true end end
  local bg = background(self)
  return {
    { text = "Fit", info = "dbl-click", checked = self.fitting, command = function() self:fit() end },
    { text = "100%", checked = not self.fitting and math.abs(self.cam.zoom - 1) < 1e-3, command = function() self:actual_size() end },
    { text = "Zoom in", info = "wheel", command = function() self:zoom_at(self.zoom_step) end },
    { text = "Zoom out", info = "wheel", command = function() self:zoom_at(1 / self.zoom_step) end },
    DIV,
    { text = "Background: checker", checked = bg == "checker", command = set(function(t) t.bg = "checker" end) },
    { text = "Background: dark", checked = bg == "dark", command = set(function(t) t.bg = "dark" end) },
    { text = "Background: light", checked = bg == "light", command = set(function(t) t.bg = "light" end) },
    { text = "Pixel grid", checked = grid_on(self), command = set(function(t) t.grid_on = not grid_on(t) end) },
    DIV,
    { text = "Reload image", command = function() self:reload() end },
    { text = "Copy path", command = function() system.set_clipboard(self.filename) end },
  }                                                -- (its source, reload, settings: the "Plugin: texviewer" submenu, last)
end

load_config()
P.open_with(P.read("files") or {}, TexView)
return TexView
