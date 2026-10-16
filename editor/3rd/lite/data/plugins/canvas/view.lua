-- view.lua - canvas.View: a lite tab with a camera (plugins/canvas). Extend
-- it for an editor that draws on a canvas: an image, a node graph, a curve.
--
-- The camera: world units -> screen pixels, screen = view corner + cam.x/y
-- + world * z (z = self:z(): the zoom, times lite's SCALE).
--   self:to_screen(wx, wy), self:to_world(sx, sy), self:z()
--   self:zoom_at(f, sx, sy)  zoom by f, the point under (sx, sy) stays there
--   self:pan_by(dx, dy)      move the world by pixels
--   self:fit(frac)           self:bounds() (a world rect) in view, filling frac
--   self:center_on(wx, wy)
-- While self.fitting (the default for a new tab) it fits again as the view
-- resizes; the first pan or zoom stops that.
--
-- The mouse (as the node graph): LMB on nothing / MMB drags pan, double-click
-- on nothing fits, the wheel scrolls (SHIFT: sideways) and CTRL+wheel zooms
-- (self.wheel_zooms: the wheel zooms, as an image viewer), RMB: the menu
-- (self:menu_items(), searchable; extend it: call CanvasView.menu_items).
-- What's on the canvas gets the mouse first, in world units:
--   self:on_canvas_pressed(button, wx, wy, clicks) -> true: taken (no pan)
--   self:on_canvas_moved(wx, wy), self:on_canvas_released(button, wx, wy)
-- Drawing: self:draw_canvas() (the camera set, clipped to the view, over the
-- background and the grid), then self:draw_overlay() (screen space: labels).
-- self.grid: world units between grid lines (false: none).
-- A view that edits a file: self:save(), self.dirty (CTRL+S; asked on close).
local core = require "core"
local keymap = require "core.keymap"
local style = require "core.style"
local View = require "core.view"
local D = require "plugins.canvas.draw"
local T = require "plugins.canvas.theme"
local C = T.C

local CanvasView = View:extend()
CanvasView.zoom_min, CanvasView.zoom_max = 0.1, 4
CanvasView.zoom_step = 1.1
CanvasView.wheel_zooms = false
CanvasView.grid = 24
CanvasView.fit_frac = 0.9
CanvasView.wants_ctrl_wheel = true                 -- (projectplugins.lua: CTRL+wheel comes here, not to the code's font)

function CanvasView:new()
  CanvasView.super.new(self)
  self.cursor = "arrow"
  self.cam = { x = 0, y = 0, zoom = 1 }
  self.fitting = true
end

function CanvasView:z() return self.cam.zoom * SCALE end
function CanvasView:to_screen(wx, wy)
  local z = self:z()
  return self.position.x + self.cam.x + wx * z, self.position.y + self.cam.y + wy * z
end
function CanvasView:to_world(sx, sy)
  local z = self:z()
  return (sx - self.position.x - self.cam.x) / z, (sy - self.position.y - self.cam.y) / z
end

function CanvasView:set_zoom(zoom, sx, sy)          -- (sx, sy: the point that stays; default the centre)
  sx = sx or self.position.x + self.size.x / 2
  sy = sy or self.position.y + self.size.y / 2
  zoom = math.max(self.zoom_min, math.min(self.zoom_max, zoom))
  local wx, wy = self:to_world(sx, sy)
  self.cam.zoom = zoom
  local z = self:z()
  self.cam.x, self.cam.y = sx - self.position.x - wx * z, sy - self.position.y - wy * z
  self.fitting = false
  core.redraw = true
end
function CanvasView:zoom_at(f, sx, sy) self:set_zoom(self.cam.zoom * f, sx, sy) end
function CanvasView:pan_by(dx, dy)
  self.cam.x, self.cam.y = self.cam.x + dx, self.cam.y + dy
  self.fitting = false
  core.redraw = true
end
function CanvasView:center_on(wx, wy)
  local z = self:z()
  self.cam.x, self.cam.y = self.size.x / 2 - wx * z, self.size.y / 2 - wy * z
  self.fitting = false
  core.redraw = true
end

function CanvasView:bounds() return nil end        -- the world rect fit shows: x, y, w, h (extend it)

function CanvasView:fit(frac)
  local x, y, w, h = self:bounds()
  if not x or self.size.x <= 0 then return end
  frac = frac or self.fit_frac
  w, h = math.max(w, 1e-6), math.max(h, 1e-6)
  local zoom = math.min(frac * self.size.x / w, frac * self.size.y / h) / SCALE
  self.cam.zoom = math.max(self.zoom_min, math.min(self.zoom_max, zoom))
  local z = self:z()
  self.cam.x = (self.size.x - w * z) / 2 - x * z
  self.cam.y = (self.size.y - h * z) / 2 - y * z
  self.fitting = true
  core.redraw = true
end

function CanvasView:update()
  CanvasView.super.update(self)
  if self.fitting and (self.size.x ~= self.fit_w or self.size.y ~= self.fit_h) then   -- (resized: fit again)
    self.fit_w, self.fit_h = self.size.x, self.size.y
    self:fit()
  end
end

-- the mouse ------------------------------------------------------------

function CanvasView:on_canvas_pressed(button, wx, wy, clicks) return false end
function CanvasView:on_canvas_moved(wx, wy) end
function CanvasView:on_canvas_released(button, wx, wy) end

function CanvasView:on_mouse_pressed(button, x, y, clicks)
  self.mx, self.my = x, y
  local wx, wy = self:to_world(x, y)
  if self:on_canvas_pressed(button, wx, wy, clicks) then return true end
  if button == "left" and clicks >= 2 then self:fit() return true end
  if button == "left" or button == "middle" then
    self.panning = button
    self.cursor = "hand"
    return true
  end
end

function CanvasView:on_mouse_moved(x, y, dx, dy)
  self.mx, self.my = x, y
  if self.panning then self:pan_by(dx, dy) return end
  self:on_canvas_moved(self:to_world(x, y))
end

function CanvasView:on_mouse_released(button, x, y)
  if self.panning then
    if self.panning == button then self.panning = nil; self.cursor = "arrow" end
    return
  end
  local wx, wy = self:to_world(x, y)
  self:on_canvas_released(button, wx, wy)
end

function CanvasView:on_mouse_wheel(dy, dx)
  local mx, my = self.mx, self.my
  if self.wheel_zooms or keymap.modkeys["ctrl"] then
    if dy and dy ~= 0 then self:zoom_at(dy > 0 and self.zoom_step or 1 / self.zoom_step, mx, my) end
    return true
  end
  local step = 60 * SCALE
  if keymap.modkeys["shift"] then dx, dy = dy, 0 end
  self:pan_by((dx or 0) * step, (dy or 0) * step)
  return true
end

-- the menu (RMB): plugins/canvas/init.lua registers it for every canvas view
function CanvasView:menu_items()
  return {
    { text = "Fit", info = "dbl-click", command = function() self:fit() end },
    { text = "100%", checked = math.abs(self.cam.zoom - 1) < 1e-3, command = function() self:set_zoom(1) end },
    { text = "Zoom in", info = "CTRL+wheel", command = function() self:zoom_at(self.zoom_step ^ 2) end },
    { text = "Zoom out", info = "CTRL+wheel", command = function() self:zoom_at(1 / self.zoom_step ^ 2) end },
  }
end

-- drawing ---------------------------------------------------------------

function CanvasView:draw_grid()
  local px, py, sw, sh = self.position.x, self.position.y, self.size.x, self.size.y
  local step = self.grid * self:z()
  local every = 5
  while step < 8 do step = step * 5 end            -- zoomed far out: fewer lines
  local ox, oy = self:to_screen(0, 0)
  local t = math.max(1, SCALE)
  local i0 = math.floor((px - ox) / step)
  for i = i0, i0 + math.ceil(sw / step) + 1 do
    renderer.draw_rect(ox + i * step, py, t, sh, lite_bg(i % every == 0 and C.grid2 or C.grid))
  end
  local j0 = math.floor((py - oy) / step)
  for j = j0, j0 + math.ceil(sh / step) + 1 do
    renderer.draw_rect(px, oy + j * step, sw, t, lite_bg(j % every == 0 and C.grid2 or C.grid))
  end
end

function CanvasView:draw_canvas() end
function CanvasView:draw_overlay() end

-- a line of text in a dark box, at the bottom left (what's shown, the zoom)
function CanvasView:draw_status(text)
  local px, py, ph = self.position.x, self.position.y, self.size.y
  local fh = style.font:get_height()
  local tw = style.font:get_width(text)
  renderer.draw_rect(px + 6 * SCALE, py + ph - fh - 10 * SCALE, tw + 12 * SCALE, fh + 6 * SCALE, { 0, 0, 0, 140 })
  renderer.draw_text(style.font, text, px + 12 * SCALE, py + ph - fh - 7 * SCALE, { 230, 230, 230, 255 })
end

function CanvasView:draw_background_color() return C.bg end

function CanvasView:draw()
  self:draw_background(self:draw_background_color())
  local px, py, sw, sh = self.position.x, self.position.y, self.size.x, self.size.y
  core.push_clip_rect(px, py, sw, sh)
  D.set_view(px, py, sw, sh)
  if self.grid then self:draw_grid() end
  self:draw_canvas()
  self:draw_overlay()
  if self.note then self.note:draw(nil, nil, { x = px, y = py, w = sw, h = sh }) end   -- (self:flash: bottom right, a few seconds)
  core.pop_clip_rect()
end

-- a short note, bottom right, for a few seconds (canvas.tip): "Saved", an error
function CanvasView:flash(text, err)
  self.note = self.note or require("plugins.canvas.tip").note()
  self.note:say(text, err)
end

-- the camera, for get_state / a new tab from it
function CanvasView:camera_state()
  if self.fitting then return nil end
  return { x = self.cam.x, y = self.cam.y, zoom = self.cam.zoom }
end
function CanvasView:set_camera(c)
  if type(c) ~= "table" or not c.zoom then return end
  self.cam.x, self.cam.y = c.x or 0, c.y or 0
  self.cam.zoom = math.max(self.zoom_min, math.min(self.zoom_max, c.zoom))
  self.fitting = false
end

function CanvasView:scroll_to_line() end           -- (lite asks every tab it opens a file in)

-- a view that edits a file: give it self:save() and set self.dirty; CTRL+S
-- saves it (canvas:save), closing it unsaved asks first (as a text tab)
function CanvasView:try_close(do_close)
  local config = require "core.config"
  if not (self.dirty and self.save) or not config.confirm_close_unsaved then return do_close() end
  local r = system.show_dialog("Unsaved changes", string.format("\"%s\" has unsaved changes.", self:get_name()), "Save", "Don't save", "Cancel")
  if r == 1 then self:save(); do_close()
  elseif r == 2 then do_close() end
end

return CanvasView
