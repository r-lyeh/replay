-- draw.lua - drawing on a canvas (plugins/canvas), in screen pixels: what
-- the node graph draws with (lines, discs, rounded boxes, curves, wires,
-- sockets, arrows), for any plugin's editor. Sizes are pixels: multiply by
-- the view's zoom yourself (canvas.View: self:z()).
local D = {}

local VX1, VY1, VX2, VY2 = -math.huge, -math.huge, math.huge, math.huge
-- the visible rect: curves wholly outside it aren't drawn (View:draw sets it)
function D.set_view(x, y, w, h) VX1, VY1, VX2, VY2 = x, y, x + w, y + h end

function D.line(x1, y1, x2, y2, color, w)
  renderer.draw_line(x1, y1, x2, y2, math.max(1, w or 1), color)
end

function D.disc(x, y, d, color) renderer.draw_line(x, y, x, y, d, color) end   -- a round cap: a disc, d wide

-- a rounded rectangle. Opaque: rects + anti-aliased discs at the corners;
-- translucent: one rect per corner row (nothing is painted twice).
-- top_only: square bottom corners (a header).
function D.rrect(x, y, w, h, r, c, top_only)
  -- whole pixels: lite's rects are integers (truncated, so -0.5 and 0.5 both
  -- land on 0) while the corner discs are anti-aliased floats; unrounded
  -- pieces drift a pixel apart at some zoom levels
  local x1, y1 = math.floor(x + 0.5), math.floor(y + 0.5)
  x, y, w, h = x1, y1, math.floor(x + w + 0.5) - x1, math.floor(y + h + 0.5) - y1
  r = math.floor(math.min(r, w / 2, h / 2))
  if r < 1 then renderer.draw_rect(x, y, w, h, c) return end
  local rb = top_only and 0 or r
  local dot = D.disc
  if (c[4] or 255) >= 255 then
    renderer.draw_rect(x + r, y, w - 2 * r, h, c)
    renderer.draw_rect(x, y + r, r, h - r - rb, c)
    renderer.draw_rect(x + w - r, y + r, r, h - r - rb, c)
    dot(x + r, y + r, 2 * r, c); dot(x + w - r, y + r, 2 * r, c)
    if top_only then
      renderer.draw_rect(x, y + h - r, r, r, c); renderer.draw_rect(x + w - r, y + h - r, r, r, c)
    else
      dot(x + r, y + h - r, 2 * r, c); dot(x + w - r, y + h - r, 2 * r, c)
    end
    return
  end
  renderer.draw_rect(x, y + r, w, h - r - rb, c)
  for i = 0, r - 1 do
    local dy = r - i - 0.5
    local inset = math.floor(r - math.sqrt(r * r - dy * dy) + 0.5)
    renderer.draw_rect(x + inset, y + i, w - 2 * inset, 1, c)
    if not top_only then renderer.draw_rect(x + inset, y + h - 1 - i, w - 2 * inset, 1, c) end
  end
end

-- a cubic curve, w pixels wide, in at most max_steps segments (default 24;
-- fewer when it's short)
function D.bezier(x1, y1, c1x, c1y, c2x, c2y, x2, y2, color, w, max_steps)
  w = w or 1
  local m = w * 3                                  -- off the view (the curve stays inside its 4 points' box): nothing to do
  if math.max(x1, c1x, c2x, x2) < VX1 - m or math.min(x1, c1x, c2x, x2) > VX2 + m
     or math.max(y1, c1y, c2y, y2) < VY1 - m or math.min(y1, c1y, c2y, y2) > VY2 + m then return end
  local flat, upright = y1 == c1y and c1y == c2y and c2y == y2, x1 == c1x and c1x == c2x and c2x == x2
  if flat or upright then                          -- all on one line: one segment (no joints to show), over
    local p0, p1, p2, p3                           -- what the curve covers (a short or backward wire overshoots):
    if flat then p0, p1, p2, p3 = x1, c1x, c2x, x2 else p0, p1, p2, p3 = y1, c1y, c2y, y2 end
    local lo, hi = math.min(p0, p3), math.max(p0, p3)   -- its ends, and where it turns (B'(t) = 0, 0 < t < 1)
    local a, b, c = -p0 + 3 * p1 - 3 * p2 + p3, 2 * (p0 - 2 * p1 + p2), p1 - p0
    local function at(t)
      if t > 0 and t < 1 then
        local u = 1 - t
        local v = u * u * u * p0 + 3 * u * u * t * p1 + 3 * u * t * t * p2 + t * t * t * p3
        lo, hi = math.min(lo, v), math.max(hi, v)
      end
    end
    if math.abs(a) < 1e-9 then
      if math.abs(b) > 1e-9 then at(-c / b) end
    else
      local disc = b * b - 4 * a * c
      if disc >= 0 then
        local sq = math.sqrt(disc)
        at((-b + sq) / (2 * a)); at((-b - sq) / (2 * a))
      end
    end
    if flat then return D.line(lo, y1, hi, y1, color, w) end
    return D.line(x1, lo, x1, hi, color, w)
  end
  local px, py = x1, y1
  local len = math.abs(c1x - x1) + math.abs(c1y - y1) + math.abs(c2x - c1x) + math.abs(c2y - c1y)
            + math.abs(x2 - c2x) + math.abs(y2 - c2y)
  local steps = math.max(1, math.min(max_steps or 24, math.floor(len / (14 * SCALE))))
  for i = 1, steps do
    local t = i / steps
    local u = 1 - t
    local cx = u * u * u * x1 + 3 * u * u * t * c1x + 3 * u * t * t * c2x + t * t * t * x2
    local cy = u * u * u * y1 + 3 * u * u * t * c1y + 3 * u * t * t * c2y + t * t * t * y2
    D.line(px, py, cx, cy, color, w)
    px, py = cx, cy
  end
end

-- a wire from an output (x1, y1: leaves rightwards) to an input (x2, y2:
-- arrives from the left), w wide; bend: how far it leaves straight (pixels);
-- outline: a darker colour drawn under it, wider (a highlighted wire)
function D.wire(x1, y1, x2, y2, color, w, bend, outline)
  local d = math.max(math.abs(x2 - x1) * 0.5, bend or 40 * SCALE)
  w = w or 1.2
  if outline then D.bezier(x1, y1, x1 + d, y1, x2 - d, y2, x2, y2, outline, w * 2) end
  D.bezier(x1, y1, x1 + d, y1, x2 - d, y2, x2, y2, color, w)
end

-- a socket: a disc of colour in a dark ring, d wide; hot: lit (hover)
function D.socket(x, y, d, color, hot, ring, ring_hot)
  D.disc(x, y, d * (hot and 1.18 or 1), hot and (ring_hot or { 255, 255, 255, 255 }) or ring or { 16, 16, 16, 255 })
  D.disc(x, y, d * (hot and 0.86 or 0.73), color)
end

-- an arrow head at x, y pointing along (dx, dy) (a unit vector), s long
function D.arrow(x, y, dx, dy, s, c, w)
  D.line(x - dx * s - dy * s * 0.8, y - dy * s + dx * s * 0.8, x, y, c, w)
  D.line(x - dx * s + dy * s * 0.8, y - dy * s - dx * s * 0.8, x, y, c, w)
end

-- a checkerboard in a rect, squares of s pixels from (ox, oy) (default: the
-- rect's corner), colours a and b
function D.checker(x, y, w, h, s, a, b, ox, oy)
  s = math.max(1, s)
  ox, oy = ox or x, oy or y
  renderer.draw_rect(x, y, w, h, a)
  local i0, j0 = math.floor((x - ox) / s), math.floor((y - oy) / s)
  local i1, j1 = math.ceil((x + w - ox) / s), math.ceil((y + h - oy) / s)
  for j = j0, j1 - 1 do
    local ry = oy + j * s
    local y1, y2 = math.max(ry, y), math.min(ry + s, y + h)
    if y2 > y1 then
      for i = i0 + ((i0 + j) % 2 == 0 and 1 or 0), i1 - 1, 2 do
        local rx = ox + i * s
        local x1, x2 = math.max(rx, x), math.min(rx + s, x + w)
        if x2 > x1 then renderer.draw_rect(x1, y1, x2 - x1, y2 - y1, b) end
      end
    end
  end
end

-- text centred vertically in a box of height h
function D.text(font, text, x, y, color, h)
  if h then y = y + (h - font:get_height()) / 2 end
  return renderer.draw_text(font, text, x, y, color)
end

-- fonts at any size (cached): the canvas's text follows its zoom. bold:
-- the same family's bold (fonts/font_bold.ttf: Roboto Bold, as font.ttf is
-- Roboto Regular), not the monospace's
local FONT, MONO, BOLD = DATADIR .. "/data/fonts/font.ttf", DATADIR .. "/data/fonts/monospace.ttf", DATADIR .. "/data/fonts/font_bold.ttf"
local fonts = {}
function D.font(px, mono, bold)
  px = math.max(4, math.floor(px * 2 + 0.5) / 2)
  local k = (mono and "m" or bold and "b" or "f") .. px
  if not fonts[k] then fonts[k] = renderer.font.load(mono and MONO or bold and BOLD or FONT, px) end
  return fonts[k]
end

-- p % of the monitor's height (vh) / width (vw), in pixels: a size that looks
-- the same on any monitor, whatever its resolution
function D.vh(p) local _, h = system.get_display_size() return h * p / 100 end
function D.vw(p) local w = system.get_display_size() return w * p / 100 end

return D
