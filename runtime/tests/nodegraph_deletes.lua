-- nodegraph_deletes.lua - every node can be deleted (in the editor).
--   play games/pong.lua --lite "dofile('runtime/tests/nodegraph_deletes.lua')@3"
-- Deletes each node of plugins/nodegraph/tests/playground.lua, move-00.lua and
-- games/pong.lua in turn (a copy, in TMPDIR), undoing after each, and checks:
-- no error, the file still parses, no floating code breaks, no statement node
-- is lost. Writes the report to TMPDIR/nodegraph_deletes.txt (and the console).
-- A repeat and its until go together (each picks the other). AUDIT_FILES = {...}: others.
local core = require "core"
local luaparse = require "plugins.nodegraph.luaparse"
core.add_thread(function()
  for i = 1, 5 do coroutine.yield() end
  local out = {}
  for _, file in ipairs(rawget(_G, "AUDIT_FILES") or { "plugins/nodegraph/tests/playground.lua", "plugins/nodegraph/tests/move-00.lua", "games/pong.lua" }) do
    local fh = io.open(file); local src = fh:read("*a"); fh:close()
    local tmp = (os.getenv("TMPDIR") or os.getenv("TEMP") or ".") .. "/del_" .. file:gsub("/", "_")
    fh = io.open(tmp, "w"); fh:write(src); fh:close()
    local v = require("plugins.nodegraph").open(tmp)
    for i = 1, 10 do coroutine.yield() end
    v:update()
    src = v.doc:get_text(1, 1, math.huge, math.huge)
    local count, fails = #v.g.nodes, 0
    for i = 1, count do
      v:update()
      local n = v.g.nodes[i]
      if n and n.kind ~= "start" then
        local title = n.title
        v.note = nil
        v:select({ n })
        local function stmts() local c = 0; for _, m in ipairs(v.g.nodes) do if m.kind ~= "expr" and m.kind ~= "start" then c = c + 1 end end; return c end
        local before = stmts()
        local kind0 = n.kind
        local pick = { n }
        if n.ast and n.ast.tag == "Repeat" then          -- (repeat and until: both, or it refuses)
          for _, m in ipairs(v.g.nodes) do if m ~= n and m.ast == n.ast then pick[2] = m end end
        end
        local ok, err = pcall(v.delete_nodes, v, pick)
        v:update()
        local lost = before - stmts()
        local allowed = (title == "repeat" or title == "until") and 2 or (kind0 == "expr" and 0 or 1)
        if v.doc:get_text(1, 1, math.huge, math.huge) ~= src and lost > allowed and kind0 ~= "function" then   -- (a function: its body goes with it)
          out[#out + 1] = file .. " #" .. i .. " " .. title .. ": LOST " .. (lost - allowed) .. " nodes" end
        for _, F in ipairs(v.g.floats or {}) do if F.err then out[#out + 1] = file .. " #" .. i .. " " .. title .. ": BROKEN FLOAT " .. tostring(F.err) end end
        local txt = v.doc:get_text(1, 1, math.huge, math.huge)
        local msg = v.note and v.note.text or ""
        if not ok then fails = fails + 1; out[#out + 1] = file .. " #" .. i .. " " .. title .. ": ERROR " .. tostring(err)
        elseif not luaparse.parse(txt) then fails = fails + 1; out[#out + 1] = file .. " #" .. i .. " " .. title .. ": broke the file"
        elseif txt == src then out[#out + 1] = file .. " #" .. i .. " " .. n.kind .. " " .. title .. ": refused: " .. msg end
        for _ = 1, 50 do if v.doc:get_text(1, 1, math.huge, math.huge) == src then break end v.doc:undo() end
        if v.doc:get_text(1, 1, math.huge, math.huge) ~= src then out[#out + 1] = "UNDO FAILED at " .. i; break end
        v.doc:clean()
        coroutine.yield()
      end
    end
    out[#out + 1] = file .. ": " .. count .. " nodes, " .. fails .. " errors"
  end
  local dir = os.getenv("TMPDIR") or os.getenv("TEMP") or "."
  local f = io.open(dir .. "/nodegraph_deletes.txt", "w"); f:write(table.concat(out, "\n"), "\n"); f:close()
  print(table.concat(out, "\n"))
  if os.getenv("NG_EXIT") then os.exit(0) end
end)
