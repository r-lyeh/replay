-- draw.lua - NodeGraphView: drawing (part of the nodegraph plugin, ours).
-- Blender-like nodes and wires at the view's zoom; widgets and popups.
local core = require "core"
local common = require "core.common"
local command = require "core.command"
local keymap = require "core.keymap"
local style = require "core.style"
local DocView = require "core.docview"
local luaparse = require "plugins.nodegraph.luaparse"
local graph = require "plugins.nodegraph.graph"
local resolve = require "plugins.nodegraph.resolve"
local NodeGraphView = require "plugins.nodegraph.class"
local T = require "plugins.nodegraph.theme"
local U = require "plugins.nodegraph.util"
local rgb, C, HEAD, SOCK, GLOBAL, VALUE = T.rgb, T.C, T.HEAD, T.SOCK, T.GLOBAL, T.VALUE
local EXEC, sock_color, pin_color, kind_color, alpha = T.EXEC, T.sock_color, T.pin_color, T.kind_color, T.alpha
local line_col, names_text, names_of, pin_spans, stmt_of, name_for = U.line_col, U.names_text, U.names_of, U.pin_spans, U.stmt_of, U.name_for
local PALETTE, near_curve, frame_of, line_start, next_line, rest_blank = U.PALETTE, U.near_curve, U.frame_of, U.line_start, U.next_line, U.rest_blank
local indent_at, dedent, reindent, float_text, float_span, frame_of_node = U.indent_at, U.dedent, U.reindent, U.float_text, U.float_span, U.frame_of_node
local move_tree, movable, drag_roots, num_text, draggable, slider_value = U.move_tree, U.movable, U.drag_roots, U.num_text, U.draggable, U.slider_value
local dragged_number, hsv2rgb, rgb2hsv = U.dragged_number, U.hsv2rgb, U.rgb2hsv

function NodeGraphView:socket_xy(n, side, i, ox, oy)
  local z = self.zoom
  if n.proxy then                                  -- inside a folded function: on its header's edge
    local h = n.proxy
    return ox + (h.x + (side == "in" and 0 or h.w)) * z, oy + (h.y + h.head_h / 2) * z
  end
  local sk = side == "in" and n.ins[i] or n.outs[i]
  return ox + (n.x + (side == "in" and 0 or n.w)) * z, oy + (n.y + sk.y) * z
end

local B = require "plugins.nodegraph.breaks"
local BREAK, STOPPED = rgb"#e0464e", rgb"#ffd040"   -- a breakpoint's dot; where the world stopped
local PULSE = T.PULSE                              -- the flow that ran (the probe): orange (config.lua: flow)
local Z, zz = SCALE, 1                             -- set by draw() for the functions below
local F, CF                                        -- the fonts at that zoom

-- the shapes are the canvas's (plugins/canvas/draw.lua: shared with every
-- plugin's editor); here widths are at the zoom (Z)
local CD = require "plugins.canvas.draw"
local CPICK = require "plugins.canvas.picker"
local TIP = require "plugins.canvas.tip"
local function line(x1, y1, x2, y2, color, w) CD.line(x1, y1, x2, y2, color, (w or 1.5) * Z) end
local dot, rrect = CD.disc, CD.rrect
local function bezier(x1, y1, c1x, c1y, c2x, c2y, x2, y2, color, w)
  CD.bezier(x1, y1, c1x, c1y, c2x, c2y, x2, y2, color, (w or 1.5) * Z, zz < T.cfg.far_zoom and 6 or 24)   -- far out: 6 segments at most
end

-- a wire, out (right) -> in (left), like Blender's: a dark outline, a coloured core
local function wire(x1, y1, x2, y2, color, hot, w)
  local d = math.max(math.abs(x2 - x1) * 0.5, 40 * Z)
  if hot then bezier(x1, y1, x1 + d, y1, x2 - d, y2, x2, y2, alpha(C.outline, 220), 4.5) end
  bezier(x1, y1, x1 + d, y1, x2 - d, y2, x2, y2, color, w or (hot and 2.2 or 1.2))
end

-- flow beads (experimental, easy to drop: delete this block and its one call
-- in draw_exec). A few dots slide out -> in along a wire that ran, timed by
-- the editor clock (not the game's), stepped at 30 Hz so lite repaints nothing
-- in between. Going back in time (the timeline dragged left, rewound) they
-- slide backwards, in to out (bead_dir, set by draw() from the view).
local BEADS, BEAD_SPEED = 3, 0.8                   -- dots per wire, wire lengths per second
local bead_phase, bead_tick = 0, nil
local anim_live = false                            -- beads / fading flow drawn: redraw on the next 30 Hz tick (not every frame)
function NodeGraphView.anim_due()                  -- (update(): time for the next step of what moves?)
  return anim_live and math.floor(system.get_time() * 30) ~= bead_tick
end
local function bead_step(dir)                      -- once a draw: the phase moves on, 30 steps a second
  local tick = math.floor(system.get_time() * 30)
  if bead_tick and tick > bead_tick then bead_phase = (bead_phase + (tick - bead_tick) / 30 * BEAD_SPEED * dir) % 1 end
  bead_tick = tick
end
local function beads(x1, y1, x2, y2)
  local d = math.max(math.abs(x2 - x1) * 0.5, 40 * Z)
  local c1x, c2x = x1 + d, x2 - d
  local phase = bead_phase
  for k = 0, BEADS - 1 do
    local t = (phase + k / BEADS) % 1
    local u = 1 - t
    local bx = u * u * u * x1 + 3 * u * u * t * c1x + 3 * u * t * t * c2x + t * t * t * x2
    local by = u * u * (u + 3 * t) * y1 + t * t * (3 * u + t) * y2   -- (controls at y1, y2)
    dot(bx, by, math.max(4, 7 * Z), C.outline)
    dot(bx, by, math.max(2.5, 4.5 * Z), { 255, 255, 255, 255 })
  end
  anim_live = true
end

local function socket(x, y, color, hot) CD.socket(x, y, 11 * Z, color, hot, C.outline, C.active) end

local function arrow(x, y, dx, dy, c)              -- an arrow head at x, y pointing along (dx, dy)
  local s = 5 * Z
  line(x - dx * s - dy * s * 0.8, y - dy * s + dx * s * 0.8, x, y, c)
  line(x - dx * s + dy * s * 0.8, y - dy * s - dx * s * 0.8, x, y, c)
end

function NodeGraphView:draw_grid()
  local px, py, sw, sh = self.position.x, self.position.y, self.size.x, self.size.y
  local step = 24 * Z
  while step < 8 do step = step * 5 end            -- zoomed far out: fewer lines
  local ox, oy = self:origin()
  local t = math.max(1, SCALE)
  local i0 = math.floor((px - ox) / step)
  for i = i0, i0 + math.ceil(sw / step) + 1 do
    renderer.draw_rect(ox + i * step, py, t, sh, lite_bg(i % 5 == 0 and C.grid2 or C.grid))
  end
  local j0 = math.floor((py - oy) / step)
  for j = j0, j0 + math.ceil(sh / step) + 1 do
    renderer.draw_rect(px, oy + j * step, sw, t, lite_bg(j % 5 == 0 and C.grid2 or C.grid))
  end
end

-- control flow: right of the header -> left of the next header (left to
-- right), or down from the bottom (a branch's next row, a loop's body)
-- the flow (UE style): white wires from an out pin (right) to an in pin (left)
function NodeGraphView:exec_xy(n, side, k, ox, oy)
  if n.proxy then                                  -- inside a folded function: on its header's edge
    local h = n.proxy
    return ox + (h.x + (side == "in" and 0 or h.w)) * zz, oy + (h.y + h.head_h / 2) * zz
  end
  local p = side == "in" and n.xin or n.xouts[k]
  return ox + (n.x + (side == "in" and 0 or n.w)) * zz, oy + (n.y + p.y) * zz
end

local function exec_pin(x, y, filled, hot)          -- a triangle pointing right
  local s = (hot and 6.5 or 5.5) * Z
  local xl = x - 0.7 * s
  if filled then
    for dy = -math.floor(s), math.floor(s) do
      local f = 1 - math.abs(dy) / s
      renderer.draw_rect(math.floor(xl + 0.5), math.floor(y + dy + 0.5), math.max(1, math.floor(1.7 * s * f + 0.5)), 1, EXEC)
    end
  else
    line(xl, y - s, x + s, y, EXEC, 1.3); line(x + s, y, xl, y + s, EXEC, 1.3); line(xl, y + s, xl, y - s, EXEC, 1.3)
  end
end

function NodeGraphView:draw_exec(e, ox, oy)
  local hot = self.hl and self.hl.execs[e]        -- (hovered: drawn bright, thicker)
  local a, b = self.by_id[e.from], self.by_id[e.to]
  if e.jump and b.xin then                         -- a goto: a faint wire to its label (no pin of its own)
    local x2, y2 = self:exec_xy(b, "in", 1, ox, oy)
    wire(ox + (a.x + a.w) * zz, oy + (a.y + a.head_h / 2) * zz, x2, y2, alpha(EXEC, 90), false, 1.5)
    return
  end
  if not (a.xouts[e.out] and b.xin) then return end
  local x1, y1 = self:exec_xy(a, "out", e.out, ox, oy)
  local x2, y2 = self:exec_xy(b, "in", 1, ox, oy)
  local fc = self:flow_color(e, b)                 -- (ran: orange, fading back to white once it doesn't)
  if e.wrap and x2 < x1 then                       -- to the next row: a snake back to the left
    local c = fc or alpha(EXEC, 230)
    for _, k in ipairs(U.exec_path(x1, y1, x2, y2, self:wrap_y(b, oy), Z)) do
      if hot then bezier(k[1], k[2], k[3], k[4], k[5], k[6], k[7], k[8], alpha(C.active, 160), 5) end
      bezier(k[1], k[2], k[3], k[4], k[5], k[6], k[7], k[8], c, 2.2)
    end
    return
  end
  if hot then wire(x1, y1, x2, y2, alpha(C.active, 160), false, 5) end
  wire(x1, y1, x2, y2, fc or alpha(EXEC, e.back and 110 or 230), false, e.back and 1.5 or 2.2)
  if fc == PULSE then beads(x1, y1, x2, y2) end    -- (experimental: flow beads)
end

-- a flow wire's colour from the probe: orange while its target ran in the
-- frame shown; once it doesn't, it blends back to white over flow_fade s (config.lua)
function NodeGraphView:flow_color(e, b)
  if e.back then return nil end
  local now = system.get_time()
  self.flow_heat = self.flow_heat or setmetatable({}, { __mode = "k" })
  if self:ran(b) then self.flow_heat[e] = now; return PULSE end
  local t = self.flow_heat[e]
  if not t then return nil end
  local f = (now - t) / T.cfg.flow_fade
  if f >= 1 then self.flow_heat[e] = nil; return nil end
  anim_live = true                                 -- (still fading: again at the next 30 Hz tick)
  local w = EXEC
  return { PULSE[1] + (w[1] - PULSE[1]) * f, PULSE[2] + (w[2] - PULSE[2]) * f, PULSE[3] + (w[3] - PULSE[3]) * f, 230 + 25 * (1 - f) }
end

-- where a wrapped flow wire runs back left: in the gap above the row it enters
function NodeGraphView:wrap_y(b, oy)
  return oy + (b.y - 26) * self.zoom
end

-- a chip: a variable's name in a pill (UE's "get" node); lit = that variable
-- is hovered / clicked. Leaves a hit rect (hover lights it, drag rewires).
function NodeGraphView:draw_chip(cx, sy, label, sk, n, side, i, lit)
  local fh = F:get_height()
  local cw, ch = F:get_width(label) + 12 * Z, fh + 2 * Z
  local col = pin_color(sk)
  local t = math.max(1, Z)
  rrect(cx, sy - ch / 2, cw, ch, ch / 2, lit and C.active or col)
  rrect(cx + t, sy - ch / 2 + t, cw - 2 * t, ch - 2 * t, ch / 2 - t, lit and alpha(col, 255) or rgb"#262630")
  renderer.draw_text(F, label, cx + 6 * Z, sy - fh / 2, lit and C.outline or C.text)
  self.hits[#self.hits + 1] = { kind = "chip", x = cx, y = sy - ch / 2, w = cw, h = ch, node = n, pin = sk,
                                side = side, i = i, decl = sk.decl }
  return cw
end

function NodeGraphView:draw_node(n, ox, oy)
  local x, y, w, h = ox + n.x * zz, oy + n.y * zz, n.w * zz, n.h * zz
  local r = 5 * Z
  local sel = self.selected == n or (self.sel and self.sel[n])
  local act, hot = sel and self.nsel <= 1, self.hover == n   -- white: a lone selection; orange: several
  local a = n.alpha and math.floor(255 * math.max(0, math.min(1, n.alpha))) or 255
  if zz < T.cfg.far_zoom then                            -- far out (unreadable): plain boxes, no text, pins or shadow
    local rk
    for _, pin in ipairs(self.pins) do if pin.nodes and pin.nodes[n] then rk = rgb(pin.color or "#e5c07b") break end end
    local oc = (sel and (act and C.active or C.sel)) or rk or (hot and C.hover) or (n.has_error and C.err)
    if oc then renderer.draw_rect(x - 1, y - 1, w + 2, h + 2, oc) end
    renderer.draw_rect(x, y, w, h, alpha(C.body, a))
    renderer.draw_rect(x, y, w, math.max(1, n.head_h * zz),
                       alpha(n.color or (n.callee and HEAD.call) or (n.table and HEAD.table) or kind_color(n.kind), a))
    return
  end
  if a == 255 then rrect(x + 2 * Z, y + 3 * Z, w, h, r, C.shadow) end
  local rk, rc                                    -- pinned references: in its variable's colour
  for _, pin in ipairs(self.pins) do
    if pin.nodes and pin.nodes[n] then rk, rc = pin.nodes[n], rgb(pin.color or "#e5c07b") break end
  end
  if n == self.err_n then                          -- the syntax error is around here: a red halo, pulsing
    local k = 0.5 + 0.5 * math.sin(system.get_time() * 4)
    local t1, t2 = math.max(2, 3 * Z), (8 + 4 * k) * Z
    rrect(x - t2, y - t2, w + 2 * t2, h + 2 * t2, r + t2, alpha(C.err, math.floor(40 + 50 * k)))
    if not sel then rrect(x - t1, y - t1, w + 2 * t1, h + 2 * t1, r + t1, C.err) end   -- (selected: its own outline)
    anim_live = true
  end
  if rk and not sel then
    local t = math.max(1, (rk == "decl" and 3.5 or 2.5) * Z)   -- (the declaration: thicker)
    rrect(x - t, y - t, w + 2 * t, h + 2 * t, r + t, rc)
  elseif sel or hot then                           -- outline: a slightly bigger node behind
    local t = math.max(1, (sel and 2 or 1) * Z)
    rrect(x - t, y - t, w + 2 * t, h + 2 * t, r + t, act and C.active or sel and C.sel or C.hover)
  elseif n.has_error then                          -- errors: a red outline
    local t = math.max(1, 1.5 * Z)
    rrect(x - t, y - t, w + 2 * t, h + 2 * t, r + t, C.err)
  end
  rrect(x, y, w, h, r, alpha(C.body, a))
  local hh = n.head_h * zz
  local head = alpha(n.color or (n.callee and HEAD.call) or (n.table and HEAD.table) or kind_color(n.kind), a)
  rrect(x, y, w, hh, r, head, true)
  local pad = 10 * Z
  local fh = F:get_height()
  if zz < 0.4 then return end                      -- far out: boxes only
  -- the text is measured at the base size and drawn at the zoomed one, which
  -- isn't exactly proportional: keep what's inside the node inside it
  core.push_clip_rect(x, y, w, h)
  local socks, chips = {}, {}
  local cw = graph.CHEV * zz                       -- the chevron: fold / unfold (left of the title)
  if self:collapsible(n) then
    local cx, cy, s = x + pad - 2 * Z, y + hh / 2, 3.2 * Z
    local cc = self.hover_chev == n and C.active or alpha(C.text, 200)
    if n.collapsed then line(cx, cy - s, cx + s, cy, cc, 1.4); line(cx + s, cy, cx, cy + s, cc, 1.4)   -- >
    else line(cx - s * 0.2, cy - s * 0.5, cx + s * 0.8, cy + s * 0.5, cc, 1.4); line(cx + s * 0.8, cy + s * 0.5, cx + s * 1.8, cy - s * 0.5, cc, 1.4) end   -- v
  end
  renderer.draw_text(F, n.head_title or n.title, x + pad + cw, y + (hh - fh) / 2, C.text)   -- (compact: the longest title that fits)
  if n.collapsed then                              -- folded: its header only, its pins on its edges
    if n.xouts and n.xouts[1] and n.xouts[1].name ~= "" then
      local tw = F:get_width(n.xouts[1].name)
      renderer.draw_text(F, n.xouts[1].name, x + w - pad - tw, y + (hh - fh) / 2, C.text)
    end
    core.pop_clip_rect()
    for side, list in pairs({ ["in"] = n.ins, out = n.outs }) do
      for i, sk in ipairs(list) do
        if not sk.action and not (side == "out" and sk.silent and not sk.decl) then
          local sx, sy = self:socket_xy(n, side, i, ox, oy)
          socket(sx, sy, pin_color(sk), self.hover_sock == sk)
        end
      end
    end
    local conn = self.exec_conn or {}
    if n.xin then local ex, ey = self:exec_xy(n, "in", 1, ox, oy); exec_pin(ex, ey, conn[n] and conn[n].inn, false) end
    if n.xouts and n.xouts[1] then
      local ex, ey = self:exec_xy(n, "out", 1, ox, oy)
      local any = false
      for k in ipairs(n.xouts) do any = any or (conn[n] and conn[n][k]) end
      exec_pin(ex, ey, any, false)
    end
    return
  end
  for side, list in pairs({ ["in"] = n.ins, out = n.outs }) do  -- sockets and their labels
    for i, sk in ipairs(list) do
      local sx, sy = self:socket_xy(n, side, i, ox, oy)
      local tw = F:get_width(sk.name)
      if sk.action then                            -- "+ add field", "+ N more": a button row
        local hot = self.hover_action == sk
        renderer.draw_text(F, sk.name, x + pad, sy - fh / 2, hot and C.sel or alpha(C.blabel, 170))
        self.hits[#self.hits + 1] = { kind = "action", x = x + pad - 2 * Z, y = sy - fh / 2 - 2 * Z, w = tw + 4 * Z, h = fh + 4 * Z,
                                      node = n, pin = sk }
        goto next_pin
      end
      local tx = side == "in" and x + pad or x + w - pad - tw
      local wired = sk.decl or sk.value or sk.kind == "expr" or sk.field_path or sk.split_src
      local lit = sk.decl and (sk.decl == self.hover_decl or sk.decl == self.lit_decl)
      if side == "in" and sk.chip then             -- a chip: outside, left of the socket (drawn below, unclipped)
        chips[#chips + 1] = { sx, sy, sk, i, lit }
        if sk.chip ~= sk.name or sk.field then renderer.draw_text(F, sk.name, tx, sy - fh / 2, C.blabel) end   -- (the slot's name)
      elseif side == "out" and sk.chip and not sk.silent then
        self:draw_chip(tx - 6 * Z, sy, sk.name, sk, n, side, i, lit)   -- a parameter in its header: its label, as a chip
      elseif not sk.silent then
        local hl = self.hl and self.hl.socks[sk]  -- (a hovered pin, or one at the end of a hovered wire: its name lit)
        renderer.draw_text(F, sk.name, tx, sy - fh / 2, hl and C.active or (wired and not sk.unused and C.blabel or C.bdim))   -- (an unused local: dim)
      end
      if lit and sk.silent then                      -- (a silent declaration: a ring on its socket)
        dot(sx, sy, 15 * Z, C.active)
      end
      if side == "out" and sk.hint then            -- its annotated type, dim, before the name
        renderer.draw_text(F, sk.hint, tx - F:get_width(sk.hint) - 6 * Z, sy - fh / 2, C.bdim)
      end
      if side == "in" and sk.text then             -- a value typed in place: widgets
        self:draw_widget(n, sk, tx + tw + 6 * Z, sy)
      end
      socks[#socks + 1] = { sx, sy, pin_color(sk), self.hover_sock == sk or (self.hl and self.hl.socks[sk]) }   -- (drawn unclipped, on the edge)
      ::next_pin::
    end
  end
  for k, xo in ipairs(n.xouts or {}) do            -- named flow outs: then / else / body / done
    if xo.name ~= "" then
      local tw = F:get_width(xo.name)
      renderer.draw_text(F, xo.name, x + w - pad - tw, y + xo.y * zz - fh / 2, k == 1 and C.btext or C.blabel)
    end
  end
  if #n.lines > 0 then                             -- the code, in a field
    local fy = y + n.body_y * zz
    local lh = CF:get_height()
    local fx = x + (n.body_x or 6) * zz             -- (compact: right of the inputs' names)
    rrect(fx, fy, x + w - 6 * Z - fx, #n.lines * lh + 6 * Z, 3 * Z, alpha(C.field, a))
    local ty = fy + 3 * Z
    for _, l in ipairs(n.lines) do
      renderer.draw_text(CF, l, fx + 4 * Z, ty, C.code)
      ty = ty + lh
    end
  end
  if #n.diags > 0 then                             -- what will fail (red), what looks wrong (amber): a footer
    local dy = y + n.diag_y * zz
    local bg = n.has_error and C.errbg or C.warnbg
    rrect(x, dy, w, y + h - dy, r, alpha(bg, a))
    renderer.draw_rect(x, dy, w, r, alpha(bg, a))  -- square top corners
    local rh = (fh + 6 * Z)
    for i, d in ipairs(n.diags) do
      local ry = dy + 2 * Z + (i - 1) * rh
      local warn = d.level == "warning"
      dot(x + pad + 3 * Z, ry + rh / 2, 7 * Z, warn and C.warn or C.err)
      renderer.draw_text(F, d.msg, x + pad + 12 * Z, ry + 3 * Z, warn and C.warntext or C.errtext)
    end
  end
  core.pop_clip_rect()
  for _, c in ipairs(chips) do                     -- the chips left of their sockets, with a short stub
    local sx, sy, sk, i, lit = c[1], c[2], c[3], c[4], c[5]
    local cw = F:get_width(sk.chip) + 12 * Z
    local cx = sx - 10 * Z - cw
    renderer.draw_rect(cx + cw, sy - math.max(1, Z) / 2, 10 * Z, math.max(1, Z), lit and C.active or pin_color(sk))
    self:draw_chip(cx, sy, sk.chip, sk, n, "in", i, lit)
  end
  for _, k in ipairs(socks) do socket(k[1], k[2], k[3], k[4]) end
  local conn = self.exec_conn or {}
  if n.xin then
    local ex, ey = self:exec_xy(n, "in", 1, ox, oy)
    exec_pin(ex, ey, conn[n] and conn[n].inn, self.hover_sock == n.xin or (self.hl and self.hl.socks[n.xin]))
  end
  for k, xo in ipairs(n.xouts or {}) do
    local ex, ey = self:exec_xy(n, "out", k, ox, oy)
    exec_pin(ex, ey, conn[n] and conn[n][k], self.hover_sock == xo or (self.hl and self.hl.socks[xo]))
  end
end

-- widgets for values written in place (a pin's literal, a table's fields):
--   boolean: a checkbox (click toggles)     number: a field (drag sideways)
--   string / other: a field (double-click edits)
--   vector {x=, y=}: a number field per part; colour {r, g, b}: a swatch + parts
-- Each one leaves a hit rect in self.hits for the mouse (this frame's).
function NodeGraphView:draw_widget(n, sk, bx, sy)
  local fh, bh = CF:get_height(), CF:get_height() + 2 * Z
  local by = sy - bh / 2
  local hits = self.hits
  if sk.lit == "boolean" then                      -- a checkbox
    local on = (num_text(sk.text, self.preview, sk.pos)) == "true"
    local b = bh - 2 * Z
    local top = by + Z
    rrect(bx, top, b, b, 3 * Z, C.field)
    if on then                                     -- a tick (the strings' green): a short arm down, a long one up
      local x1, y1 = bx + 0.24 * b, top + 0.52 * b
      local x2, y2 = bx + 0.43 * b, top + 0.72 * b
      local x3, y3 = bx + 0.78 * b, top + 0.30 * b
      line(x1, y1, x2, y2, C.str, 2)
      line(x2, y2, x3, y3, C.str, 2)
      dot(x2, y2, math.max(1, 2 * Z), C.str)       -- (a round elbow)
    end
    hits[#hits + 1] = { kind = "bool", x = bx, y = by, w = b, h = bh, node = n, pin = sk,
                        pos = sk.pos, epos = sk.epos, text = on and "true" or "false" }
    return
  end
  if sk.comps then                                 -- a vector / a colour: a field per part
    local x = bx
    if sk.kind == "color" then
      local v = {}
      local unit = true
      for k, c in ipairs(sk.comps) do
        v[k] = tonumber(num_text(c.text, self.preview, c.pos)) or 0
        if v[k] > 1 then unit = false end
      end
      local sc = unit and 255 or 1
      local col = { math.floor(math.max(0, math.min(255, v[1] * sc))), math.floor(math.max(0, math.min(255, v[2] * sc))),
                    math.floor(math.max(0, math.min(255, v[3] * sc))), 255 }
      rrect(x, by, bh * 1.6, bh, 3 * Z, C.outline)
      rrect(x + Z, by + Z, bh * 1.6 - 2 * Z, bh - 2 * Z, 3 * Z, col)
      if #sk.comps >= 3 then
        hits[#hits + 1] = { kind = "swatch", x = x, y = by, w = bh * 1.6, h = bh, node = n, pin = sk, unit = unit,
                            rgb = { v[1] * sc, v[2] * sc, v[3] * sc } }
      end
      x = x + bh * 1.6 + 6 * Z
    end
    for _, c in ipairs(sk.comps) do
      local t = num_text(c.text, self.preview, c.pos)
      renderer.draw_text(CF, c.label or "", x, sy - fh / 2, C.bdim)
      x = x + CF:get_width(c.label or "") + 3 * Z
      local w = CF:get_width(t) + 10 * Z
      rrect(x, by, w, bh, 3 * Z, (self.preview and self.preview[c.pos]) and C.frame or C.field)
      renderer.draw_text(CF, t, x + 5 * Z, sy - fh / 2, C.code)
      if draggable(c.text) then
        hits[#hits + 1] = { kind = "num", x = x, y = by, w = w, h = bh, node = n, pin = sk, pos = c.pos, epos = c.epos, text = c.text }
      end
      x = x + w + 6 * Z
    end
    return
  end
  local hint = sk.hint
  if hint and hint.range and sk.lit == "number" and draggable(sk.text) then   -- --@range: a slider
    local a, b = hint.range[1], hint.range[2]
    local t = num_text(sk.text, self.preview, sk.pos)
    local v = tonumber(t) or a
    local w = math.max(110 * Z, CF:get_width(t) + 20 * Z)
    local f = b > a and math.max(0, math.min(1, (v - a) / (b - a))) or 0
    rrect(bx, by, w, bh, 3 * Z, C.field)
    if f > 0 then rrect(bx, by, math.max(6 * Z, w * f), bh, 3 * Z, rgb"#4772b3") end
    renderer.draw_text(CF, t, bx + (w - CF:get_width(t)) / 2, sy - fh / 2, C.text)
    hits[#hits + 1] = { kind = "slider", x = bx, y = by, w = w, h = bh, node = n, pin = sk, pos = sk.pos, epos = sk.epos,
                        text = sk.text, range = hint.range }
    return
  end
  if hint and hint.enum and sk.lit == "string" then  -- --@enum: a drop-down
    local t = sk.text
    local w = CF:get_width(t) + 24 * Z
    rrect(bx, by, w, bh, 3 * Z, C.field)
    renderer.draw_text(CF, t, bx + 5 * Z, sy - fh / 2, rgb"#c3e88d")
    local ax, ay = bx + w - 9 * Z, sy                -- a small down arrow
    line(ax - 3 * Z, ay - 2 * Z, ax, ay + 2 * Z, C.dim); line(ax, ay + 2 * Z, ax + 3 * Z, ay - 2 * Z, C.dim)
    hits[#hits + 1] = { kind = "enum", x = bx, y = by, w = w, h = bh, node = n, pin = sk, pos = sk.pos, epos = sk.epos,
                        text = sk.text, enum = hint.enum }
    return
  end
  local t = num_text(sk.text, self.preview, sk.pos)
  local w = CF:get_width(t) + 10 * Z
  local num = sk.lit == "number" and draggable(sk.text)
  local bg = (self.preview and self.preview[sk.pos]) and C.frame or C.field
  local col = sk.kind ~= "literal" and C.dim or sk.lit == "nil" and C.err or sk.lit == "string" and C.str
              or sk.lit == "number" and rgb"#f78c6c" or C.code
  local hex = sk.lit == "string" and t:match("^[\"']#(%x+)[\"']$")
  local cr, cg, cb, ca                              -- "#rgb", "#rgba", "#rrggbb", "#rrggbbaa": a colour
  if hex and (#hex == 3 or #hex == 4) then
    cr, cg, cb = tonumber(hex:sub(1, 1), 16) * 17, tonumber(hex:sub(2, 2), 16) * 17, tonumber(hex:sub(3, 3), 16) * 17
    ca = #hex == 4 and tonumber(hex:sub(4, 4), 16) * 17 or 255
  elseif hex and (#hex == 6 or #hex == 8) then
    cr, cg, cb = tonumber(hex:sub(1, 2), 16), tonumber(hex:sub(3, 4), 16), tonumber(hex:sub(5, 6), 16)
    ca = #hex == 8 and tonumber(hex:sub(7, 8), 16) or 255
  end
  if cr then                                       -- its box shows it (over the field, as alpha blends);
    local a = ca / 255                             -- the text black or white, after how light that is
    local base = C.field
    local r, g, b2 = cr * a + base[1] * (1 - a), cg * a + base[2] * (1 - a), cb * a + base[3] * (1 - a)
    bg = { r, g, b2, 255 }
    col = (0.299 * r + 0.587 * g + 0.114 * b2) > 140 and rgb"#141414" or rgb"#f0f0f0"
    if sk.kind == "literal" then                   -- a click: the colour picker (a double-click still edits the text)
      hits[#hits + 1] = { kind = "swatch", x = bx, y = by, w = w, h = bh, node = n, pin = sk, hexstr = t:sub(1, 1),
                          comps = { { pos = sk.pos, epos = sk.epos, text = sk.text } }, rgb = { cr, cg, cb },
                          alpha = (#hex == 4 or #hex == 8) and ca / 255 or nil }
    end
  end
  rrect(bx, by, w, bh, 3 * Z, bg)
  renderer.draw_text(CF, t, bx + 5 * Z, sy - fh / 2, col)
  if num then                                      -- (the cursor turns into a sideways arrow over it)
    hits[#hits + 1] = { kind = "num", x = bx, y = by, w = w, h = bh, node = n, pin = sk, pos = sk.pos, epos = sk.epos, text = sk.text }
  end
end

function NodeGraphView:draw_picker()             -- (the shared picker: plugins/canvas/picker.lua; the hex row typed: our text field)
  if not self.picker then return end
  CPICK.draw_parts(self.picker, { hex_typing = self.editing and self.editing.hex })
end

-- comment boxes: a dashed, tinted box with a headline; drag the headline to
-- move it with the nodes inside, double-click it to rename, RMB to delete
local function nlines(s) local n = 1 for _ in (s or ""):gmatch("\n") do n = n + 1 end return n end
function NodeGraphView:note_rect(nt, ox, oy)       -- (its headline: as tall as its title's lines; the one being typed, too)
  local e = self.editing
  local lines = nlines(e and e.note == nt and e.text or nt.title)
  local hh = lines * F:get_height() + 8 * Z
  return ox + nt.x * zz, oy + nt.y * zz, nt.w * zz, math.max(nt.h * zz, hh), hh
end
function NodeGraphView:draw_notes(ox, oy)
  self.note_hits = {}
  for _, nt in ipairs(self.g.notes or {}) do
    if nt.hidden then goto next_note end
    local bx, by, bw, bh, hh = self:note_rect(nt, ox, oy)
    local c = nt.tag.vals.color and rgb(nt.tag.vals.color) or rgb"#a0a0a0"   -- (default: gray)
    rrect(bx, by, bw, bh, 6 * Z, alpha(c, 22))
    rrect(bx, by, bw, hh, 6 * Z, alpha(c, 40), true)
    local t = math.max(1, SCALE)
    local dash, gap = 6 * Z, 12 * Z
    for dx = 0, bw - dash, gap do
      renderer.draw_rect(bx + dx, by, dash, t, alpha(c, 140)); renderer.draw_rect(bx + dx, by + bh - t, dash, t, alpha(c, 140))
    end
    for dy = 0, bh - dash, gap do
      renderer.draw_rect(bx, by + dy, t, dash, alpha(c, 140)); renderer.draw_rect(bx + bw - t, by + dy, t, dash, alpha(c, 140))
    end
    local editing = self.editing and self.editing.note == nt
    local cw = graph.CHEV * zz                     -- the chevron: fold / unfold, left of the title
    if zz >= 0.3 then
      local cx, cy, s = bx + 8 * Z, by + hh / 2, 3.2 * Z
      local cc = self.hover_note_chev == nt and C.active or alpha(c, 230)
      if nt.collapsed then line(cx, cy - s, cx + s, cy, cc, 1.4); line(cx + s, cy, cx, cy + s, cc, 1.4)   -- >
      else line(cx - s * 0.2, cy - s * 0.5, cx + s * 0.8, cy + s * 0.5, cc, 1.4); line(cx + s * 0.8, cy + s * 0.5, cx + s * 1.8, cy - s * 0.5, cc, 1.4) end   -- v
    end
    if zz >= 0.3 and not editing then
      local title = nt.title ~= "" and nt.title or (nt.collapsed and "comment" or "comment (double-click to name it)")
      core.push_clip_rect(bx, by, bw, hh)
      local ly = by + 4 * Z
      for ln in (title .. "\n"):gmatch("(.-)\n") do
        renderer.draw_text(F, ln, bx + 8 * Z + cw, ly, nt.title ~= "" and alpha(c, 230) or alpha(c, 120))
        ly = ly + F:get_height()
      end
      core.pop_clip_rect()
    end
    self.note_hits[#self.note_hits + 1] = { note = nt, x = bx, y = by, w = bw, h = hh, bh = bh, chev_w = 8 * Z + cw }
    if not nt.collapsed then                       -- its corner grip (drag an edge or a corner: resize)
      local n, st = 5, 2 * Z                       -- a small stair triangle in the corner
      for i = 0, n - 1 do
        renderer.draw_rect(bx + bw - (i + 1) * st - t, by + bh - (n - i) * st - t, st, (n - i) * st, alpha(c, 150))
      end
    end
    ::next_note::
  end
end

function NodeGraphView:draw_menu()                 -- (plugins/canvas/menu.lua: the shared menus)
  require("plugins.canvas.menu").draw(self.menu, self.mx, self.my)
end

-- the edit box, over the row being edited
function NodeGraphView:draw_edit(ox, oy)
  local e = self.editing
  self.edit_box = nil
  if not e then return end
  if e.note then                                   -- a comment box's headline
    local ox, oy = self:origin()
    local bx, by, bw, _, hh = self:note_rect(e.note, ox, oy)
    renderer.draw_rect(bx + 3 * Z - 1, by + 2 * Z - 1, bw - 6 * Z + 2, hh - 4 * Z + 2, C.active)
    renderer.draw_rect(bx + 3 * Z, by + 2 * Z, bw - 6 * Z, hh - 4 * Z, C.field)
    local tx = bx + 8 * Z
    require("plugins.canvas.field").draw(e, F, tx, by + 4 * Z, C.text, C.active)   -- (its lines, the caret: canvas.field)
    self.edit_box = { x = tx, y = by, w = bw, h = hh, font = F }
    return
  end
  if e.hex then                                    -- the picker's hex row
    if not self.picker then self.editing = nil; return end
    local _, _, _, _, hex = self:picker_rects()
    local cf = style.code_font
    renderer.draw_rect(hex.x - 1, hex.y - 1, hex.w + 2, hex.h + 2, e.err and C.err or C.active)
    renderer.draw_rect(hex.x, hex.y, hex.w, hex.h, C.field)
    local tx = hex.x + 6 * SCALE
    require("plugins.canvas.field").draw(e, cf, tx, hex.y + (hex.h - cf:get_height()) / 2, C.text, C.active)   -- (lite's selection, its caret)
    self.edit_box = { x = tx, y = hex.y, w = hex.w, h = hex.h }
    if e.err then renderer.draw_text(style.font, e.err, hex.x, hex.y + hex.h + 3 * SCALE, C.err) end
    return
  end
  local n = e.node
  local pad = 8 * Z
  local h = CF:get_height() + 4 * Z
  local y = oy + n.y * zz + (n.head_h * zz - h) / 2
  if e.which == "body" then y = oy + (n.y + n.body_y) * zz + 1 * Z end
  local x = ox + n.x * zz + pad - 3 * Z
  if e.which == "body" and n.body_x then x = ox + (n.x + n.body_x) * zz + 1 * Z end
  local si = tonumber(e.which:match("^slot(%d+)$") or "")
  if si and n.ins[si] then                         -- an input's row: right of its name
    y = oy + (n.y + n.ins[si].y) * zz - h / 2
    x = ox + n.x * zz + 10 * Z + F:get_width(n.ins[si].name) + 4 * Z
  end
  local ni = tonumber(e.which:match("^name(%d+)$") or e.which:match("^key(%d+)$") or e.which:match("^var(%d+)$") or "")
  if ni and n.ins[ni] then                         -- a return value's / a field's name: over the label
    y = oy + (n.y + n.ins[ni].y) * zz - h / 2
    x = ox + n.x * zz + 7 * Z
  end
  local w = math.max(n.w * zz - 2 * pad + 6 * Z, CF:get_width(e.text) + 16 * Z)
  local t = math.max(1, SCALE)
  if e.which == "body" then                        -- hide the old (wrapped) text under the box
    renderer.draw_rect(ox + n.x * zz + 6 * Z, y, n.w * zz - 12 * Z, oy + (n.y + n.h) * zz - 6 * Z - y, C.field)
  end
  renderer.draw_rect(x - t, y - t, w + 2 * t, h + 2 * t, e.err and C.err or C.active)
  renderer.draw_rect(x, y, w, h, C.field)
  local tx = x + 3 * Z
  require("plugins.canvas.field").draw(e, CF, tx, y + 2 * Z, C.text, C.active)   -- (lite's selection, its caret: canvas.field)
  self.edit_box = { x = tx, y = y, w = w, h = h }
  if e.err then renderer.draw_text(F, e.err, x, y + h + 3 * Z, C.err) end
end

function NodeGraphView:draw()
  self:draw_background(C.bg)
  zz = self.zoom
  Z = SCALE * zz
  F, CF = self:fonts()
  self.hits = {}
  local px, py, sw, sh = self.position.x, self.position.y, self.size.x, self.size.y
  CD.set_view(px, py, sw, sh)
  core.push_clip_rect(px, py, sw, sh)
  self:draw_grid()
  local ox, oy = self:origin()
  local g = self.g
  self.err_n = self:err_node()                     -- (a syntax error: the node closest to it, haloed)
  local back = self.flow_back_at and system.get_time() - self.flow_back_at < 0.5   -- (just went back in time)
  bead_step(back and -1 or 1)
  anim_live = false
  if g and #self.pins > 0 then                     -- pinned references: a crosshair through each, in its colour
    local t = math.max(1, math.floor(1.5 * SCALE + 0.5))
    for _, pin in ipairs(self.pins) do
      local pc = rgb(pin.color or "#e5c07b")
      for n, k in pairs(pin.nodes or {}) do
        if not n.hidden then
          local cx = math.floor(ox + (n.x + n.w / 2) * zz)
          local cy = math.floor(oy + (n.y + n.h / 2) * zz)
          local c = alpha(pc, k == "decl" and 170 or 95)
          renderer.draw_rect(px, cy - t / 2, sw, t, c)
          renderer.draw_rect(cx - t / 2, py, t, sh, c)
        end
      end
    end
  end
  if g then
    for _, f in ipairs(g.frames) do                -- functions: a frame each (Blender's frame node)
      if f.hidden then goto next_frame end
      local c = f.color and alpha(f.color, math.floor(70 * (f.alpha or 1))) or alpha(C.framebg, math.floor(150 * (f.alpha or 1)))
      rrect(ox + f.x * zz, oy + f.y * zz, f.w * zz, f.h * zz, 6 * Z, c)
      ::next_frame::
    end
    self:draw_notes(ox, oy)                        -- comment boxes, behind everything
    for _, e in ipairs(g.exec) do                  -- on screen only
      local a, b = self.by_id[e.from], self.by_id[e.to]
      if self:shown(a) == self:shown(b) then goto next_exec end   -- (inside one folded function)
      a, b = self:shown(a), self:shown(b)
      local x1, x2 = ox + math.min(a.x, b.x) * zz - 20, ox + math.max(a.x + a.w, b.x + b.w) * zz + 20
      local y1, y2 = oy + math.min(a.y, b.y) * zz - 20, oy + math.max(a.y + a.h, b.y + b.h) * zz + 20
      if x2 >= px and x1 <= px + sw and y2 >= py and y1 <= py + sh then self:draw_exec(e, ox, oy) end
      ::next_exec::
    end
    for _, d in ipairs(g.data) do                  -- a statement -> the functions it holds (under it)
      local a, b = self.by_id[d.from], self.by_id[d.to]
      if a.hidden or b.hidden then goto next_data end
      local sx, sy = ox + (a.x + 30) * zz, oy + (a.y + a.h) * zz
      local tx, ty = ox + b.x * zz, oy + (b.y + b.head_h / 2) * zz
      local c = alpha(SOCK["function"], 170)
      if tx > sx + 8 * Z then bezier(sx, sy, sx, ty, sx, ty, tx, ty, c, 1.5)
      else wire(sx, sy, tx, ty, c, false, 1.5) end
      ::next_data::
    end
    local focus = self.hover or self.selected
    local lit = self.hover_decl or self.lit_decl     -- a chip hovered / clicked: that variable's wires show
    for pass = 1, 2 do                             -- variables: dim first, the focused node's on top
      for _, l in ipairs(g.links) do
        local a, b = self.by_id[l.from], self.by_id[l.to]
        local hov = self.hl and self.hl.links[l]   -- (hovered: it, or a pin at its end)
        local hot = (focus and (a == focus or b == focus)) or hov
        local shown = not l.chip or (lit and a.outs[l.out].decl == lit) or hov   -- (chips: no wires, unless lit / hovered)
        if self:shown(a) == self:shown(b) and (a.proxy or b.proxy) then shown = false end   -- (inside one folded function)
        if l.chip and shown then hot = true end
        if shown and (pass == 2) == (hot and true or false) then
          local x1, y1 = self:socket_xy(a, "out", l.out, ox, oy)
          local x2, y2 = self:socket_xy(b, "in", l.inp, ox, oy)
          local d = math.max(math.abs(x2 - x1) * 0.5, 40 * Z)
          if math.max(x1 + d, x2) >= px and math.min(x1, x2 - d) <= px + sw
             and math.max(y1, y2) >= py and math.min(y1, y2) <= py + sh then   -- on screen only
            local c = pin_color(a.outs[l.out])
            if hov then wire(x1, y1, x2, y2, alpha(C.active, 150), false, 5.5) end
            if l.pending then                      -- (wired in the text, not yet in the flow: dashed)
              local steps, px0, py0 = 24, x1, y1
              local cc = alpha(c, hot and 255 or 170)
              for s = 1, steps do
                local t = s / steps
                local u = 1 - t
                local cx = u * u * u * x1 + 3 * u * u * t * (x1 + d) + 3 * u * t * t * (x2 - d) + t * t * t * x2
                local cy = u * u * (u + 3 * t) * y1 + t * t * (3 * u + t) * y2
                if s % 2 == 1 then renderer.draw_line(px0, py0, cx, cy, math.max(1, (hot and 2.2 or 1.5) * Z), cc) end
                px0, py0 = cx, cy
              end
            else
              wire(x1, y1, x2, y2, alpha(c, hot and 255 or (l.expr and 150 or 55)), hot)
            end
          end
        end
      end
    end
    if self.probe and zz >= 0.55 then              -- values on wires (the frame shown): a small tag mid-wire
      local lh = CF:get_height()
      for _, l in ipairs(g.links) do
        local a, b = self.by_id[l.from], self.by_id[l.to]
        if not l.chip and not a.hidden and not b.hidden then
          local v = self:link_value(l)
          if v then
            local x1, y1 = self:socket_xy(a, "out", l.out, ox, oy)
            local x2, y2 = self:socket_xy(b, "in", l.inp, ox, oy)
            local mx, my = (x1 + x2) / 2, (y1 + y2) / 2
            if mx >= px - 100 and mx <= px + sw + 100 and my >= py - 20 and my <= py + sh + 20 then
              if #v > 18 then v = v:sub(1, 16) .. ".." end
              local tw = CF:get_width(v) + 8 * Z
              rrect(mx - tw / 2, my - lh / 2 - 2 * Z, tw, lh + 4 * Z, 3 * Z, alpha(rgb"#16161a", 225))
              renderer.draw_text(CF, v, mx - tw / 2 + 4 * Z, my - lh / 2, alpha(pin_color(a.outs[l.out]), 255))
            end
          end
        end
      end
    end
    self.nsel = 0
    for _ in pairs(self.sel or {}) do self.nsel = self.nsel + 1 end
    local conn = {}                                -- flow pins with a wire: drawn filled
    for _, e in ipairs(g.exec) do
      local a, b = self.by_id[e.from], self.by_id[e.to]
      conn[a] = conn[a] or {}; conn[a][e.out or 1] = true
      conn[b] = conn[b] or {}; if not e.back or e.jump then conn[b].inn = true end   -- (a goto leads to its label)
    end
    self.exec_conn = conn
    for _, n in ipairs(g.nodes) do
      local x, y = ox + n.x * zz, oy + n.y * zz
      if not n.hidden and x + n.w * zz + 10 >= px and x - 10 <= px + sw and y + n.h * zz >= py and y <= py + sh then self:draw_node(n, ox, oy) end
    end
    self:diff_draw(ox, oy)                         -- (diff.lua: against an earlier state)
    self.value_tip = nil
    if self.probe and (self.hl or self.hover_decl or self.hover_sock) and not self.menu then   -- a hovered wire / pin / chip: its value, by the mouse
      local best
      for l in pairs(self.hl and self.hl.links or {}) do
        local v, name, n, line, computed = self:link_value(l)
        local a = self.by_id[l.from]
        if v and (not best or line < best[4]) then best = { v, name, n, line, a and a.outs[l.out] and a.outs[l.out].vtype, computed, a and a.outs[l.out] and a.outs[l.out].decl } end
      end
      local hc = self.hover_chip
      if not best and hc and hc.side == "in" and hc.pin then   -- a chip under the mouse: its variable there
        local v, name, n, line = self:pin_value(hc.node, hc.pin)
        if v then best = { v, name, n, line, hc.pin.vtype, nil, hc.pin.decl } end
      end
      if not best and self.hover then             -- an input pin under the mouse: its variable there
        for _, pin in ipairs(self.hover.ins) do
          if pin.decl and (pin == self.hover_sock or (self.hover_decl and pin.decl == self.hover_decl)) then
            local v, name, n, line = self:pin_value(self.hover, pin)
            if v then best = { v, name, n, line, pin.vtype, nil, pin.decl } end
          end
        end
      end
      if not best and self.hover then             -- an input pin fed by an expression / call node: that node's value
        for i, pin in ipairs(self.hover.ins) do
          if not pin.decl and pin == self.hover_sock then
            for _, l in ipairs(self.g.links or {}) do
              if l.to == self.hover.id and l.inp == i then
                local v, _, n, line, computed = self:link_value(l)
                if v then best = { v, pin.name, n, line, pin.vtype, computed } end
              end
            end
          end
        end
      end
      if not best and self.hover and self.hover.vexpr then   -- an expression / call node's result pin
        for _, o in ipairs(self.hover.outs) do
          if o.value and not o.decl and o == self.hover_sock then
            local v, n, line, computed = self:expr_value(self.hover)
            if v then best = { v, o.name or "result", n, line, o.vtype, computed } end
          end
        end
      end
      if not best and self.hover then             -- an output pin: the variable it sets, after its line
        for _, pin in ipairs(self.hover.outs) do
          if pin.decl and (pin == self.hover_sock or (self.hover_decl and pin.decl == self.hover_decl)) then
            local v, name, n, line = self:out_value(self.hover, pin)
            if v then best = { v, name, n, line, pin.vtype, nil, pin.decl } end
          end
        end
      end
      if best then
        self.value_tip = true                     -- (it says the type too: no type tip)
        local ahead = best[6] and self.probe.brk == best[4]   -- (stopped on its line: worked out, not run yet)
        local t = best[2] .. (ahead and " ~ " or " = ") .. best[1] .. (best[5] and ("   " .. best[5]) or "")
                  .. (ahead and "   (not run yet: computed)" or "")
                  .. (function()                  -- a variable: the line that last set it (else where it's declared)
                    local d = best[7]
                    if ahead or not d then return "" end
                    local at = B.changed_at(self.probe, d.name, self.probe.brk or best[4], self.doc and self.doc.lines) or self:line_at(d.pos)
                    return at and ("   (at line " .. at .. ")") or ""
                  end)()
        local tw, th = style.font:get_width(t) + 12 * SCALE, style.font:get_height() + 6 * SCALE
        local tx, ty = self.mx + 14 * SCALE, self.my + 12 * SCALE
        rrect(tx, ty, tw, th, 4 * SCALE, alpha(rgb"#16161a", 240))
        renderer.draw_text(style.font, t, tx + 6 * SCALE, ty + 3 * SCALE, C.text)
      end
    end
    local p = self.press
    if p and p.box and p.moved then                -- the selection box: an unfilled orange rect
      local bx, by = math.min(p.x, p.lx), math.min(p.y, p.ly)
      local bw, bh = math.abs(p.lx - p.x), math.abs(p.ly - p.y)
      local t = math.max(1, SCALE)
      renderer.draw_rect(bx, by, bw, bh, alpha(C.sel, 25))
      renderer.draw_rect(bx, by, bw, t, C.sel); renderer.draw_rect(bx, by + bh - t, bw, t, C.sel)
      renderer.draw_rect(bx, by, t, bh, C.sel); renderer.draw_rect(bx + bw - t, by, t, bh, C.sel)
    end
    if p and p.sock and p.moved then               -- a wire being dragged from a socket
      local sx, sy
      if p.sock.exec then sx, sy = self:exec_xy(p.sock.node, p.sock.side, p.sock.i, ox, oy)
      else sx, sy = self:socket_xy(p.sock.node, p.sock.side, p.sock.i, ox, oy) end
      local c = p.sock.exec and EXEC or pin_color(p.sock.sock)
      local ex, ey = p.lx, p.ly
      local t = p.snap                             -- (near a pin: the wire snaps to it)
      if t then
        if t.exec then ex, ey = self:exec_xy(t.node, t.side, t.i, ox, oy) else ex, ey = self:socket_xy(t.node, t.side, t.i, ox, oy) end
        dot(ex, ey, 15 * Z, alpha(C.active, 200))
      end
      if p.sock.side == "out" then wire(sx, sy, ex, ey, c, true) else wire(ex, ey, sx, sy, c, true) end
    end
  end
  self:draw_picker()
  self:draw_edit(ox, oy)
  local hn = self.hover_head                       -- a title: its doc (calls) and its warnings, a tip of lines
  if hn and hn.doc and not self.menu and not self.press and self.mx then
    local rows = { { hn.doc.sig, C.text, style.code_font } }   -- (plugins/canvas/tip.lua: the shared tooltip)
    for _, l in ipairs(hn.doc.lines or {}) do rows[#rows + 1] = { l, C.label } end
    TIP.box(rows, self.mx, self.my, self:menu_bounds())
  end
  local hs = self.hover_sock                       -- a socket's type, when known: a small tip
  local tip = self.hover_decl and self.chip_tip    -- (a chip: what the variable is, how often it's read)
  if not (hn and hn.doc) and not self.value_tip and (tip or (hs and hs.vtype)) and not self.menu and not self.press and self.mx then
    local text = tip or hs.vtype
    TIP.text(text, self.mx, self.my, self:menu_bounds(), T.TYPE[text] or C.text)
  end
  self:draw_changes()                              -- (diff.lua: the changes since opened)
  self:draw_menu()
  -- top-left: what's wrong (errors, warnings, a parse error: the last good
  -- graph stays); bottom-left, on the last pixels of the canvas: what this is,
  -- the frame of the flow shown, what an edit expects, the last message.
  -- Each on a small dark backdrop, no bar across.
  local fh = style.font:get_height()
  self.status_hits = {}                            -- (the counts: a click goes to the next one)
  local function strip(parts, y)                   -- { {text, colour, kind, font = f}... } in a row from the left
    local w = 0
    for _, t in ipairs(parts) do w = w + (t.font or style.font):get_width(t[1]) end
    if w == 0 then return end
    rrect(px + 4 * SCALE, y - 2 * SCALE, w + 8 * SCALE, fh + 4 * SCALE, 3 * SCALE, alpha(rgb"#16161a", 200))
    local x = px + 8 * SCALE
    for _, t in ipairs(parts) do
      local x0 = x
      local hot = t[3] and self.hover_status == t[3]
      local f = t.font or style.font
      x = renderer.draw_text(f, t[1], x, y + (fh - f:get_height()) / 2, hot and C.active or t[2])
      if t[3] then
        local tw = f:get_width((t[1]:gsub("%s+$", "")))
        if hot and not t.font then renderer.draw_rect(x0, y + fh, tw, math.max(1, SCALE), t[2]) end   -- (underlined: a link)
        self.status_hits[#self.status_hits + 1] = { kind = t[3], x = x0, y = y - 2 * SCALE, w = tw, h = fh + 4 * SCALE }
      end
    end
  end
  local top = {}
  if g and (g.errors or 0) > 0 then top[#top + 1] = { string.format("%d error%s   ", g.errors, g.errors > 1 and "s" or ""), C.err, "error" } end
  if g and (g.warnings or 0) > 0 then top[#top + 1] = { string.format("%d warning%s   ", g.warnings, g.warnings > 1 and "s" or ""), C.warn, "warning" } end
  local nb = self.doc and self.doc.filename and #B.lines(self.doc.filename) or 0
  if nb > 0 then
    local nl = 0                                   -- (on code that runs once, at load: the world can't stop there)
    for _, l in ipairs(B.lines(self.doc.filename)) do
      local ln = self:line_node(l)
      if ln and self:wont_stop(ln) then nl = nl + 1 end
    end
    top[#top + 1] = { string.format("%d breakpoint%s%s   ", nb, nb > 1 and "s" or "",
                      nl > 0 and string.format(" (%d at load: won't stop)", nl) or ""), BREAK, "breakpoint" }
  end
  if self.err then top[#top + 1] = { self.err, C.err, self.err_line and "syntax" } end   -- (a link: its place)
  if self.note and self.note.err and system.get_time() - self.note.t < 4 then
    local sep = #top > 0 and not top[#top][1]:find("%s$") and "   " or ""
    top[#top + 1] = { sep .. self.note.text, C.err }
  end
  if #top > 0 then top[#top][1] = top[#top][1]:gsub("%s+$", "") end
  strip(top, py + 6 * SCALE)
  local nc = self:n_changes()                      -- top-right: "N changes" (diff.lua), a link
  if nc > 0 then
    local t = string.format("%d change%s", nc, nc > 1 and "s" or "")
    local tw = style.font:get_width(t)
    local x, y = px + sw - tw - 12 * SCALE, py + 6 * SCALE
    local c = self.CHANGES_COLOR
    rrect(x - 4 * SCALE, y - 2 * SCALE, tw + 8 * SCALE, fh + 4 * SCALE, 3 * SCALE, alpha(rgb"#16161a", 200))
    local hot = self.hover_status == "changes" or self.changes
    renderer.draw_text(style.font, t, x, y, hot and C.active or c)
    if hot then renderer.draw_rect(x, y + fh, tw, math.max(1, SCALE), c) end
    self.status_hits[#self.status_hits + 1] = { kind = "changes", x = x, y = y - 2 * SCALE, w = tw, h = fh + 4 * SCALE }
  end
  local info = self.doc and self.doc.filename and self.doc.filename:match("[^/\\]*$") or "no file"   -- (its name: the tab has the rest)
  local hints = {}                                 -- what the mouse and keys do: the (i) icon's tip
  if g then
    info = info .. string.format("   %d nodes   %d%%", #g.nodes, math.floor(self.zoom * 100 + 0.5))
    hints = { "LMB: select / move / wire", "ALT+LMB: unlink", "RMB: menu / pan", "CTRL+WHEEL: zoom", "DOUBLE-CLICK: edit" }
    local keys = B.where() and { "F5: continue", "F10: over", "F11: into", "SHIFT+F11: out" }   -- (stopped at a breakpoint)
                 or { "F9: breakpoint", "CTRL+F: find", "ALT+LEFT: back", "DEL: delete", "CTRL+Z / CTRL+Y: undo / redo" }
    for _, k in ipairs(keys) do hints[#hints + 1] = k end
    for i, h in ipairs(hints) do hints[i] = { h, i } end   -- shortest first (easier to read; ties as listed)
    table.sort(hints, function(a, b) if #a[1] ~= #b[1] then return #a[1] < #b[1] end return a[2] < b[2] end)
    for i, h in ipairs(hints) do hints[i] = h[1] end
  end
  local bottom = { { info, style.dim } }
  if #hints > 0 then table.insert(bottom, 1, { "i ", style.dim, "help", font = style.icon_font }) end   -- (i): hovered, the mouse and keys
  if self.probe then bottom[#bottom + 1] = { string.format("   flow at t=%.2fs", self.probe.t or 0), PULSE } end
  if self.editing then bottom[#bottom + 1] = { "   editing: Enter applies, a click elsewhere cancels", style.caret } end
  if self.note and not self.note.err and system.get_time() - self.note.t < 4 then bottom[#bottom + 1] = { "   " .. self.note.text, style.syntax["keyword2"] } end
  local by = py + sh - fh - 4 * SCALE
  strip(bottom, by)
  if self.hover_status == "help" and #hints > 0 then   -- the (i) hovered: a tip above it, a line each (shortest first)
    local lh, p = fh + 4 * SCALE, 6 * SCALE
    local tw = 0
    for _, h in ipairs(hints) do tw = math.max(tw, style.font:get_width(h)) end
    local th = #hints * lh + 2 * p
    local tx, ty = px + 4 * SCALE, by - 6 * SCALE - th
    rrect(tx, ty, tw + 2 * p, th, 3 * SCALE, rgb"#181818")
    for i, h in ipairs(hints) do renderer.draw_text(style.font, h, tx + p, ty + p + (i - 1) * lh, C.text) end
  end
  core.pop_clip_rect()
end

-- breakpoints: a red dot on the node's top-left corner; the node the world
-- stopped at (probe.brk: its line), a thick yellow outline (B, BREAK, STOPPED: at the top)
local draw_node0 = NodeGraphView.draw_node
-- a breakpoint is a line (Lua stops at lines): on a line holding several
-- statements (if c then f() end) it belongs to the first of them
function NodeGraphView:line_node(line)
  local g = self.g
  if not g then return nil end
  if self.line_nodes_g ~= g then
    local m = {}
    for _, n in ipairs(g.nodes) do
      if n.line and n.kind ~= "expr" and not n.floating and (not m[n.line] or (n.pos or 0) < (m[n.line].pos or 0)) then m[n.line] = n end
    end
    self.line_nodes, self.line_nodes_g = m, g
  end
  return self.line_nodes[line]
end
function NodeGraphView:draw_node(n, ox, oy)
  local x, y, w, h = ox + n.x * zz, oy + n.y * zz, n.w * zz, n.h * zz
  local stmt = n.line and self:line_node(n.line) == n
  if stmt and self.probe and self.probe.brk == n.line then
    local t = math.max(3, 4 * Z)
    rrect(x - t, y - t, w + 2 * t, h + 2 * t, 5 * Z + t, STOPPED)
  end
  draw_node0(self, n, ox, oy)
  if stmt and self.doc and B.has(self.doc.filename, n.line) then
    local d = math.max(13.5, 19.5 * Z)
    dot(x, y, d, C.outline)
    dot(x, y, math.max(10.5, 15 * Z), BREAK)
    self.hits[#self.hits + 1] = { kind = "breakpoint", x = x - d / 2, y = y - d / 2, w = d, h = d, node = n, line = n.line }   -- (a click: removed)
    if self:wont_stop(n) then dot(x, y, math.max(5, 7 * Z), C.outline) end   -- (hollow: runs at load, won't stop)
  end
end
