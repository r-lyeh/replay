-- editor.lua - a material editor: .mat files as node graphs (runs in lite).
-- An example of a plugin built on the canvas (editor/3rd/lite/data/plugins/canvas):
-- canvas.GraphView does the drawing, the camera and the editing; this file
-- says what nodes there are, reads and writes the file, and draws a colour
-- swatch / a value inside some nodes. Saving this file reloads the plugin.
--
-- A .mat file is Lua data: return { nodes = { { id, kind, x, y, data } },
-- links = { { from, out, to, input } } } (canvas.GraphView's graph).
local P = ...
P.title = "Material editor"                         -- (its name in menus: Open with, the main menu's Plugins)
local core = require "core"
local canvas = require "plugins.canvas"
local D, C = canvas.draw, canvas.C

local MatView = canvas.GraphView:extend()

MatView.types = { color = "#c7c729", float = "#a1a1a1", vec2 = "#6363c7" }

MatView.kinds = {
  output   = { title = "Material Output", color = "#8a2b2b",
               ins = { { "albedo", "color" }, { "roughness", "float" }, { "metallic", "float" }, { "emission", "color" }, { "alpha", "float" } } },
  color    = { title = "Color", color = "#6a5a20", outs = { { "color", "color" } } },
  number   = { title = "Value", color = "#3f5a3a", outs = { { "value", "float" } } },
  uv       = { title = "UV", color = "#2e5470", outs = { { "uv", "vec2" } } },
  texture  = { title = "Image Texture", color = "#2e5470",
               ins = { { "uv", "vec2" } }, outs = { { "color", "color" }, { "alpha", "float" } } },
  mix      = { title = "Mix", color = "#3c3c83",
               ins = { { "a", "color" }, { "b", "color" }, { "factor", "float" } }, outs = { { "color", "color" } } },
  multiply = { title = "Multiply", color = "#3c3c83",
               ins = { { "a", "color" }, { "b", "color" } }, outs = { { "color", "color" } } },
  scale    = { title = "Scale", color = "#3c3c83",
               ins = { { "color", "color" }, { "by", "float" } }, outs = { { "color", "color" } } },
}

local function read(file)
  local f = io.open(file, "rb")
  if not f then return nil, "can't read" end
  local src = f:read("*a")
  f:close()
  local fn, err = load(src, "=" .. file, "t", {})  -- (data: nothing runs with any power)
  if not fn then return nil, err end
  local ok, v = pcall(fn)
  if not ok or type(v) ~= "table" then return nil, ok and "not a table" or v end
  return v
end

function MatView:new(state)
  self.filename = state and state.filename or ""
  local g, err = read(self.filename)
  self.err = not g and err or nil
  MatView.super.new(self, g)
  if state then self:set_camera(state.cam) end
end

function MatView:get_name() return (self.filename:match("[^/\\]*$") or "?") .. (self.dirty and "*" or "") end
function MatView:get_state() return { filename = self.filename, cam = self:camera_state() } end

function MatView:save()
  local f = io.open(self.filename, "wb")
  if not f then core.error("can't write %s", self.filename) return end
  f:write("-- a material (plugins/materials): its nodes and the wires between them\nreturn ",
          canvas.to_lua({ nodes = self.graph.nodes, links = self.graph.links }), "\n")
  f:close()
  self.dirty = false
  core.log("Saved %s", self:get_name())
end

-- inside some nodes: the colour, the value, the image's name
function MatView:node_extra(n)
  if n.kind == "color" or n.kind == "number" or n.kind == "texture" then return 22 end
  return 0
end
function MatView:draw_node_extra(n, x, y, w, h, z)
  local d, pad = n.data or {}, 8 * z
  if n.kind == "color" then
    local c = { math.floor((d[1] or 1) * 255), math.floor((d[2] or 1) * 255), math.floor((d[3] or 1) * 255), 255 }
    D.rrect(x + pad, y, w - 2 * pad, h, 3 * z, C.outline)
    D.rrect(x + pad + z, y + z, w - 2 * pad - 2 * z, h - 2 * z, 3 * z, c)
  else
    D.rrect(x + pad, y, w - 2 * pad, h, 3 * z, C.field)
    local t = n.kind == "number" and string.format("%g", d.value or 0) or tostring(d.image or "(no image)")
    local F = D.font(12 * z)
    D.text(F, t, x + pad + (w - 2 * pad - F:get_width(t)) / 2, y, C.text, h)
  end
end

function MatView:add_node(kind, wx, wy, data)       -- (new ones: sensible values)
  local defaults = { color = { 0.8, 0.8, 0.8 }, number = { value = 0.5 }, texture = { image = "" } }
  return MatView.super.add_node(self, kind, wx, wy, data or defaults[kind])
end

function MatView:draw_overlay()
  MatView.super.draw_overlay(self)
  if self.err then self:draw_status("can't read: " .. tostring(self.err)) end
end

P.open_with(P.read("files") or {}, MatView)
return MatView
