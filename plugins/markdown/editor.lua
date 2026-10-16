-- editor.lua - the markdown viewer: .md files rendered on a canvas (runs in
-- lite; see editor/3rd/lite/data/plugins/projectplugins.lua for what P gives).
-- Not a full CommonMark: headings, paragraphs, **bold**, *italic*, `code`,
-- links (a #heading; another .md: shown in this tab, Backspace back; any
-- other file: its tab; the web: the browser), images (![alt](file),
-- <img src= width=>: files next to it or in the project; the web's: alt text),
-- lists (nested, numbered), code blocks, quotes, tables, rules, and the
-- usual HTML tags dropped. The wheel scrolls, CTRL+wheel sizes the text (it
-- flows again to the width), a click on a link follows it; the keys:
-- up / down, page up / down, home / end, backspace (back after a link).
-- Right-click: contents (a section per heading, its headings in a submenu;
-- type to find one), back, size,
-- edit as text, reload, copy, its source. The file is read again when it
-- changes on disk. Its settings: config.lua; the files it opens: files.lua.
local P = ...
P.commands = { { "Back", "markdown:back" }, { "Top", "markdown:top" }, { "Bottom", "markdown:bottom" }, { "Edit as text", "markdown:edit-as-text" } }
P.title = "Markdown preview"                         -- (its name in menus: Open with, the main menu's Plugins)
local core = require "core"
local command = require "core.command"
local keymap = require "core.keymap"
local style = require "core.style"
local View = require "core.view"
local canvas = require "plugins.canvas"
local D = canvas.draw

local DEFAULTS = { size = 15, width = 820, zoom = 1 }
local cfg = {}
local function load_config()
  local c = P.read("config")
  cfg = {}
  for k, v in pairs(DEFAULTS) do cfg[k] = v end
  if type(c) == "table" then for k, v in pairs(c) do if DEFAULTS[k] ~= nil and type(v) == type(DEFAULTS[k]) then cfg[k] = v end end end
  cfg.size = math.max(8, math.min(40, cfg.size))
  cfg.width = math.max(300, cfg.width)
end
local bg = lite_bg or function(c) return c end
local exts, md_exts                                -- (the extensions it shows: files.lua; below)      -- (the editor's: backgrounds let the game show through)

-- parsing: the file -> blocks ----------------------------------------------

local ENT = { lt = "<", gt = ">", amp = "&", quot = '"', nbsp = " ", copy = "(c)", mdash = "-", ndash = "-" }
local TAGS = { a = 1, img = 1, br = 1, p = 1, div = 1, span = 1, b = 1, i = 1, em = 1, strong = 1, sub = 1, sup = 1,
               center = 1, details = 1, summary = 1, h1 = 1, h2 = 1, h3 = 1, h4 = 1, h5 = 1, h6 = 1, hr = 1, kbd = 1, code = 1 }
local INLINE = { img = 1, br = 1, a = 1, b = 1, strong = 1, i = 1, em = 1, code = 1, kbd = 1 }   -- (tags inline() draws)
local function strip_html(s)
  s = s:gsub("<!%-%-.-%-%->", "")
  s = s:gsub("<(/?)(%a%w*)([^>]*)>", function(_, name) local n = name:lower(); if TAGS[n] and not INLINE[n] then return "" end end)   -- (<img>, <br>, <a>...: inline()'s)
  return (s:gsub("&(%a+);", function(e) return ENT[e] end))
end

local function parse(src)
  local lines = {}
  for l in (src:gsub("\r", "") .. "\n"):gmatch("(.-)\n") do lines[#lines + 1] = (l:gsub("\t", "    ")) end
  local blocks, i, last = {}, 1, nil
  local function push(b) b.line = i; blocks[#blocks + 1] = b; last = b; return b end
  local boxes = {}                                 -- HTML containers open (<p>, <div>, <center>): centred or not
  local function centred() for _, c in ipairs(boxes) do if c then return true end end return false end
  local function containers(r)                     -- <p align="center"> / </p>... at r's start: -> r without them
    while true do
      local tag = r:match("^%s*(</?%a+[^>]*>)")
      local nm = tag and tag:match("^</?(%a+)"):lower()
      if not (nm == "p" or nm == "div" or nm == "center") then return r end
      if tag:sub(2, 2) == "/" then table.remove(boxes)
      else boxes[#boxes + 1] = nm == "center" or tag:lower():match("align%s*=%s*[\"']?center") ~= nil end
      r = r:sub(#r:match("^%s*") + #tag + 1)
      if last and last.t == "p" then last = nil end
    end
  end
  while i <= #lines do
    local l = lines[i]
    local ind, rest = l:match("^( *)(.*)$")
    local n = #ind
    local fence = rest:match("^(```+)") or rest:match("^(~~~+)")
    if fence then                                  -- a code block (indented in a list: part of its last item)
      local code, close = {}, "^%s*" .. (fence:gsub("~", "%%~"))
      i = i + 1
      while i <= #lines and not lines[i]:match(close) do
        local ln = lines[i]
        code[#code + 1] = ln:sub(math.min(n, #ln:match("^ *")) + 1)
        i = i + 1
      end
      local cb = { t = "code", lines = code, indent = n }
      if last and last.t == "list" and n > 0 then
        local it = last.items[#last.items]
        last.items[#last.items + 1] = { ind = it.ind, level = it.level, cont = true, code = cb }
        last.gap = true                            -- (indented text after it: more of that item)
      else push(cb) end
    elseif n < 4 and rest:match("^<[hH][1-6][%s>]") then   -- <h1 align="center">...</h1>: a heading
      local lv, attrs, text = rest:match("^<[hH]([1-6])([^>]*)>(.-)</[hH][1-6]>%s*$")
      if not lv then lv, attrs, text = rest:match("^<[hH]([1-6])([^>]*)>(.*)$") end
      push({ t = "h", level = tonumber(lv), text = text, center = centred() or attrs:lower():match("align%s*=%s*[\"']?center") ~= nil })
      last = nil
    elseif n < 4 and rest:match("^<[hH][rR][%s/>]") then
      push({ t = "hr" }); last = nil
    elseif rest == "" then
      if last and last.t == "p" then last = nil end
      if last and last.t == "list" then last.gap = true end
    elseif n < 4 and rest:match("^#+%s") then
      local hashes, text = rest:match("^(#+)%s+(.-)%s*#*$")
      push({ t = "h", level = math.min(6, #hashes), text = text })
      last = nil
    elseif n < 4 and (rest:match("^%-%-%-+%s*$") or rest:match("^%*%*%*+%s*$") or rest:match("^___+%s*$")) then
      push({ t = "hr" }); last = nil
    elseif rest:match("^|") then                   -- a table: its rows, the --- line under the header skipped
      local rows, header = {}, false
      while i <= #lines and lines[i]:match("^%s*|") do
        local r = lines[i]:match("^%s*|(.*)$"):gsub("|%s*$", "")
        if r:match("^[%s:|%-]+$") and r:find("-", 1, true) then header = #rows == 1
        else
          local cells = {}
          for c in (r .. "|"):gmatch("(.-)|") do cells[#cells + 1] = c:match("^%s*(.-)%s*$") end
          rows[#rows + 1] = cells
        end
        i = i + 1
      end
      i = i - 1
      push({ t = "table", rows = rows, header = header }); last = nil
    elseif rest:match("^>") then
      local text = rest:gsub("^>%s?", "")
      if last and last.t == "quote" then last.text = last.text .. " " .. text else push({ t = "quote", text = text }) end
    elseif rest:match("^[%-%*%+]%s") or rest:match("^%d+[%.%)]%s") then   -- a list item: its level from its indent
      local marker, text = rest:match("^([%-%*%+])%s+(.*)$")
      local num
      if not marker then num, text = rest:match("^(%d+)[%.%)]%s+(.*)$") end
      if not (last and last.t == "list") then push({ t = "list", items = {} }) end
      local list = last
      local base = list.items[1] and list.items[1].ind or n
      list.items[#list.items + 1] = { ind = n, level = math.max(0, math.floor((n - base) / 2)), num = num, text = text, line = i }
      list.gap = false
    elseif last and last.t == "list" and n > 0 then   -- more of the last item (or text after a block inside it)
      local it = last.items[#last.items]
      if last.gap or it.code then
        last.items[#last.items + 1] = { ind = it.ind, level = it.level, cont = true, text = rest }
        last.gap = false
      else it.text = it.text .. " " .. rest end
    else
      local r, closed = containers(rest), 0
      while true do                                -- (</p> at its end: closes after this text)
        local t = r:match("</(%a+)%s*>%s*$")
        if not (t and (t:lower() == "p" or t:lower() == "div" or t:lower() == "center")) then break end
        r, closed = r:sub(1, #r - #r:match("</%a+%s*>%s*$")), closed + 1
      end
      local text = strip_html(r)
      if text:match("%S") then
        if last and last.t == "p" then last.text = last.text .. (l:match("  $") and "\n" or " ") .. text
        else push({ t = "p", text = text, center = centred() }) end
      end
      for _ = 1, closed do table.remove(boxes); last = nil end
    end
    i = i + 1
  end
  return blocks
end

-- built-in emoji (the fonts have none): pictures in emoji/ (tools/make_emoji.py
-- draws them), as tall as the text. Later: an emoji font cached in an atlas.
local EMOJI = {
  ["\240\159\142\174"] = "gamepad",                -- U+1F3AE
  ["\226\156\148"] = "check",                        -- U+2714 (and U+2705, the green one)
  ["\226\156\133"] = "check",
  ["\240\159\167\170"] = "test",                   -- U+1F9EA
  ["\240\159\146\164"] = "sleep",                  -- U+1F4A4
  ["\240\159\148\156"] = "soon",                   -- U+1F51C
  ["\240\159\146\161"] = "idea",                   -- U+1F4A1
}
local function emoji_at(s, p)                      -- -> its name, the byte after it (and after a U+FE0F)
  for len = 4, 3, -1 do
    local e = EMOJI[s:sub(p, p + len - 1)]
    if e then
      local q = p + len
      if s:sub(q, q + 2) == "\239\184\143" then q = q + 3 end
      return e, q
    end
  end
end
local emoji_imgs = {}
local function emoji_image(name)                   -- -> img, w, h (nil: not there)
  local c = emoji_imgs[name]
  if c == nil then
    local img = renderer.image and renderer.image.load and renderer.image.load(P.dir .. PATHSEP .. "emoji" .. PATHSEP .. name .. ".png")
    c = img and { img, img:get_size() } or false
    emoji_imgs[name] = c
  end
  if c then return c[1], c[2], c[3] end
end

-- inline: a line of markdown -> spans { text, bold, em, code, link } (an emoji: { emoji = name })
local function inline(s)
  local spans, b, e, link = {}, false, false, nil  -- (link: inside <a href=...>)
  local buf = {}
  local function flush()
    if #buf > 0 then spans[#spans + 1] = { text = table.concat(buf), bold = b, em = e, link = link }; buf = {} end
  end
  local p, n = 1, #s
  while p <= n do
    local c = s:sub(p, p)
    if c == "\\" and p < n and s:sub(p + 1, p + 1):match("%p") then buf[#buf + 1] = s:sub(p + 1, p + 1); p = p + 2
    elseif c == "`" then
      local q = s:find("`", p + 1, true)
      if q then flush(); spans[#spans + 1] = { text = s:sub(p + 1, q - 1), code = true }; p = q + 1
      else buf[#buf + 1] = c; p = p + 1 end
    elseif (c == "!" and s:sub(p + 1, p + 1) == "[") or c == "[" then
      local img = c == "!"
      local a = img and p + 1 or p
      local text, href, q = s:match("^%[(.-)%]%(([^%)]*)%)()", a)
      if text then
        flush()
        if img then spans[#spans + 1] = { img = href:match("^(%S*)"), text = text }
        else spans[#spans + 1] = { text = strip_html(text:gsub("[%*_`]", "")), link = href:match("^(%S*)"), bold = b } end
        p = q
      else buf[#buf + 1] = c; p = p + 1 end
    elseif (c == "*" or c == "_") and s:sub(p + 1, p + 1) == c then
      flush(); b = not b; p = p + 2
    elseif c == "*" or (c == "_" and (p == 1 or s:sub(p - 1, p - 1):match("[%s%p]")) ~= (p == n or s:sub(p + 1, p + 1):match("[%s%p]"))) then
      flush(); e = not e; p = p + 1
    elseif c == "<" then
      local tag = s:match("^<!%-%-.-%-%->", p) or s:match("^</?%a%w*[^>]*>", p)
      local name = tag and tag:match("^</?(%a%w*)")
      local lname, closing = name and name:lower(), tag and tag:sub(2, 2) == "/"
      local function attr(k) return tag:match(k .. '%s*=%s*"([^"]*)"') or tag:match(k .. "%s*=%s*'([^']*)'") or tag:match(k .. "%s*=%s*([^%s>/]+)") end
      if tag and lname == "br" then flush(); spans[#spans + 1] = { br = true }; p = p + #tag
      elseif tag and lname == "a" then              -- <a href="...">: a link until </a>
        flush(); link = not closing and attr("href") or nil; p = p + #tag
      elseif tag and (lname == "b" or lname == "strong") then flush(); b = not closing; p = p + #tag
      elseif tag and (lname == "i" or lname == "em") then flush(); e = not closing; p = p + #tag
      elseif tag and not closing and (lname == "code" or lname == "kbd") then   -- its text, as code
        local q1, q2 = s:find("</" .. name .. "%s*>", p + #tag)
        flush()
        spans[#spans + 1] = { text = strip_html(s:sub(p + #tag, (q1 or n + 1) - 1)), code = true, link = link }
        p = (q2 or n) + 1
      elseif tag and lname == "img" then          -- <img src="..." width="204px" alt="...">
        flush()
        spans[#spans + 1] = { img = attr("src") or "", text = attr("alt") or "", width = tonumber((attr("width") or ""):match("^%d+")), link = link }
        p = p + #tag
      elseif tag and (tag:sub(2, 2) == "!" or TAGS[name:lower()]) then p = p + #tag
      else buf[#buf + 1] = c; p = p + 1 end
    elseif c:byte() >= 0xE2 and emoji_at(s, p) then
      local name, q = emoji_at(s, p)
      flush(); spans[#spans + 1] = { emoji = name, link = link }; p = q
    elseif c == "&" and s:match("^&%a+;", p) then
      local ent = s:match("^&(%a+);", p)
      buf[#buf + 1] = ENT[ent] or ("&" .. ent .. ";")
      p = p + #ent + 2
    else buf[#buf + 1] = c; p = p + 1 end
  end
  flush()
  return spans
end
local function measure(F, s, bold)                 -- a line's width, unwrapped, as flow draws it
  local wsum = 0
  for _, sp in ipairs(inline(s)) do
    if sp.br then
    elseif sp.img then wsum = wsum + F.text:get_width("[" .. sp.text .. "]")
    elseif sp.emoji then wsum = wsum + F.text:get_height()
    elseif sp.code then wsum = wsum + F.mono:get_width(sp.text) + 2 * math.floor(2 * SCALE)
    else wsum = wsum + ((bold or sp.bold) and F.bold_of[F.text] or F.text):get_width(sp.text) end
  end
  return wsum
end
local function plain(s) local t = {} for _, sp in ipairs(inline(s)) do if sp.text and not sp.img then t[#t + 1] = sp.text end end return table.concat(t) end
-- (plain drops emoji: a heading's anchor has none either, as GitHub's)
local function slug(s)                             -- a heading's anchor, as GitHub makes it
  return (plain(s):lower():gsub("[^%w%- ]", ""):gsub(" ", "-"))
end

-- layout: blocks -> things to draw, in pixels, at a size --------------------

local MdView = canvas.View:extend()
MdView.grid = false
MdView.wheel_zooms = false

local function fonts(z)                            -- the sizes it draws with; bold_of[font]: the same size in bold (fonts/font_bold.ttf)
  local px = cfg.size * SCALE * z
  local F = { px = px, text = D.font(px), mono = D.font(px * 0.9, true), h = {}, bold_of = {} }
  F.bold_of[F.text] = D.font(px, false, true)
  for i, k in ipairs({ 2, 1.6, 1.3, 1.12, 1, 0.9 }) do
    F.h[i] = D.font(px * k)
    F.bold_of[F.h[i]] = D.font(px * k, false, true)
  end
  return F
end

-- spans flowed into width w from (x, y): adds draw items and link boxes; -> the y under them.
-- opts: bold, tight (headings), center (each line centred in w)
local function external(href) return href and href:match("^%a[%w+.-]*:") ~= nil end
local function flow(L, spans, x, y, w, font, color, opts)
  opts = opts or {}
  local F = L.F
  local lh = math.floor(font:get_height() * (opts.tight and 1.15 or 1.35))
  local cx = x
  local extra = 0                                  -- (an image in this line: taller than the text)
  local first_item, first_link, right = #L.items + 1, #L.links + 1, x   -- (this line's: to centre it)
  local function newline()
    if opts.center and right > x then              -- the line, moved to the middle
      local dx = math.floor((x + w - right) / 2)
      for k = first_item, #L.items do L.items[k][2] = L.items[k][2] + dx end
      for k = first_link, #L.links do L.links[k].x = L.links[k].x + dx end
    end
    cx = x; y = y + lh + extra; extra = 0
    first_item, first_link, right = #L.items + 1, #L.links + 1, x
  end
  for _, sp in ipairs(spans) do
    local img, iw, ih
    if sp.br then                                  -- <br>: the next line
      if cx > x then newline() end
      goto next_span
    end
    if sp.emoji then                               -- a built-in emoji: a square as tall as the text
      local eimg = emoji_image(sp.emoji)
      local fh = font:get_height()
      local sz = math.floor(fh * 0.92)
      if cx > x and cx + sz > x + w then newline() end
      if eimg then L.items[#L.items + 1] = { "image", cx, y + math.floor((lh - sz) / 2), sz, sz, eimg } end
      if sp.link then L.links[#L.links + 1] = { x = cx, y = y, w = sz, h = fh, href = sp.link } end
      right = cx + sz
      cx = cx + sz + math.floor(fh * 0.12)
      goto next_span
    end
    if sp.img then img, iw, ih = L.image(sp.img) end
    if img then                                    -- an image: its pixels at the text's zoom (width=: that), never wider than the column
      local dw = (sp.width or iw) * SCALE * L.z
      local dh = ih * dw / iw
      if dw > w then dh, dw = dh * w / dw, w end
      dw, dh = math.max(1, math.floor(dw)), math.max(1, math.floor(dh))
      if cx > x and cx + dw > x + w then newline() end
      L.items[#L.items + 1] = { "image", cx, y, dw, dh, img }
      if sp.link then L.links[#L.links + 1] = { x = cx, y = y, w = dw, h = dh, href = sp.link } end
      extra = math.max(extra, dh + math.floor(F.px * 0.4) - lh)
      right = cx + dw
      cx = cx + dw + math.floor(F.px * 0.4)
      goto next_span
    elseif sp.img then sp = { text = "[" .. (sp.text ~= "" and sp.text or "image") .. "]", em = true, link = sp.link } end   -- (the web's, or not there: its alt text)
    do
    local f = sp.code and F.mono or ((sp.bold or opts.bold) and F.bold_of[font]) or font
    local col = sp.link and style.accent or sp.code and (style.syntax["string"] or color) or sp.em and (style.syntax["keyword"] or color) or color
    local words = {}
    local pad = sp.code and math.floor(2 * SCALE) or 0   -- (code: a box with a little room around it)
    if sp.code and (f:get_width(sp.text) + 2 * pad <= x + w - cx or f:get_width(sp.text) + 2 * pad > w) then
      words[1] = sp.text                           -- (fits here: one box; else it wraps at its spaces)
    elseif sp.code then
      for part in (sp.text .. " "):gmatch("(%S+%s*)") do words[#words + 1] = part end
      if #words == 0 then words[1] = sp.text end
    else
      for word, sp2 in sp.text:gmatch("([^%s]*)(%s*)") do
        if word ~= "" or sp2 ~= "" then words[#words + 1] = word .. sp2 end
      end
    end
    local ext = sp.link and external(sp.link) and math.max(5, math.floor(f:get_height() * 0.45))   -- (a web link: a small arrow after it)
    for wi, wd in ipairs(words) do
      local bare = wd:gsub("%s+$", "")
      local ww, bw = f:get_width(wd), f:get_width(bare)
      local more = (ext and wi == #words) and (ext + math.floor(3 * SCALE)) or 0
      if cx > x and cx + bw + more > x + w then newline() end
      if cx == x then wd = wd:gsub("^%s+", ""); ww = f:get_width(wd); bare = wd:gsub("%s+$", ""); bw = f:get_width(bare) end
      if wd ~= "" then
        local ty = y + math.floor((lh - f:get_height()) / 2)
        local pl, pr = wi == 1 and pad or 0, wi == #words and pad or 0
        if sp.code then L.items[#L.items + 1] = { "rect", cx, ty, pl + (wi < #words and ww or bw) + pr, f:get_height(), "code" } end
        L.items[#L.items + 1] = { "text", cx + pl, ty, sp.code and wd or bare, f, col }
        if sp.link then                            -- (underlined: the spaces between its words too)
          L.items[#L.items + 1] = { "rect", cx, ty + f:get_height() - 1, wi < #words and ww or bw, math.max(1, math.floor(SCALE)), col }
          L.links[#L.links + 1] = { x = cx, y = ty, w = ww, h = f:get_height(), href = sp.link }
        end
        right = cx + pl + bw + pr
        if ext and wi == #words then               -- the arrow, after the last word (part of the link)
          local ex, ey = right + math.floor(3 * SCALE), ty + math.floor((f:get_height() - ext) / 2) - math.floor(ext * 0.15)
          L.items[#L.items + 1] = { "ext", ex, ey, ext, col }
          L.links[#L.links + 1] = { x = right, y = ty, w = ext + math.floor(3 * SCALE), h = f:get_height(), href = sp.link }
          right = ex + ext
          ww = ww + (right - (cx + pl + bw + pr))
        end
        cx = cx + ww + pl + pr
      end
    end
    end
    ::next_span::
  end
  if cx > x then newline() end
  return y
end

function MdView:layout()
  local z = self.zoom or cfg.zoom
  local avail = self.size.x - 2 * math.floor(18 * SCALE) - style.scrollbar_size
  local w = math.floor(math.min(avail, cfg.width * SCALE * z))
  local key = w .. "|" .. z .. "|" .. tostring(self.blocks) .. "|" .. tostring(style.text)
  if self.L and self.L.key == key then return self.L end
  local F = fonts(z)
  local L = { key = key, F = F, items = {}, links = {}, anchors = {}, heads = {}, w = w, marks = {}, z = z }   -- marks: { line, y } (text <-> view)
  L.image = function(src) return self:image(src) end
  local x0 = 0
  local y = math.floor(F.px)
  local gap = math.floor(F.px * 0.7)
  local function code_block(b, x)
    local f = F.mono
    local lh = f:get_height()
    local h = #b.lines * lh + gap
    L.items[#L.items + 1] = { "rect", x, y, w - (x - x0), h, "code" }
    for k, cl in ipairs(b.lines) do
      L.items[#L.items + 1] = { "text", x + gap / 2, y + gap / 2 + (k - 1) * lh, cl, f, style.syntax["normal"] or style.text }
    end
    y = y + h + gap
  end
  for bi, b in ipairs(self.blocks or {}) do
    if b.line then L.marks[#L.marks + 1] = { b.line, y } end
    if b.t == "h" then
      local f = F.h[b.level]
      if bi > 1 then y = y + math.floor(f:get_height() * 0.6) end
      local id = slug(b.text)
      L.anchors[id] = y
      L.heads[#L.heads + 1] = { level = b.level, text = plain(b.text), y = y }
      y = flow(L, inline(b.text), x0, y, w, f, b.level <= 2 and style.accent or style.text, { bold = true, tight = true, center = b.center })
      if b.level <= 2 then
        L.items[#L.items + 1] = { "rect", x0, y + 2, w, math.max(1, math.floor(SCALE)), style.divider }
        y = y + math.floor(gap * 0.8)
      end
      y = y + math.floor(gap / 2)
    elseif b.t == "p" then
      y = flow(L, inline(b.text), x0, y, w, F.text, style.text, { center = b.center }) + gap
    elseif b.t == "code" then
      code_block(b, x0 + math.floor(b.indent / 2) * math.floor(F.px * 1.5))
    elseif b.t == "hr" then
      L.items[#L.items + 1] = { "rect", x0, y + gap / 2, w, math.max(1, math.floor(SCALE)), style.dim }
      y = y + gap * 2
    elseif b.t == "quote" then
      local top = y
      local ind = math.floor(F.px)
      y = flow(L, inline(b.text), x0 + ind, y, w - ind, F.text, style.dim)
      L.items[#L.items + 1] = { "rect", x0 + 2, top, math.max(2, math.floor(3 * SCALE)), y - top, style.accent }
      y = y + gap
    elseif b.t == "list" then
      local num = {}
      for k, it in ipairs(b.items) do
        if it.line then L.marks[#L.marks + 1] = { it.line, y } end
        local ind = math.floor(F.px * 1.6)
        local x = x0 + (it.level + 1) * ind
        if not it.cont then
          local lh = math.floor(F.text:get_height() * 1.35)
          if it.num then
            num[it.level] = tonumber(it.num)
            local s = it.num .. "."
            L.items[#L.items + 1] = { "text", x - F.text:get_width(s) - 6 * SCALE, y + math.floor((lh - F.text:get_height()) / 2), s, F.text, style.dim }
          elseif it.text:match("^%[[ xX]%]%s") then   -- "- [x] done" / "- [ ] to do": a box, ticked or not
            local bs = math.floor(F.text:get_height() * 0.62)
            local bx, by = math.floor(x - ind / 2 - bs / 2), math.floor(y + (lh - bs) / 2)
            L.items[#L.items + 1] = { "check", bx, by, bs, it.text:match("^%[[xX]%]") ~= nil }
          else
            local d = math.max(3, math.floor(F.px * 0.32))
            L.items[#L.items + 1] = { "disc", x - ind / 2, y + lh / 2, d, style.dim }
          end
        end
        local text = (not it.num and not it.cont) and it.text:gsub("^%[[ xX]%]%s+", "") or it.text
        if it.code then code_block(it.code, x)
        else y = flow(L, inline(text), x, y, w - (x - x0), F.text, style.text) end
      end
      y = y + gap
    elseif b.t == "table" then
      local ncol = 0
      for _, r in ipairs(b.rows) do ncol = math.max(ncol, #r) end
      local pad = math.floor(F.px * 0.5)
      local cw, total = {}, 0
      for c = 1, ncol do
        cw[c] = 0
        for ri, r in ipairs(b.rows) do
          cw[c] = math.max(cw[c], math.ceil(measure(F, r[c] or "", ri == 1 and b.header)) + 2 * pad + 2)
        end
        total = total + cw[c]
      end
      if total > w then                            -- too wide: every column shrinks, its text wraps
        for c = 1, ncol do cw[c] = math.max(math.floor(F.px * 3), math.floor(cw[c] * w / total)) end
      end
      local tw = 0
      for c = 1, ncol do tw = tw + cw[c] end
      local line = math.max(1, math.floor(SCALE))
      for ri, r in ipairs(b.rows) do
        local top, bottom, x = y, y, x0
        local head = ri == 1 and b.header
        local mark = #L.items
        for c = 1, ncol do
          local yy = flow(L, inline(r[c] or ""), x + pad, top + pad / 2, cw[c] - 2 * pad, F.text, head and style.accent or style.text, { bold = head, tight = true })
          bottom = math.max(bottom, yy + pad / 2)
          x = x + cw[c]
        end
        if head then table.insert(L.items, mark + 1, { "rect", x0, top, tw, bottom - top, "code" }) end
        L.items[#L.items + 1] = { "rect", x0, bottom, tw, line, style.divider }
        y = bottom
      end
      y = y + gap
    end
  end
  L.h = y + math.floor(F.px * 2)
  self.L = L
  return L
end

-- the view -------------------------------------------------------------------

function MdView:new(state)
  MdView.super.new(self)
  self.scrollable = true
  self.filename = state and state.filename or ""
  self.zoom = state and state.zoom or cfg.zoom
  self.history = {}
  self.images = {}
  self:reload()
  if state and state.scroll then self.scroll.y, self.scroll.to.y = state.scroll, state.scroll end
end

function MdView:reload()                            -- its text: the editor's (unsaved too) when it has the doc, else the file
  local info = system.get_file_info(self.filename)
  self.mtime = info and info.modified
  self.images = {}                                 -- (read again: they may have changed too)
  if self.doc then
    self.err, self.change = nil, self.doc:get_change_id()
    self.blocks = parse(table.concat(self.doc.lines))
    self.L = nil
    core.redraw = true
    return
  end
  local f = io.open(self.filename, "rb")
  if f then
    self.err = nil
    self.blocks = parse(f:read("*a"))
    f:close()
  else
    self.blocks, self.err = {}, "can't read " .. self.filename
  end
  self.L = nil
  core.redraw = true
end

function MdView:get_name() return self.filename:match("[^/\\]*$") end
function MdView:get_state() return { filename = self.filename, zoom = self.zoom, scroll = self.scroll.to.y } end
function MdView:scroll_to_line() end               -- (opening a file asks every tab)
function MdView:get_scrollable_size() return self.L and self.L.h or math.huge end
function MdView:bounds() return nil end
function MdView:fit() end

function MdView:origin()                            -- the document's (0, 0) on screen
  local L = self:layout()
  return self.position.x + math.floor((self.size.x - style.scrollbar_size - L.w) / 2), self.position.y - self.scroll.y
end

function MdView:jump(anchor)                        -- a "#heading" link: scroll there (back: where we were)
  local L = self:layout()
  local y = L.anchors[anchor]
  if not y then core.warn("%s: no heading #%s", self:get_name(), anchor) return false end
  self.history[#self.history + 1] = self.scroll.to.y
  self.scroll.to.y = math.max(0, y - math.floor(L.F.px * 0.5))
  return true
end
function MdView:back()                              -- the place before the last link: in this file, or the file before
  local h = table.remove(self.history)
  if type(h) == "table" then
    self.filename, self.doc, self.flipped = h.filename, h.doc, nil
    self:reload()
    self.scroll.y, self.scroll.to.y = h.y, h.y
  elseif h then self.scroll.to.y = h end
end

local function open_url(url)
  if PLATFORM == "Windows" then system.exec('start "" "' .. url .. '"')
  elseif PLATFORM == "Mac OS X" then system.exec('open "' .. url .. '"')
  else system.exec('xdg-open "' .. url .. '"') end
end

-- a link's or an image's path -> the file (abs), or nil: next to this file;
-- "/x" or "docs/x": from the project's folder (or a folder above this one)
function MdView:resolve(path)
  path = path:gsub("\\", "/"):gsub("%%20", " ")
  local dir = (self.filename:gsub("\\", "/")):match("^(.*)/") or "."
  local tries = { dir .. "/" .. path }
  local d = dir
  while d and d:find("/", 1, true) do              -- (the folders above: "docs/x" from inside docs/)
    d = d:match("^(.*)/")
    if d then tries[#tries + 1] = d .. "/" .. path:gsub("^/", "") end
  end
  tries[#tries + 1] = (system.absolute_path(".") or ".") .. "/" .. path:gsub("^/", "")
  for _, f in ipairs(tries) do
    local info = system.get_file_info(f)
    if info then
      if info.type == "dir" then                   -- (a folder: its README.md)
        local r = f:gsub("/$", "") .. "/README.md"
        if system.get_file_info(r) then return system.absolute_path(r) or r end
      else return system.absolute_path(f) or f end
    end
  end
end

function MdView:image(src)                          -- -> img, w, h (nil: the web's, or not there)
  if src == "" or src:match("^%a[%w+.-]*:") then return nil end
  local c = self.images[src]
  if c == nil then
    local file = self:resolve(src)
    local img = file and renderer.image.load(file)
    c = img and { img, img:get_size() } or false
    self.images[src] = c
  end
  if c then return c[1], c[2], c[3] end
end

function MdView:follow(href)
  if href == "" then return end
  if href:sub(1, 1) == "#" then return self:jump(href:sub(2)) end
  if href:match("^%a[%w+.-]*:") then open_url(href); core.log("Opened %s", href) return end
  local path, frag = href:match("^([^#]*)#?(.*)$")
  local file = self:resolve(path)
  if not file then core.warn("%s: no file %s", self:get_name(), path) return end
  local e = file:match("%.([^%./\\]+)$")
  if e and exts[e:lower()] then                    -- markdown: shown here (Backspace: back)
    self.history[#self.history + 1] = { filename = self.filename, doc = self.doc, y = self.scroll.to.y }
    self.filename, self.doc, self.flipped = file, nil, nil
    self:reload()
    self.scroll.y, self.scroll.to.y = 0, 0
    if frag ~= "" then self:jump(frag); table.remove(self.history) end
    return
  end
  core.root_view:open_doc(core.open_doc(file))     -- any other file: its tab
end

function MdView:link_at(x, y)
  local L = self:layout()
  local ox, oy = self:origin()
  for _, l in ipairs(L.links) do
    if x >= ox + l.x and x < ox + l.x + l.w and y >= oy + l.y and y < oy + l.y + l.h then return l end
  end
end

function MdView:on_mouse_pressed(button, x, y, clicks)
  if View.on_mouse_pressed(self, button, x, y, clicks) then return true end   -- (the scrollbar)
  if button == "left" then
    local l = self:link_at(x, y)
    if l then self:follow(l.href) return true end
  end
  return true
end
function MdView:on_mouse_moved(x, y, dx, dy)
  View.on_mouse_moved(self, x, y, dx, dy)
  self.cursor = self:link_at(x, y) and "hand" or "arrow"
end
function MdView:on_mouse_released(button, x, y) View.on_mouse_released(self, button, x, y) end
function MdView:on_mouse_wheel(dy)
  if keymap.modkeys["ctrl"] then
    if dy and dy ~= 0 then self:set_text_zoom((self.zoom or 1) * (dy > 0 and 1.1 or 1 / 1.1)) end
    return true
  end
  View.on_mouse_wheel(self, dy)
  return true
end
function MdView:set_text_zoom(z)                    -- the text's size: the same place stays on top
  local L = self:layout()
  local f = self.scroll.to.y / math.max(1, L.h)
  self.zoom = math.max(0.5, math.min(3, z))
  local L2 = self:layout()
  self.scroll.y = f * L2.h
  self.scroll.to.y = self.scroll.y
  core.redraw = true
end

local next_check = 0
function MdView:line_y(line)                        -- a text line's place in the view (the block it's in)
  local L, y = self:layout(), 0
  for _, m in ipairs(L.marks) do if m[1] <= line then y = m[2] else break end end
  return y
end
function MdView:top_line()                          -- the text line at the view's top
  local L, line = self:layout(), 1
  for _, m in ipairs(L.marks) do if m[2] <= self.scroll.y + 2 then line = m[1] else break end end
  return line
end

function MdView:update()
  View.update(self)
  if self.pending_line and self.size.x > 0 then     -- (flipped from its text: where its caret was)
    local y = math.max(0, self:line_y(self.pending_line) - math.floor(self:layout().F.px))
    self.scroll.y, self.scroll.to.y, self.pending_line = y, y, nil
  end
  if self.doc and self.doc:get_change_id() ~= self.change then self:reload() end   -- (typed in its text: shown at once)
  local now = system.get_time()
  if not self.doc and now >= (self.next_check or 0) then
    self.next_check = now + 0.5                    -- its file changed on disk: read it again
    local info = system.get_file_info(self.filename)
    if info and info.modified ~= self.mtime then self:reload() end
  end
  if now >= next_check then
    next_check = now + 0.5
    if P.changed("config") then load_config(); core.redraw = true end
    if P.changed("files") then P.open_with(P.read("files") or {}, MdView); exts = md_exts() end
  end
end

function MdView:draw_background_color() return style.background end

function MdView:draw_canvas()
  if self.err then
    renderer.draw_text(style.font, self.err, self.position.x + style.padding.x, self.position.y + style.padding.y, style.error or style.text)
    return
  end
  local L = self:layout()
  local ox, oy = self:origin()
  local top, bottom = self.position.y, self.position.y + self.size.y
  local code_bg = bg(style.background2 or style.line_highlight)
  for _, it in ipairs(L.items) do
    local k, x, y = it[1], ox + it[2], oy + it[3]
    if k == "text" then
      if y + it[5]:get_height() >= top and y <= bottom then
        renderer.draw_text(it[5], it[4], x, y, it[6])
      end
    elseif k == "rect" then
      if y + it[5] >= top and y <= bottom then renderer.draw_rect(x, y, it[4], it[5], it[6] == "code" and code_bg or it[6]) end
    elseif k == "image" then
      if y + it[5] >= top and y <= bottom then renderer.draw_image(it[6], x, y, it[4], it[5]) end
    elseif k == "ext" then                         -- a web link's arrow: a corner and a diagonal, up and right
      if y + it[4] >= top and y <= bottom then
        local e, c = it[4], it[5]
        local t = math.max(1, math.floor(SCALE))
        renderer.draw_rect(x + math.floor(e * 0.45), y, e - math.floor(e * 0.45), t, c)
        renderer.draw_rect(x + e - t, y, t, e - math.floor(e * 0.45), c)
        D.line(x + e - t, y + t, x + t, y + e - t, c, t)
      end
    elseif k == "check" then                       -- a list's box: ticked, or empty
      if y + it[4] >= top and y <= bottom then
        local b, t = it[4], math.max(1, math.floor(SCALE))
        local c = it[5] and style.accent or style.dim
        renderer.draw_rect(x, y, b, t, c); renderer.draw_rect(x, y + b - t, b, t, c)
        renderer.draw_rect(x, y, t, b, c); renderer.draw_rect(x + b - t, y, t, b, c)
        if it[5] then                              -- a tick
          local lw = math.max(2, math.floor(b / 7))
          D.line(x + b * 0.22, y + b * 0.52, x + b * 0.42, y + b * 0.74, c, lw)
          D.line(x + b * 0.42, y + b * 0.74, x + b * 0.8, y + b * 0.26, c, lw)
        end
      end
    elseif k == "disc" then
      if y >= top - 10 and y <= bottom + 10 then D.disc(x, y, it[4], it[5]) end
    end
  end
end

function MdView:draw()
  MdView.super.draw(self)
  self:draw_scrollbar()
end

-- the right-click menu: contents first (type to find a heading)
function MdView:menu_items()
  local DIV = require("plugins.contextmenu").DIVIDER
  local L = self:layout()
  local items = {
    { text = "Back", info = "backspace", command = function() self:back() end },
    { text = "Larger text", info = "CTRL+wheel", command = function() self:set_text_zoom(self.zoom * 1.1) end },
    { text = "Smaller text", info = "CTRL+wheel", command = function() self:set_text_zoom(self.zoom / 1.1) end },
    { text = "Text 100%", checked = math.abs(self.zoom - 1) < 1e-3, command = function() self:set_text_zoom(1) end },
    { text = "Edit as text", command = function() self:edit_text() end },
    { text = "Reload", command = function() self:reload() end },
    { text = "Copy path", command = function() system.set_clipboard(self.filename) end },
    DIV,
  }
  for _, it in ipairs(self:contents_items(L)) do items[#items + 1] = it end
  return items                                     -- (its source, reload, settings: the "Plugin: markdown" submenu, last)
end

-- the contents: a section per heading of the top level (the one below a lone
-- title), its own headings in its submenu (the section first: go to its top);
-- headings down to ### (typing finds them too: "Section > heading")
function MdView:contents_items(L)
  local function go(h) return function()
    self.history[#self.history + 1] = self.scroll.to.y
    self.scroll.to.y = math.max(0, h.y - math.floor(L.F.px * 0.5))
  end end
  local heads = {}
  for _, h in ipairs(L.heads) do if h.level <= 3 then heads[#heads + 1] = h end end
  local top, n = 7, 0
  for _, h in ipairs(heads) do top = math.min(top, h.level) end
  for _, h in ipairs(heads) do if h.level == top then n = n + 1 end end
  local items, group = {}, top
  if n == 1 then                                   -- (a lone title: its sections are the level below)
    group = 7
    for _, h in ipairs(heads) do if h.level > top then group = math.min(group, h.level) end end
  end
  local cur
  for _, h in ipairs(heads) do
    if h.level < group then                        -- (the title)
      items[#items + 1] = { text = h.text, command = go(h) }; cur = nil
    elseif h.level == group then
      cur = { text = h.text, command = go(h), kids = {} }
      items[#items + 1] = cur
    elseif cur then
      cur.kids[#cur.kids + 1] = { text = string.rep("  ", h.level - group - 1) .. h.text, command = go(h) }
    else items[#items + 1] = { text = h.text, command = go(h) } end   -- (before any section)
  end
  for _, it in ipairs(items) do                     -- (a section with headings of its own: a submenu)
    if it.kids and #it.kids > 0 then
      local kids, head = it.kids, { text = it.text, info = "top", command = it.command }
      it.sub = function() local l = { head }; for _, k in ipairs(kids) do l[#l + 1] = k end return l end
      it.command = nil
    end
    it.kids = nil
  end
  return items
end

function MdView:edit_text()                          -- its text, in this tab (plugins/tabflip: the tab's icon does it too)
  local node = core.root_view.root_node:get_node_for_view(self)
  if node then require("plugins.tabflip").flip(node, self) end
end

-- a tab flips between the text and this view (the icon left of its name)
local DocView = require "core.docview"
function md_exts()
  local set = {}
  for _, e in ipairs(P.read("files") or {}) do if type(e) == "string" then set[(e:lower():gsub("^%.", ""))] = true end end
  return set
end
exts = md_exts()
require("plugins.tabflip").register {
  key = "markdown",
  name = "markdown",
  text = function(view)
    local f = view:is(DocView) and view.doc and view.doc.filename
    local e = f and f:match("%.([^%./\\]+)$")
    return e ~= nil and exts[e:lower()] == true
  end,
  alt = function(view) return view:is(MdView) end,
  to_alt = function(view)
    local mv = MdView({ filename = system.absolute_path(view.doc.filename) or view.doc.filename })
    mv.doc = view.doc
    mv:reload()
    return mv
  end,
  to_text = function(view) return DocView(view.doc or core.open_doc(view.filename)) end,
  icon = function(x, y, s, c)                      -- an open book: two pages from a spine, a line of text on each
    local t = math.max(1, math.floor(s / 7))
    local half = math.floor(s / 2)
    local function frame(fx, fy, fw, fh)
      renderer.draw_rect(fx, fy, fw, t, c); renderer.draw_rect(fx, fy + fh - t, fw, t, c)
      renderer.draw_rect(fx, fy, t, fh, c); renderer.draw_rect(fx + fw - t, fy, t, fh, c)
    end
    frame(x, y + t, half + t, s - 2 * t)           -- (the left page, then the right: they share the spine)
    frame(x + half, y + t, s - half, s - 2 * t)
    renderer.draw_rect(x + half, y, t, s, c)         -- the spine, a little taller
    if s >= 9 then
      local ly = y + math.floor(s * 0.45)
      renderer.draw_rect(x + 2 * t, ly, half - 3 * t, t, c)
      renderer.draw_rect(x + half + 2 * t, ly, s - half - 3 * t, t, c)
    end
  end,
  tip = "Show as preview",
  menu = "Toggle preview / text",
  after = function(old, new)                       -- the same place in both
    if new:is(MdView) and old.doc then
      if new.doc ~= old.doc then new.doc = old.doc; new:reload() end   -- (from now on: the editor's text, saved or not)
      new.pending_line = old.doc:get_selection()
    elseif new:is(DocView) and old.top_line then
      local line = old:top_line()
      new.doc:set_selection(line, 1)
      new:scroll_to_line(line, false, true)
    end
  end,
}

-- keys, while a markdown tab is the active view
local function active()                              -- the markdown tab in front, or nil
  local v = core.active_view
  if v and v.is and v:is(MdView) then return v end
end
local function scroll(by) return function() local v = active(); v.scroll.to.y = v.scroll.to.y + by(v) end end
command.add(function() return active() ~= nil end, {
  ["markdown:line-down"] = scroll(function(v) return v:layout().F.px * 3 end),
  ["markdown:line-up"] = scroll(function(v) return -v:layout().F.px * 3 end),
  ["markdown:page-down"] = scroll(function(v) return v.size.y * 0.9 end),
  ["markdown:page-up"] = scroll(function(v) return -v.size.y * 0.9 end),
  ["markdown:top"] = function() active().scroll.to.y = 0 end,
  ["markdown:bottom"] = function() local v = active(); v.scroll.to.y = v:get_scrollable_size() end,
  ["markdown:back"] = function() active():back() end,
  ["markdown:edit-as-text"] = function() active():edit_text() end,
})
if not package.loaded["markdown.keys"] then         -- (once: a reload keeps them)
  package.loaded["markdown.keys"] = true
  keymap.add {
    ["down"] = "markdown:line-down", ["up"] = "markdown:line-up",
    ["pagedown"] = "markdown:page-down", ["pageup"] = "markdown:page-up",
    ["home"] = "markdown:top", ["end"] = "markdown:bottom", ["ctrl+home"] = "markdown:top", ["ctrl+end"] = "markdown:bottom",
    ["backspace"] = "markdown:back",
  }
end

load_config()
P.open_with(P.read("files") or {}, MdView)
return MdView
