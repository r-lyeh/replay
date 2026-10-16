-- chain.lua - plugins that feed other plugins (Replay). A plugin that makes
-- another plugin's files registers as a maker: the dungeon generator makes
-- the tilemap editor's .tmap maps. What it makes is marked with where it came
-- from (`made_by`, a path beside it), so the plugin that edits the result can
-- offer *Regenerate* and *Open the source*. Each step is a file: a chain can
-- be cut at any link (edit the result by hand: it stays yours until it's
-- regenerated) and fed on (a result can itself be a maker's source).
--
--   local chain = require "plugins.chain"
--   chain.register { ext = "dungeon", key = "dungeon", name = "Dungeon generator", makes = "tmap",
--                    build = function(source_path) return out_path end }   -- (or nil, err)
--   chain.rebuild(source_path)            -> out_path | nil, err
--   chain.source(made_by, result_path)    -> the source's absolute path
--   chain.makers_of("tmap")               -> the makers that make .tmap files
local chain = { makers = {} }

local function ext_of(path) return (tostring(path):match("%.([^%./\\]+)$") or ""):lower() end
local function dir_of(path) return tostring(path):gsub("\\", "/"):match("^(.*)/[^/]*$") or "." end

function chain.register(m)
  assert(type(m) == "table" and m.ext and m.build, "chain.register: { ext =, build = }")
  chain.makers[m.ext:lower()] = m
end
function chain.maker_of(source_path) return chain.makers[ext_of(source_path)] end
function chain.makers_of(ext)
  local out = {}
  for _, m in pairs(chain.makers) do if m.makes == ext then out[#out + 1] = m end end
  table.sort(out, function(a, b) return a.ext < b.ext end)
  return out
end
-- a result's `made_by` (relative to the result's folder, or absolute) -> the source's path
function chain.source(made_by, result_path)
  if type(made_by) ~= "string" or made_by == "" then return nil end
  if made_by:match("^/") or made_by:match("^%a:[/\\]") then return made_by end
  return dir_of(result_path) .. "/" .. made_by
end
function chain.rebuild(source_path)
  local m = chain.maker_of(source_path)
  if not m then return nil, "no plugin makes files from ." .. ext_of(source_path) end
  local ok, out, err = pcall(m.build, source_path)
  if not ok then return nil, tostring(out) end
  return out, err
end
-- open a source in its maker's tab
function chain.open_source(source_path)
  local m = chain.maker_of(source_path)
  local ok, ow = pcall(require, "plugins.openwith")
  if m and m.key and ok and ow.open then return ow.open(m.key, source_path) end
  local core = require "core"
  return core.root_view:open_doc(core.open_doc(source_path))
end

return chain
