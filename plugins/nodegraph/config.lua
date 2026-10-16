-- config.lua: the node graph's settings (the tree: /plugins/nodegraph:
-- config; or its menu's "Plugin: nodegraph > Settings"). Saved, they apply
-- at once to every open graph.
return {
  grid = 24,             -- the layout snaps to it, graph units (0: no snapping)
  rebuild_delay = 0.2,   -- typing in the text: the graph is rebuilt once it pauses this long (s)
  flow = "#ff9a2e",      -- the flow that ran (values on wires): its colour
  flow_fade = 0.6,       -- ... and how long it takes to fade back to white (s)
  far_zoom = 0.3,        -- zoomed out under this, nodes are plain boxes (no text)
  zoom_max = 3,          -- the most it zooms in (1: 100%)
  headers = {            -- a node's header colour, per kind
    ["function"] = "#2f5b5b", ["local"] = "#246283", set = "#7a4a1f", call = "#3c3c83",
    branch = "#83314a", loop = "#6a5a20", ["return"] = "#5a2d5a", expr = "#3f5a3a",
    table = "#2e5470", start = "#8a2b2b",
  },
}
