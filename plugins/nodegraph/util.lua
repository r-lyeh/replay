-- util.lua - helpers shared by the node graph's view modules (part of the
-- nodegraph plugin, ours): text spans and lines, moving code, colours, numbers.
local resolve = require "plugins.nodegraph.resolve"
local U = {}

local function line_col(src, pos)
  local before = src:sub(1, pos - 1)
  local _, nl = before:gsub("\n", "")
  local ls = before:match(".*\n()") or 1
  return nl + 1, pos - ls + 1
end

local names_text                                  -- (below, with the rename)

names_text = function(f, l)
  local list = table.concat(l, ", ")
  if f.vararg then list = list .. (#l > 0 and ", ..." or "...") end
  if f.fmt == "func" then
    local rest = {}
    for i = 2, #l do rest[#rest + 1] = l[i] end
    list = table.concat(rest, ", ") .. (f.vararg and (#rest > 0 and ", ..." or "...") or "")
    return l[1] .. "(" .. list .. ")"
  end
  if f.fmt == "params" then return "(" .. list .. ")" end
  return list
end
local function names_of(f, text)
  local body = text:match("^%s*(.-)%s*$")
  local first
  if f.fmt == "func" then
    first, body = body:match("^([%w_]+)%s*%((.*)%)$")
    if not first then return nil, "write it as name(params)" end
  elseif f.fmt == "params" then
    body = body:match("^%((.*)%)$")
    if not body then return nil, "write it as (params)" end
  end
  local l = { first }                              -- (func: the name first)
  if not body:match("^%s*$") then
    for nm in (body .. ","):gmatch("%s*(.-)%s*,") do l[#l + 1] = nm end
  end
  if f.vararg then
    if l[#l] ~= "..." then return nil, "keep the ... at the end" end
    l[#l] = nil
  end
  if #l ~= #f.spans then return nil, string.format("%d names expected", #f.spans) end
  for _, nm in ipairs(l) do
    if not resolve.is_name(nm) then return nil, "not a name: " .. nm end
  end
  return l
end

-- a colour typed in the picker: #rgb or #rrggbb
local function pin_spans(pin)
  if pin.uses and #pin.uses > 0 and (pin.kind == nil or pin.kind == "var" or pin.kind == "global") then return pin.uses end
  if pin.pos then return { { pos = pin.pos, epos = pin.epos } } end
  return {}
end
-- the uses inside these spans: they go away with the edit (not a capture)
local function stmt_of(n)                          -- the statement a node belongs to
  while n and n.kind == "expr" do n = n.parent end
  return n
end
local function name_for(e_text)                    -- a name from the expression: a.b.c -> c, f(x) -> f
  local last = e_text:match("^[%w_%.:]-([%a_][%w_]*)%s*$")      -- a path: its last name
            or e_text:match("^[%w_%.:]-([%a_][%w_]*)%s*%b()%s*$") -- a call: what is called
  if last and resolve.is_name(last) and #last > 1 then return last end
  return "value"
end
local PALETTE = { false, "#e06c75", "#e5a050", "#e5c07b", "#98c379", "#56b6c2", "#61afef", "#c678dd" }

-- mouse (Blender-like):
--   LMB: select a node          LMB+drag on a node: move it
--   LMB+drag on a socket: wire it to another socket (rewire)
--   ALT+LMB on a socket or a wire: disconnect (its reads become nil)
--   RMB+drag: pan               RMB: menu (add a node; on a node: colour, delete)
--   double-click: edit a node's row (on the background: show the whole graph)

-- the wire under (x, y), as its link
local function near_curve(x, y, x1, y1, x2, y2, r)
  local d = math.max(math.abs(x2 - x1) * 0.5, 40 * SCALE)
  local c1x, c2x = x1 + d, x2 - d
  for i = 0, 24 do
    local t = i / 24
    local u = 1 - t
    local cx = u * u * u * x1 + 3 * u * u * t * c1x + 3 * u * t * t * c2x + t * t * t * x2
    local cy = u * u * u * y1 + 3 * u * u * t * y1 + 3 * u * t * t * y2 + t * t * t * y2
    if (cx - x) ^ 2 + (cy - y) ^ 2 <= r * r then return true end
  end
end

-- the curves of a flow wire (bezier control points, screen space): one
-- curve, or for a wire that wraps to the next row a snake: out to the right,
-- down into the gap above the row (ym), back left, into the pin
local function exec_path(x1, y1, x2, y2, ym, z)
  if not ym then
    local d = math.max(math.abs(x2 - x1) * 0.5, 40 * z)
    return { { x1, y1, x1 + d, y1, x2 - d, y2, x2, y2 } }
  end
  local r = 30 * z
  return {
    { x1, y1, x1 + 2 * r, y1, x1 + 2 * r, ym, x1, ym },
    { x1, ym, x1, ym, x2, ym, x2, ym },
    { x2, ym, x2 - 2 * r, ym, x2 - 2 * r, y2, x2, y2 },
  }
end

local function near_path(x, y, path, rad)
  for _, c in ipairs(path) do
    for i = 0, 24 do
      local t = i / 24
      local u = 1 - t
      local cx = u * u * u * c[1] + 3 * u * u * t * c[3] + 3 * u * t * t * c[5] + t * t * t * c[7]
      local cy = u * u * u * c[2] + 3 * u * u * t * c[4] + 3 * u * t * t * c[6] + t * t * t * c[8]
      if (cx - x) ^ 2 + (cy - y) ^ 2 <= rad * rad then return true end
    end
  end
end

local function frame_of(el)
  local p = el.parent
  while p do
    if p.head then return p end
    p = p.parent
  end
end

-- where a statement dropped at graph point (gx, gy) goes: after the statement
-- left of it in the same function, or first in the body right of a header;
-- at the top level, after the statement above it
local function line_start(src, p) return (src:sub(1, p - 1):match(".*\n()")) or 1 end
local function next_line(src, p)                    -- the start of the line after p's (nil: none)
  local nl = src:find("\n", p, true)
  return nl and nl + 1 or nil
end
local function rest_blank(src, p)                   -- nothing but spaces / a comment after p on its line
  local rest = src:match("^[^\n]*", p) or ""
  return rest:match("^%s*$") or rest:match("^%s*%-%-")
end
local function indent_at(src, p) return src:match("^[ \t]*", line_start(src, p)) end
local function dedent(text)
  local lines, min = {}, math.huge
  for l in (text .. "\n"):gmatch("([^\n]*)\n") do
    lines[#lines + 1] = l
    if l:match("%S") then min = math.min(min, #l:match("^[ \t]*")) end
  end
  while #lines > 0 and not lines[#lines]:match("%S") do lines[#lines] = nil end
  while #lines > 0 and not lines[1]:match("%S") do table.remove(lines, 1) end
  if min == math.huge then min = 0 end
  for i, l in ipairs(lines) do lines[i] = l:sub(min + 1) end
  return lines
end
local function reindent(lines, indent)
  local out = {}
  for i, l in ipairs(lines) do out[i] = l:match("%S") and (indent .. l) or "" end
  return table.concat(out, "\n") .. "\n"
end
local function float_text(lines, dx, dy, indent)   -- a --[==[@float ... ]==] block
  local body = table.concat(lines, "\n")
  local lvl = ""
  while body:find("]" .. lvl .. "]", 1, true) do lvl = lvl .. "=" end
  return indent .. "--[" .. lvl .. "[@float dx=" .. math.floor(dx + 0.5) .. " dy=" .. math.floor(dy + 0.5) .. "\n"
         .. reindent(lines, indent) .. indent .. "]" .. lvl .. "]\n"
end

local function float_span(src, F)
  local a, b = F.pos, F.epos
  local ls = line_start(src, a)
  if src:sub(ls, a - 1):match("^%s*$") then a = ls end
  local rest = src:match("^[ \t]*\n", b + 1)
  if rest then b = b + #rest end
  return a, b
end

local function frame_of_node(n)
  local p = n.parent
  while p and not p.head do p = p.parent end
  return p
end

-- a box around these nodes, written as --@comment at the top of their
-- function's body (the file's top for the top level)
local function move_tree(el, dx, dy)
  el.x, el.y = el.x + dx, el.y + dy
  for _, k in ipairs(el.kids or {}) do move_tree(k, dx, dy) end
end

-- a node dragged (live): it alone; a frame or floating code: everything in
-- it (like the offsets in graph.lua)
local function move_node(el, dx, dy)
  if el.head or el.float then return move_tree(el, dx, dy) end
  el.x, el.y = el.x + dx, el.y + dy
end

local function movable(n)
  if n and n.edit and n.edit.kind == "float" then return true end
  return n and n.edit and (n.edit.insert_line or n.edit.insert_pos or (n.frame and n.frame.tag or n.edit.tag)) and true or false
end

-- what to drag for these nodes: the element of each (a header: its frame),
-- leaving out those inside another dragged one (they move with it)
local function drag_roots(nodes)
  local el_of, set = {}, {}
  for _, n in ipairs(nodes) do
    if movable(n) then
      local el = n.float_el or n.frame or n        -- floating code moves as one
      if not set[el] then el_of[#el_of + 1] = { n, el }; set[el] = true end
    end
  end
  -- (an ancestor's move reaches el only when it's a frame / floating code
  -- holding it; see graph.lua)
  local out = {}
  for _, it in ipairs(el_of) do
    local c, p, inside = it[2], it[2].parent, false
    while p do
      if set[p] and (p.head or p.float) then inside = true; break end
      c, p = p, p.parent
    end
    if not inside then out[#out + 1] = it end
  end
  return out
end
local function num_text(sk_text, preview, pos)       -- preview: { [pos] = text } while dragging
  return preview and preview[pos] or sk_text
end
local function draggable(t) return t and t:match("^%-?%d+%.?%d*$") ~= nil end
local function slider_value(h, x)
  local a, b, st = h.range[1], h.range[2], h.range[3]
  local whole = math.floor(a) == a and math.floor(b) == b and not h.text:find("%.")
  st = st or (whole and 1 or (b - a) / 100)
  local v = a + math.max(0, math.min(1, (x - h.x) / h.w)) * (b - a)
  v = a + math.floor((v - a) / st + 0.5) * st
  local d = #(tostring(st):match("%.(%d+)") or "")
  if d == 0 and not whole then d = #(h.text:match("%.(%d+)") or "") end
  return d > 0 and string.format("%." .. d .. "f", v) or tostring(math.floor(v + 0.5))
end
local function dragged_number(text, dx)
  local d = #(text:match("%.(%d+)") or "")
  local v = tonumber(text) or 0
  if d == 0 then return tostring(math.floor(v + dx / (3 * SCALE) + 0.5)) end
  local step = 10 ^ -d
  return string.format("%." .. d .. "f", v + math.floor(dx / (2 * SCALE) + 0.5) * step)
end
local function hsv2rgb(h, s, v)
  local i = math.floor(h * 6) % 6
  local f = h * 6 - math.floor(h * 6)
  local p, q, t = v * (1 - s), v * (1 - f * s), v * (1 - (1 - f) * s)
  local r, g, b = ({ { v, t, p }, { q, v, p }, { p, v, t }, { p, q, v }, { t, p, v }, { v, p, q } })[i + 1][1],
                  ({ { v, t, p }, { q, v, p }, { p, v, t }, { p, q, v }, { t, p, v }, { v, p, q } })[i + 1][2],
                  ({ { v, t, p }, { q, v, p }, { p, v, t }, { p, q, v }, { t, p, v }, { v, p, q } })[i + 1][3]
  return r, g, b
end
local function rgb2hsv(r, g, b)
  local mx, mn = math.max(r, g, b), math.min(r, g, b)
  local d, h = mx - mn, 0
  if d > 0 then
    if mx == r then h = ((g - b) / d) % 6 elseif mx == g then h = (b - r) / d + 2 else h = (r - g) / d + 4 end
    h = h / 6
  end
  return h, mx > 0 and d / mx or 0, mx
end

U.line_col = line_col
U.names_text = names_text
U.names_of = names_of
U.pin_spans = pin_spans
U.stmt_of = stmt_of
U.name_for = name_for
U.PALETTE = PALETTE
U.near_curve = near_curve
U.exec_path = exec_path
U.near_path = near_path
U.frame_of = frame_of
U.line_start = line_start
U.next_line = next_line
U.rest_blank = rest_blank
U.indent_at = indent_at
U.dedent = dedent
U.reindent = reindent
U.float_text = float_text
U.float_span = float_span
U.frame_of_node = frame_of_node
U.move_tree = move_tree
U.move_node = move_node
U.movable = movable
U.drag_roots = drag_roots
U.num_text = num_text
U.draggable = draggable
U.slider_value = slider_value
U.dragged_number = dragged_number
U.hsv2rgb = hsv2rgb
U.rgb2hsv = rgb2hsv
return U
