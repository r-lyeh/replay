local core = require "core"
local DocView = require "core.docview"

local workspace_filename = ".workspace.lua" --< Replay: was .lite_workspace.lua (still read once, if there's no new one)
local old_workspace_filename = ".lite_workspace.lua"


local function serialize(val)
  if type(val) == "string" then
    return string.format("%q", val)
  elseif type(val) == "table" then
    local t = {}
    for k, v in pairs(val) do
      table.insert(t, "[" .. serialize(k) .. "]=" .. serialize(v))
    end
    return "{" .. table.concat(t, ",") .. "}"
  end
  return tostring(val)
end


local function has_no_locked_children(node)
  if node.locked then return false end
  if node.type == "leaf" then return true end
  return has_no_locked_children(node.a) and has_no_locked_children(node.b)
end


local function get_unlocked_root(node)
  if node.type == "leaf" then
    return not node.locked and node
  end
  if has_no_locked_children(node) then
    return node
  end
  return get_unlocked_root(node.a) or get_unlocked_root(node.b)
end


--< Replay: files inside the project folder are kept relative to it
-- (./games/pong.lua), so the project can be moved or its folder renamed;
-- all with / (Windows takes it too: the same file on every platform);
-- loaded, they're absolute again (as lite keeps them)
local function to_rel(f)
  if type(f) ~= "string" then return f end
  local unix = f:gsub("\\", "/")
  local root = system.absolute_path(".")
  if not root then return unix end
  local nr = root:gsub("\\", "/"):lower()
  if nr:sub(-1) ~= "/" then nr = nr .. "/" end
  if unix:lower():sub(1, #nr) == nr then return "./" .. unix:sub(#nr + 1) end
  return unix
end
local function to_abs(f)
  if type(f) == "string" and (f:sub(1, 2) == "./" or f:sub(1, 2) == ".\\") then return system.absolute_path(f) or f end
  return f
end
-->

local function save_view(view)
  local mt = getmetatable(view)
  if mt == DocView then
    return {
      type = "doc",
      active = (core.active_view == view),
      filename = to_rel(view.doc.filename), --< Replay: relative to the project
      selection = { view.doc:get_selection() },
      scroll = { x = view.scroll.to.x, y = view.scroll.to.y },
      text = not view.doc.filename and view.doc:get_text(1, 1, math.huge, math.huge)
    }
  end
  for name, mod in pairs(package.loaded) do
    if mod == mt then
      local state = view.get_state and view:get_state() or nil
      if type(state) == "table" and state.filename then state.filename = to_rel(state.filename) end   --< Replay
      return {
        type = "view",
        active = (core.active_view == view),
        module = name,
        state = state --< Replay: e.g. which file a graph tab shows
      }
    end
  end
end


local function load_view(t)
  if t.type == "doc" then
    local ok, doc = pcall(core.open_doc, to_abs(t.filename))
    if not ok then
      return DocView(core.open_doc())
    end
    local dv = DocView(doc)
    if t.text then doc:insert(1, 1, t.text) end
    doc:set_selection(table.unpack(t.selection))
    dv.last_line, dv.last_col = doc:get_selection()
    dv.scroll.x, dv.scroll.to.x = t.scroll.x, t.scroll.x
    dv.scroll.y, dv.scroll.to.y = t.scroll.y, t.scroll.y
    return dv
  end
  if type(t.state) == "table" and t.state.filename then t.state.filename = to_abs(t.state.filename) end   --< Replay
  return require(t.module)(t.state) --< Replay: the state saved by get_state()
end


local function save_node(node)
  local res = {}
  res.type = node.type
  if node.type == "leaf" then
    res.views = {}
    for _, view in ipairs(node.views) do
      local t = save_view(view)
      if t then
        table.insert(res.views, t)
        if node.active_view == view then
          res.active_view = #res.views
        end
      end
    end
  else
    res.divider = node.divider
    res.a = save_node(node.a)
    res.b = save_node(node.b)
  end
  return res
end


local function load_node(node, t)
  if t.type == "leaf" then
    local res
    for _, v in ipairs(t.views) do
      local view = load_view(v)
      if v.active then res = view end
      node:add_view(view)
    end
    if t.active_view then
      node:set_active_view(node.views[t.active_view])
    end
    return res
  else
    node:split(t.type == "hsplit" and "right" or "down")
    node.divider = t.divider
    local res1 = load_node(node.a, t.a)
    local res2 = load_node(node.b, t.b)
    return res1 or res2
  end
end


local function save_workspace()
  if host_scripted then return end  --< Replay: a scripted run (tests) starts clean and leaves nothing
  local root = get_unlocked_root(core.root_view.root_node)
  local fp = io.open(workspace_filename, "w")
  if fp then
    fp:write("return ", serialize(save_node(root)), "\n")
    fp:close()
  end
end


local function load_workspace()
  if host_scripted then return end  --< Replay: a scripted run (tests) starts clean and leaves nothing
  local name = workspace_filename
  if not system.get_file_info(name) and system.get_file_info(old_workspace_filename) then name = old_workspace_filename end --< Replay
  local ok, t = pcall(dofile, name)
  os.remove(name)
  if ok then
    local root = get_unlocked_root(core.root_view.root_node)
    local active_view = load_node(root, t)
    if active_view then
      core.set_active_view(active_view)
    end
  end
end


local run = core.run
function core.run(...)
  if #core.docs == 0 then
    core.try(load_workspace)

    local exit = os.exit
    function os.exit(...)
      save_workspace()
      exit(...)
    end
  end

  core.run = run
  return core.run(...)
end

local run1 = core.run1
function core.run1(...)
  if #core.docs == 0 then
    core.try(load_workspace)

    local exit = os.exit
    function os.exit(...)
      save_workspace()
      exit(...)
    end
  end

  core.run1 = run1
  return core.run1(...)
end
