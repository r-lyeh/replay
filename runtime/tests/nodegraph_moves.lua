-- nodegraph_moves.lua - every node of every graph can be moved (headless).
--   lua runtime/tests/nodegraph_moves.lua            all of games/ and tests/
--   lua runtime/tests/nodegraph_moves.lua FILE...    just those
-- For each node, like a drag in the editor (util.drag_roots + edits.lua
-- write_tags): move it right, then down (its tag is there now), then back.
-- Checks: it can be moved; the file still parses; it lands where it was put;
-- nothing else moved (but what its function / floating code holds); moved back,
-- the text is exactly what it was. tests.lua runs it on tests/ (it's slow on all).
local here = (arg and arg[0] or ""):match("^(.*[/\\])") or ""
local root = here .. "../../"
local PL = root .. "plugins/nodegraph/"

local M = {}
function M.run(files, quiet)
  local saved_path, saved_pre = package.path, {}
  package.path = PL .. "?.lua;" .. package.path
  local View = {}; View.__index = View              -- (lite stubs: edits.lua only needs a few)
  function View:extend() local c = setmetatable({}, { __index = self }); c.__index = c; c.super = self; return c end
  function View:is() return false end
  local stubs = {
    ["core"] = { redraw = false, add_thread = function() end, log = function() end },
    ["core.common"] = setmetatable({}, { __index = function() return function() end end }),
    ["core.command"] = { add = function() end, perform = function() end },
    ["core.keymap"] = { add = function() end, modkeys = {} },
    ["core.style"] = setmetatable({ padding = { x = 4, y = 4 } }, { __index = function() return {} end }),
    ["core.docview"] = View, ["core.view"] = View,
  }
  local function pre(name, fn) saved_pre[name] = package.preload[name]; package.preload[name] = fn end
  for k, v in pairs(stubs) do if not package.loaded[k] then pre(k, function() return v end) end end
  for _, m in ipairs({ "luaparse", "graph", "resolve", "class", "theme", "util" }) do
    pre("plugins.nodegraph." .. m, function() return require(m) end)
  end
  pre("plugins.nodegraph.edits", function() return dofile(PL .. "edits.lua") end)
  pre("plugins.canvas.theme", function() return dofile(root .. "editor/3rd/lite/data/plugins/canvas/theme.lua") end)   -- (the shared colours)
  local P, G, R, U = require "luaparse", require "graph", require "resolve", require "util"
  local NGV = require "class"
  require "plugins.nodegraph.edits"
  package.path = saved_path
  for k, v in pairs(saved_pre) do package.preload[k] = v end

  local font = { get_width = function(_, s) return #s * 7 end, get_height = function() return 14 end }
  local function build(src)
    local ast = assert(P.parse(src))
    return G.build(ast, { font = font, code_font = font, res = R.resolve(ast), parse = P.parse, resolve = R.resolve, grid = 24 })
  end
  local function key_of(list)                      -- (as view.lua matches nodes across rebuilds)
    local keys, count = {}, {}
    for _, n in ipairs(list) do
      local k = n.kind .. "\0" .. n.title
      count[k] = (count[k] or 0) + 1
      keys[n] = k .. "\0" .. count[k]
    end
    return keys
  end
  local function by_key(g) local t = {}; for n, k in pairs(key_of(g.nodes)) do t[k] = n end; return t end
  local function move(text, g, roots, ddx, ddy)
    local new
    local v = setmetatable({ doc = { get_text = function() return text end } }, NGV)
    v.g = g
    function v:replace_text(_, t) new = t end
    v.flash = function() end
    local list = {}
    for _, it in ipairs(roots) do
      list[#list + 1] = { it[1], function(t)
        local nx, ny = (tonumber(t.vals.dx) or 0) + ddx, (tonumber(t.vals.dy) or 0) + ddy
        v.set_val(t, "dx", nx ~= 0 and tostring(nx) or nil)
        v.set_val(t, "dy", ny ~= 0 and tostring(ny) or nil)
      end }
    end
    v:write_tags(list)
    return new
  end

  local fails, total = {}, 0
  for _, f in ipairs(files) do
    local fh = assert(io.open(f, "rb")); local src = fh:read("*a"); fh:close()
    local g0 = build(src)
    local k0 = key_of(g0.nodes)
    for _, n in ipairs(g0.nodes) do
      total = total + 1
      local function fail(why) fails[#fails + 1] = f .. ":" .. tostring(n.line) .. ": " .. n.kind .. " '" .. n.title .. "': " .. why end
      local roots = U.drag_roots({ n })
      if #roots == 0 then fail("can't be moved") else
        local ok, new = pcall(move, src, g0, roots, 24, 0)
        if not ok then fail("error: " .. tostring(new))
        elseif not new then fail("no edit")
        else
          local ok2, g1 = pcall(build, new)
          local m = ok2 and by_key(g1)[k0[n]]
          if not ok2 then fail("the text broke: " .. tostring(g1))
          elseif not m then fail("lost after the move")
          elseif m.x - n.x ~= 24 or m.y ~= n.y then fail("moved by " .. (m.x - n.x) .. ", " .. (m.y - n.y))
          else
            local el, b1 = roots[1][2], by_key(g1)
            for _, o in ipairs(g0.nodes) do       -- nothing else moved, but what its frame / float holds
              local p, carried = o, false
              while p do if p == el then carried = true break end; p = p.parent end
              local mo = b1[k0[o]]
              if mo and not carried and (mo.x ~= o.x or mo.y ~= o.y) then fail("moved " .. o.kind .. " '" .. o.title .. "' too"); break end
            end
            local ok3, new2 = pcall(move, new, g1, U.drag_roots({ m }), 0, 24)
            local g2 = ok3 and new2 and build(new2)
            local m2 = g2 and by_key(g2)[k0[n]]
            if not m2 or m2.x - n.x ~= 24 or m2.y - n.y ~= 24 then fail("a second move: " .. tostring(ok3 and "misplaced" or new2))
            else
              local ok4, back = pcall(move, new2, g2, U.drag_roots({ m2 }), -24, -24)
              if not ok4 or back ~= src then fail("moved back, the text differs") end
            end
          end
        end
      end
    end
  end
  if not quiet then
    for _, s in ipairs(fails) do print(s) end
    print(string.format("nodegraph moves: %d nodes in %d files, %d failed", total, #files, #fails))
  end
  return total, fails
end

if arg and arg[0] and arg[0]:match("nodegraph_moves%.lua$") then   -- run, not loaded
  local files = {}
  if arg[1] then for i = 1, #arg do files[i] = arg[i] end
  else
    local p = io.popen('find "' .. root .. 'games" "' .. root .. 'plugins/nodegraph/tests" -name "*.lua" 2>/dev/null')
    for l in p:lines() do files[#files + 1] = l end
    p:close()
    table.sort(files)
  end
  local _, fails = M.run(files)
  os.exit(#fails == 0 and 0 or 1)
end
return M
