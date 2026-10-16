-- textproxy.lua - Lite's own text editing for our small text boxes (Replay):
-- the tree's filter, a property being typed, a menu's search, a graph's edit
-- box and comments, the bar's Lua prompt. While one of them has the keyboard
-- an invisible editor view (a document of a line, or of a few) is Lite's
-- active view: every key goes through Lite's keymap to its own editing
-- commands (selection, SHIFT+anything, CTRL+LEFT / RIGHT, CTRL+BACKSPACE,
-- CTRL+A / C / X / V / Z / Y, the user's bindings too), and the text, the
-- caret and the selection are read back for the box to draw itself.
--
--   local TP = require "plugins.textproxy"
--   local h = TP.open(text, {
--     multiline = false,          -- true: Enter / SHIFT+Enter is the box's to decide (see on_key)
--     font = font,                -- the box's font (for the mouse: where a click lands)
--     on_key = function(k) end,   -- the box's own keys first ("return", "escape", "tab", "up"...): true = taken
--     on_change = function(text) end,
--     on_blur = function(h) end,  -- Lite's focus went elsewhere (a click on a view): the box closes
--     select_all = false,         -- the text selected (typing replaces it)
--     alive = function() end,     -- false: its box is gone (a menu closed without saying): closed quietly
--   })
--   h:text()  h:set_text(t [, select_all])  h:caret() -> byte index (1-based)
--   h:range() -> a, b: the selection (byte indices, a < b; a == b: none)
--   h:place(x, y [, line_h])      -- where line 1's text is drawn (surface px): the mouse's reference
--   h:mouse_pressed(button, x, y, clicks)  h:mouse_moved(x, y)  h:mouse_released(button)
--   h:caret_on() -> the caret's blink phase  h:close()
--   TP.active                     -- the box with the keyboard (nil: none)
--   TP.draw(h, font, x, y, color, sel_color, caret_color) -> its height: lines, selection, caret
--
-- Only editing commands run (doc:move-to-*, select-to-*, delete-to-*, cut,
-- copy, paste, undo, redo, select-all...); CTRL+S, find, the command palette
-- and every other key do nothing while a box types. One line: no newlines
-- (pasted ones become spaces).
local core = require "core"
local command = require "core.command"
local keymap = require "core.keymap"
local style = require "core.style"
local Doc = require "core.doc"
local DocView = require "core.docview"

local TP = {}

-- the document: one line, or a few; never a file
local ProxyDoc = Doc:extend()
function ProxyDoc:insert(line, col, text)
  if not self.multiline then text = text:gsub("\r?\n", " ") end   -- (one line: what's pasted joins it)
  ProxyDoc.super.insert(self, line, col, text)
end
function ProxyDoc:on_text_change(kind)
  local h = self.handle
  if h and h.opts.on_change then h.opts.on_change(h:text()) end
  if h then h.t0 = system.get_time() end
  core.redraw = true
end
function ProxyDoc:save() end                       -- (never a file)
function ProxyDoc:is_dirty() return false end

-- the view: never drawn (the box draws), placed where the box's text is
local ProxyView = DocView:extend()
function ProxyView:get_name()                      -- (the window title stays the editor's)
  local v = core.last_active_view
  if v and v ~= self and v.get_name then return v:get_name() end
  return "---"
end
function ProxyView:get_font() return self.box_font or rawget(_G, "host_ui_font") or style.font end
function ProxyView:get_line_height() return self.box_line_h or self:get_font():get_height() end
function ProxyView:get_gutter_width() return 0 end
function ProxyView:get_line_screen_position(idx) return self.box_x or 0, (self.box_y or 0) + ((idx or 1) - 1) * self:get_line_height() end
function ProxyView:get_line_text_y_offset() return 0 end
function ProxyView:scroll_to_make_visible() end
function ProxyView:scroll_to_line() end
function ProxyView:get_scrollable_size() return 0 end
function ProxyView:on_text_input(text) self.doc:text_input(text) end   -- (not DocView's: plugins for code wrap that one)
function ProxyView:draw() end
function ProxyView:update() end
function ProxyView:try_close(do_close) do_close() end

local view                                         -- one, reused (its document too: one box types at a time)
local function the_view()
  if not view then view = ProxyView(ProxyDoc()) end
  return view
end

-- the commands a box may run (the rest: nothing)
local ALLOWED = {
  ["doc:undo"] = true, ["doc:redo"] = true, ["doc:cut"] = true, ["doc:copy"] = true, ["doc:paste"] = true,
  ["doc:delete"] = true, ["doc:backspace"] = true, ["doc:select-all"] = true, ["doc:select-none"] = true,
  ["doc:select-word"] = true, ["doc:upper-case"] = true, ["doc:lower-case"] = true,
  ["doc:move-to-previous-char"] = true, ["doc:move-to-next-char"] = true,
}
local MULTI = { ["doc:newline"] = true, ["doc:select-lines"] = true }
local function allowed(cmd, multiline)
  if ALLOWED[cmd] or (multiline and MULTI[cmd]) then return true end
  local what = cmd:match("^doc:move%-to%-(.+)$") or cmd:match("^doc:select%-to%-(.+)$") or cmd:match("^doc:delete%-to%-(.+)$")
  if not what then return false end
  if not multiline and (what:match("line$") or what:match("page$") or what:match("block")) then
    return what == "start-of-line" or what == "end-of-line"   -- (one line: no lines above or below)
  end
  return true
end

local Handle = {}
Handle.__index = Handle

local MODKEYS = { ["left ctrl"] = "ctrl", ["right ctrl"] = "ctrl", ["left shift"] = "shift", ["right shift"] = "shift",
                  ["left alt"] = "alt", ["right alt"] = "altgr" }
local function stroke(k)
  local s = ""
  for _, mk in ipairs({ "ctrl", "alt", "altgr", "shift" }) do if keymap.modkeys[mk] then s = s .. mk .. "+" end end
  return s .. k
end
TP.stroke = stroke                                 -- (a key as the keymap names it now: "ctrl+shift+left")

local function host_typing(on)                    -- (the host sends Lite the keyboard while a box types: replay.c)
  local f = rawget(_G, "host_call")
  if f then f(on and "typing on" or "typing off") end
end

function TP.open(text, opts)
  local before = TP.active
  if before then                                   -- (another box had it: it hears it lost it)
    before:close()
    if before.opts.on_blur then before.opts.on_blur(before) end
  end
  opts = opts or {}
  local v = the_view()
  local d = v.doc
  d.handle = nil
  d.lines, d.selections, d.cursor_clipboard = { "\n" }, { 1, 1, 1, 1 }, {}   -- (afresh; not Doc:reset(): that starts
  d.highlighter:reset()                                                       --  another highlighter thread each time)
  d.multiline = opts.multiline and true or false
  local h = setmetatable({ view = v, doc = d, opts = opts, t0 = system.get_time() }, Handle)
  d.handle = nil
  if text and text ~= "" then d:insert(1, 1, text) end
  d.undo_stack, d.redo_stack = { idx = 1 }, { idx = 1 }   -- (undo goes back to this, not before it)
  if opts.select_all then d:set_selection(math.huge, math.huge, 1, 1) else d:set_selection(math.huge, math.huge) end
  d.handle = h
  v.box_font = opts.font
  v.box_line_h = opts.line_h
  local prev = core.active_view
  h.prev = prev ~= v and prev or nil
  core.set_active_view(v)
  TP.active = h
  host_typing(true)
  core.redraw = true
  return h
end

function Handle:alive() return TP.active == self end
function Handle:insert(t) if self:alive() then self.doc:text_input(t) end end   -- (a box's own key: SHIFT+Enter's new line)
function Handle:text() return (self.doc:get_text(1, 1, math.huge, math.huge)) end
function Handle:set_text(t, select_all)
  if not self:alive() then return end
  local d = self.doc
  local cb = d.handle
  d.handle = nil                                   -- (no on_change for a text the box set itself)
  d:remove(1, 1, math.huge, math.huge)
  if t and t ~= "" then d:insert(1, 1, t) end
  if select_all then d:set_selection(math.huge, math.huge, 1, 1) else d:set_selection(math.huge, math.huge) end
  d.handle = cb
  self.t0 = system.get_time()
  core.redraw = true
end
local function offset(d, line, col)                -- (line, col) -> a byte index in the whole text
  local n = 0
  for i = 1, line - 1 do n = n + #d.lines[i] end
  return n + col
end
function Handle:caret()
  local l, c = self.doc:get_selection()
  return offset(self.doc, l, c)
end
function Handle:range()
  local l1, c1, l2, c2 = self.doc:get_selection(true)
  return offset(self.doc, l1, c1), offset(self.doc, l2, c2)
end
function Handle:place(x, y, line_h, font)
  self.view.box_x, self.view.box_y = x, y
  if line_h then self.view.box_line_h = line_h end
  if font then self.view.box_font = font end       -- (a graph's zoom: its font changes size)
end
function Handle:caret_on() return ((system.get_time() - self.t0) % 1.06) < 0.53 end

-- the mouse: the box sends what lands on it (surface px)
function Handle:mouse_pressed(button, x, y, clicks)
  if not self:alive() then return end
  if core.active_view ~= self.view then core.set_active_view(self.view) end   -- (the click went to a view first)
  self.selecting = true
  DocView.on_mouse_pressed(self.view, button, x, y, clicks)
  self.t0 = system.get_time()
  core.redraw = true
end
function Handle:mouse_moved(x, y)
  if not (self:alive() and self.selecting) then return end
  DocView.on_mouse_moved(self.view, x, y, 0, 0)
  core.redraw = true
end
function Handle:mouse_released(button)
  if not self:alive() then return end
  self.selecting = false
  self.view.mouse_selecting = nil
end

function Handle:close()
  if TP.active ~= self then return end
  TP.active = nil
  host_typing(false)
  self.doc.handle = nil
  if core.active_view == self.view then
    local back = self.prev
    if not back or back == self.view then back = core.root_view.root_node:get_active_view() end
    core.set_active_view(back)
  end
  core.redraw = true
end

-- a key while a box types: its own keys, then Lite's editing commands, and
-- nothing else (-> true: taken, its text doesn't follow)
function Handle:key(k)
  if MODKEYS[k] then return nil end                -- (the keymap's: CTRL / SHIFT / ALT held)
  local o = self.opts
  if o.on_key and o.on_key(k) then return true end
  if not self:alive() then return true end         -- (the box closed on that key)
  local cmds = keymap.map[stroke(k)]
  if cmds then
    for _, c in ipairs(cmds) do
      if allowed(c, self.doc.multiline) and command.perform(c) then self.t0 = system.get_time(); core.redraw = true; return true end
    end
  end
  return false                                     -- (a letter: its text comes next)
end

-- every key and every text first (core.on_event: whatever the plugins wrapped)
local on_event = core.on_event
function core.on_event(type, ...)
  local h = TP.active
  if h and h.opts.alive and not h.opts.alive() then h:close(); h = nil end
  if h and core.active_view ~= h.view then         -- (a click went elsewhere and nothing took the box back)
    if not h.selecting then
      local cb = h.opts.on_blur
      h:close()
      if cb then cb(h) end
      h = TP.active
    end
  end
  if h then
    if type == "textinput" then h.view:on_text_input(...); return false end
    if type == "keypressed" then
      local r = h:key(...)
      if r ~= nil then return r end
    end
  end
  return on_event(type, ...)
end

-- the blink: a redraw when the caret shows / hides; a box gone, or lite's focus gone elsewhere: closed
core.add_thread(function()
  local last
  while true do
    local h = TP.active
    if h and h.opts.alive and not h.opts.alive() then h:close(); h = nil end
    if h then
      local on = h:caret_on()
      if on ~= last then last = on; core.redraw = true end
      if core.active_view ~= h.view and not h.selecting then   -- (lost without an event: a view set itself active)
        local cb = h.opts.on_blur
        h:close()
        if cb then cb(h) end
      end
    end
    coroutine.yield()                              -- (every frame: a box gone hands the focus back at once)
  end
end)

-- drawing a box's text (one line, or a few): the selection behind it, the caret
function TP.draw(h, font, x, y, color, sel_color, caret_color, line_h)
  local lh = line_h or font:get_height()
  local d = h.doc
  local l1, c1, l2, c2 = d:get_selection(true)
  for i, line in ipairs(d.lines) do
    local t = line:gsub("\n$", "")
    local ly = y + (i - 1) * lh
    if (l1 ~= l2 or c1 ~= c2) and i >= l1 and i <= l2 then
      local a = (i == l1) and font:get_width(t:sub(1, c1 - 1)) or 0
      local b = (i == l2) and font:get_width(t:sub(1, c2 - 1)) or font:get_width(t) + font:get_width(" ")
      if b > a then renderer.draw_rect(x + a, ly, b - a, lh, sel_color or style.selection) end
    end
    renderer.draw_text(font, t, x, ly + math.floor((lh - font:get_height()) / 2), color)
  end
  if caret_color and h:caret_on() then
    local cl, cc = d:get_selection()
    local t = (d.lines[cl] or ""):gsub("\n$", "")
    renderer.draw_rect(x + font:get_width(t:sub(1, cc - 1)), y + (cl - 1) * lh, style.caret_width or 2, lh, caret_color)
  end
  return #d.lines * lh
end
-- where a byte index of the text is drawn (x from the box's left, line)
function TP.x_of(h, font, i)
  local d, n = h.doc, 0
  for li, line in ipairs(d.lines) do
    if i <= n + #line then return font:get_width(line:sub(1, i - n - 1)), li end
    n = n + #line
  end
  local last = d.lines[#d.lines]:gsub("\n$", "")
  return font:get_width(last), #d.lines
end

-- the bar's Lua prompt (replay.c draws it): the host asks through these
local prompt
rawset(_G, "lite_prompt", function(cmd, a, b, c, d)
  if cmd == "focus" then                           -- a: its text, b: font px (nil: the UI font)
    prompt = TP.open(a or "", {
      on_key = function(k)
        local ctrl = keymap.modkeys["ctrl"]
        local host = rawget(_G, "host_call")
        local function say(what) if host then host("prompt " .. what) end return true end
        if k == "return" or k == "keypad enter" then return say("run") end
        if k == "escape" then return say("leave") end
        if k == "up" and not ctrl then return say("older") end
        if k == "down" and not ctrl then return say("newer") end
        if k == "l" and ctrl then return say("clear") end
        if k == "u" and ctrl then prompt:set_text("") return true end
        if k == "c" and ctrl then                    -- (nothing selected: the line, or the last result)
          local x1, x2 = prompt:range()
          if x1 == x2 then return say("copy") end
        end
        return false
      end,
      on_blur = function() local host = rawget(_G, "host_call"); if host then host("prompt blurred") end end,
    })
    return true
  elseif cmd == "set" then                         -- a: its text, b: the caret (a byte offset, 0 first; nil / < 0: the end)
    if prompt and prompt:alive() then
      prompt:set_text(a or "")
      if b and b >= 0 then prompt.doc:set_selection(1, math.floor(b) + 1) end
    end
  elseif cmd == "place" then                       -- a, b: line 1's text at (surface px), c: its height
    if prompt and prompt:alive() then prompt:place(a, b, c) end
  elseif cmd == "get" then                         -- -> text, caret, selection from, to (byte indices), caret shown
    if not (prompt and prompt:alive()) then return nil end
    local s1, s2 = prompt:range()
    return prompt:text(), prompt:caret(), s1, s2, prompt:caret_on()
  elseif cmd == "mouse" then                       -- a: "pressed" / "moved" / "released", b, c: surface px, d: clicks
    if not (prompt and prompt:alive()) then return end
    if a == "pressed" then prompt:mouse_pressed("left", b, c, d or 1)
    elseif a == "moved" then prompt:mouse_moved(b, c)
    else prompt:mouse_released("left") end
  elseif cmd == "blur" then
    if prompt then prompt:close(); prompt = nil end
  end
end)

return TP
