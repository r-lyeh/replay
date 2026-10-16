---@meta
-- dd.lua - the debug draw API (global `dd`), for the editor: the node graph
-- names call pins after these parameters (and LuaLS can read it too).
-- Implemented in C: editor/overlay.h. Drawn over the game area; no-ops in a
-- standalone game. Kept until the next world tick.
-- color = { r, g, b [, a] } (0..255) or "#rrggbb" / "#rrggbbaa"; default white.

dd = {}

---@param x1 number
---@param y1 number
---@param x2 number
---@param y2 number
---@param color? table|string
function dd.line(x1, y1, x2, y2, color) end

---@param x1 number
---@param y1 number
---@param x2 number
---@param y2 number
---@param color? table|string
function dd.arrow(x1, y1, x2, y2, color) end

--- x, y: the top-left corner
---@param x number
---@param y number
---@param w number
---@param h number
---@param color? table|string
---@param fill? boolean
function dd.rect(x, y, w, h, color, fill) end

---@param x number
---@param y number
---@param r number
---@param color? table|string
---@param fill? boolean
function dd.circle(x, y, r, color, fill) end

--- filled
---@param x1 number
---@param y1 number
---@param x2 number
---@param y2 number
---@param x3 number
---@param y3 number
---@param color? table|string
function dd.tri(x1, y1, x2, y2, x3, y3, color) end

---@param x number
---@param y number
---@param size_px? number
---@param color? table|string
function dd.cross(x, y, size_px, color) end

--- 8 px debug font, unscaled
---@param x number
---@param y number
---@param text string
---@param color? table|string
function dd.text(x, y, text, color) end

--- following calls use game-area pixels (true) or world units (false, the default)
---@param on boolean
function dd.screen(on) end

--- messages, top-left
function dd.log(...) end
function dd.warn(...) end
function dd.error(...) end
