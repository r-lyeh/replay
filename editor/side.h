// editor/side.h - the left tab's host side: Lite draws the tree and the
// properties (editor/3rd/lite/data/plugins/sidetab.lua) left of its pane;
// what they show and do is the viewer's (runtime/boot.lua, V.L), reached
// from Lite through these (registered in Lite's Lua state):
//   host_world(fn, ...)  -> fn(world, ...) in the viewer's state, values copied over
//   host_tab(cmd, ...)   -> the selection, Save / Undo, opening sources, ... (below)
// Part of replay.c: included once, in order, from there (one compilation unit).

static int g_ctrl_pending;                         // (--events "c...": the next tree click is a CTRL+click)

// a value of one Lua state pushed onto another: nil, booleans, numbers,
// strings and tables of them (no functions, no cycles: 8 levels at most)
static void xcopy(lua_State *from, int idx, lua_State *to, int depth) {
  idx = lua_absindex(from, idx);
  lua_checkstack(to, 4);
  switch (lua_type(from, idx)) {
  case LUA_TBOOLEAN: lua_pushboolean(to, lua_toboolean(from, idx)); break;
  case LUA_TNUMBER:
    if (lua_isinteger(from, idx)) lua_pushinteger(to, lua_tointeger(from, idx));
    else lua_pushnumber(to, lua_tonumber(from, idx));
    break;
  case LUA_TSTRING: { size_t n; const char *s = lua_tolstring(from, idx, &n); lua_pushlstring(to, s, n); break; }
  case LUA_TTABLE:
    if (depth > 8) { lua_pushnil(to); break; }
    lua_newtable(to);
    lua_checkstack(from, 4);
    lua_pushnil(from);
    while (lua_next(from, idx)) {
      int kt = lua_type(from, -2), vt = lua_type(from, -1);
      if ((kt == LUA_TSTRING || kt == LUA_TNUMBER) &&
          (vt == LUA_TBOOLEAN || vt == LUA_TNUMBER || vt == LUA_TSTRING || vt == LUA_TTABLE)) {
        xcopy(from, -2, to, depth + 1);
        xcopy(from, -1, to, depth + 1);
        lua_rawset(to, -3);
      }
      lua_pop(from, 1);
    }
    break;
  default: lua_pushnil(to); break;
  }
}

// host_world(fn, ...): fn(world, ...) in the viewer's state -> its results
static int l_host_world(lua_State *EL) {
  Viewer *V = g_mv;
  const char *fn = luaL_checkstring(EL, 1);
  if (!V || V->world == LUA_NOREF) return 0;
  lua_State *L = V->L;
  int n = lua_gettop(EL), base = lua_gettop(L);
  lua_getglobal(L, fn);
  lua_rawgeti(L, LUA_REGISTRYINDEX, V->world);
  for (int i = 2; i <= n; i++) xcopy(EL, i, L, 0);
  if (lua_pcall(L, n, LUA_MULTRET, 0) != 0) {
    ov_log(OV_ERROR, "%s: %s", fn, lua_tostring(L, -1));
    lua_settop(L, base);
    return 0;
  }
  int got = lua_gettop(L) - base;
  for (int i = 1; i <= got; i++) xcopy(L, base + i, EL, 0);
  lua_settop(L, base);
  if (!strcmp(fn, "viewer_tree_fold") || !strcmp(fn, "viewer_tree_move") || !strcmp(fn, "viewer_system_move")) {
    if (!V->standalone) world_status(V);           // (Save / Undo light up)
  }
  return got;
}

static int side_bool(lua_State *EL, const char *k, bool v) { lua_pushboolean(EL, v); lua_setfield(EL, -2, k); return 0; }

// host_tab(cmd, ...): the host's part of the tab
static int l_host_tab(lua_State *EL) {
  Viewer *V = g_mv;
  const char *cmd = luaL_checkstring(EL, 1);
  if (!V) return 0;
  lua_State *L = V->L;
  bool dummy = false, *edfocus = g_edfocus_p ? g_edfocus_p : &dummy;
  if (!strcmp(cmd, "state")) {                     // what it shows: the selection, the session
    if (V->world != LUA_NOREF && !V->stopped) prof_select(V);   // (the profiler's costs: live, or the frame shown)
    lua_createtable(EL, 0, 16);
    lua_pushstring(EL, V->selected); lua_setfield(EL, -2, "selected");
    lua_createtable(EL, nsel_more + 1, 0);
    int k = 0;
    if (V->selected[0]) { lua_pushstring(EL, V->selected); lua_rawseti(EL, -2, ++k); }
    for (int i = 0; i < nsel_more; i++) { lua_pushstring(EL, sel_more[i]); lua_rawseti(EL, -2, ++k); }
    lua_setfield(EL, -2, "sel");
    lua_pushinteger(EL, k); lua_setfield(EL, -2, "nsel");
    side_bool(EL, "world", V->world != LUA_NOREF);
    side_bool(EL, "stopped", V->stopped);
    side_bool(EL, "paused", V->paused);
    side_bool(EL, "savable", V->savable);
    side_bool(EL, "sel_dirty", V->sel_dirty);
    side_bool(EL, "script", V->script);
    side_bool(EL, "reveal", V->reveal);
    lua_pushstring(EL, V->opath); lua_setfield(EL, -2, "opath");
    lua_pushinteger(EL, settings_thumbs()); lua_setfield(EL, -2, "thumbs");
    lua_pushinteger(EL, settings_tree_split()); lua_setfield(EL, -2, "split");
    return 1;
  }
  if (!strcmp(cmd, "revealed")) { V->reveal = false; return 0; }
  if (!strcmp(cmd, "inspect")) { inspect(V, luaL_checkstring(EL, 2), NULL, edfocus); return 0; }   // select it, open its source
  if (!strcmp(cmd, "toggle")) { sel_toggle(V, luaL_checkstring(EL, 2)); if (!V->standalone) world_status(V); return 0; }
  if (!strcmp(cmd, "take_ctrl")) { bool c = g_ctrl_pending > 0; if (c) g_ctrl_pending--; lua_pushboolean(EL, c); return 1; }
  if (!strcmp(cmd, "save")) { sel_action(V, "viewer_sel_save", "saved"); return 0; }
  if (!strcmp(cmd, "undo")) { sel_action(V, "viewer_sel_undo", "undid changes to"); return 0; }
  if (!strcmp(cmd, "tree_action")) {
    SDL_Window *win = g_mwin;
    tree_action(V, win, luaL_checkstring(EL, 2), luaL_checkstring(EL, 3));
    return 0;
  }
  if (!strcmp(cmd, "open_system")) { open_system(V, luaL_checkstring(EL, 2), edfocus); return 0; }
  if (!strcmp(cmd, "action")) {                    // an action row: open a file here, or run a line in the editor
    const char *a = luaL_checkstring(EL, 2);
    if (!strncmp(a, "open:", 5) && editor_running()) editor_open(a + 5, 1);
    else if (!strncmp(a, "lite:", 5) && editor_running()) editor_exec(a + 5);
    return 0;
  }
  if (!strcmp(cmd, "prop")) {                      // viewer_prop_<fn>(w, selection, id, ...) -> ok
    const char *fn = luaL_checkstring(EL, 2), *id = luaL_checkstring(EL, 3);
    int n = lua_gettop(EL);
    for (int i = 4; i <= n; i++) xcopy(EL, i, L, 0);
    lua_pushboolean(EL, prop_call(V, fn, id, n - 3));
    return 1;
  }
  if (!strcmp(cmd, "take_rename")) {               // a field just added: its row, to type its name now
    lua_getglobal(L, "viewer_rename");
    if (lua_isstring(L, -1)) {
      lua_pushstring(EL, lua_tostring(L, -1));
      lua_pop(L, 1);
      lua_pushnil(L); lua_setglobal(L, "viewer_rename");
      return 1;
    }
    lua_pop(L, 1);
    return 0;
  }
  if (!strcmp(cmd, "naming_cancel")) { lua_pushnil(L); lua_setglobal(L, "viewer_naming"); return 0; }
  if (!strcmp(cmd, "asset_file")) {                // an /assets node's file (a thumbnail)
    lua_getglobal(L, "viewer_asset_files");
    if (lua_istable(L, -1)) {
      lua_getfield(L, -1, luaL_checkstring(EL, 2));
      if (lua_isstring(L, -1)) { lua_pushstring(EL, lua_tostring(L, -1)); lua_pop(L, 2); return 1; }
      lua_pop(L, 1);
    }
    lua_pop(L, 1);
    return 0;
  }
  if (!strcmp(cmd, "prof")) {                      // the profiler: each path's ms a tick
    luaL_checktype(EL, 2, LUA_TTABLE);
    int n = (int)lua_rawlen(EL, 2);
    lua_createtable(EL, n, 0);
    for (int i = 1; i <= n; i++) {
      lua_rawgeti(EL, 2, i);
      const char *p = lua_tostring(EL, -1);
      double ms = p ? prof_ms(V, p) : 0;
      lua_pop(EL, 1);
      lua_pushnumber(EL, ms);
      lua_rawseti(EL, -2, i);
    }
    return 1;
  }
  if (!strcmp(cmd, "hover")) {                     // the tree row under the mouse: outlined in the game
    SDL_strlcpy(g_tree_hover, luaL_checkstring(EL, 2), sizeof g_tree_hover);
    return 0;
  }
  if (!strcmp(cmd, "split")) {                     // the line between the tree and the properties: a %; true: save it, false: its default
    if (lua_isnumber(EL, 2)) {
      int pct = (int)lua_tointeger(EL, 2);
      g_settings.tree_split = pct < 10 ? 10 : pct > 90 ? 90 : pct;
    } else if (lua_isboolean(EL, 2) && !lua_toboolean(EL, 2)) {
      g_settings.tree_split = SET_NONE;
      if (editor_running()) settings_save();
    } else if (editor_running()) settings_save();
    return 0;
  }
  if (!strcmp(cmd, "font")) {                      // CTRL+wheel over it: its font larger / smaller, a px a step; saved
    int steps = (int)luaL_optinteger(EL, 2, 0);
    int px = (g_settings.tab_font == SET_NONE ? 14 : g_settings.tab_font) + steps;   // (unset: lite's UI font, 14 px)
    g_settings.tab_font = px < 8 ? 8 : px > 32 ? 32 : px;
    editor_ui_font(g_settings.tab_font);
    settings_save();
    return 0;
  }
  if (!strcmp(cmd, "changed")) { if (!V->standalone) world_status(V); return 0; }
  return 0;
}

static void side_init(void) {                      // (after lite starts)
  lua_State *EL = editor_lua();
  if (!EL) return;
  lua_pushglobaltable(EL);                         // (rawset: lite's globals are strict)
  lua_pushstring(EL, "host_world"); lua_pushcfunction(EL, l_host_world); lua_rawset(EL, -3);
  lua_pushstring(EL, "host_tab"); lua_pushcfunction(EL, l_host_tab); lua_rawset(EL, -3);
  lua_pop(EL, 1);
}
