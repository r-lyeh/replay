// editor/tab.h - the left tab's host side: selection outlines, inspect, the
// tree's actions (its menu: New, Rename, Duplicate, Delete, Undo), opening a
// node's source. Lite draws the tab itself (the tree, the properties:
// editor/3rd/lite/data/plugins/sidetab.lua; its host functions: editor/side.h).
// Part of replay.c: included once, in order, from there (one compilation unit).

static float g_retina;                             // (replay.c: the display's density)
static bool g_side_focus;                          // a text box of lite's types (plugins/textproxy.lua): the keyboard is lite's
static bool *g_edfocus_p;                          // (replay.c's edfocus: opening a source shows the editor)
static bool g_menu_open;                           // one of lite's popups is open (it has the mouse and keys: replay.c, menus.h)

// the tab's right edge (between it and the editor): dragged sideways, it
// makes the tab (the tree, the properties) wider or narrower (replay.c;
// settings: tab_width, px)
static bool g_edge_hot;                          // the edge under the mouse, or being dragged: drawn bright
static bool g_edge_drag;                         // ... being dragged (replay.c sets it)
static bool tab_edge_at(int h, float x, float y, int tab_w) {   // the edge (+-3 px) under the mouse?
  return tab_w > 0 && y < h && SDL_fabsf(x - tab_w) <= 3;
}
static int tab_width_fit(int want, int win_w) {  // a width that leaves the editor some room
  int hi = win_w - 240;
  if (want > hi) want = hi;
  if (want < 120) want = 120;
  return want;
}

// run viewer_prop_<fn>(w, selection, id, ...) ; extra args already pushed: nargs
static bool prop_call(Viewer *V, const char *fn, const char *id, int nargs) {
  lua_State *L = V->L;
  if (V->world == LUA_NOREF) { lua_pop(L, nargs); return false; }
  int base = lua_gettop(L) - nargs;
  lua_getglobal(L, fn);
  lua_rawgeti(L, LUA_REGISTRYINDEX, V->world);
  push_selection(L, V);
  lua_pushstring(L, id);
  for (int i = 0; i < nargs; i++) lua_pushvalue(L, base + 1 + i);
  if (lua_pcall(L, 3 + nargs, 2, 0) != 0) {
    ov_log(OV_ERROR, "props: %s", lua_tostring(L, -1));
    lua_settop(L, base);
    return false;
  }
  bool ok = true;
  if (lua_isboolean(L, -2) && !lua_toboolean(L, -2)) {
    ov_log(OV_ERROR, "props: %s", lua_tostring(L, -1) ? lua_tostring(L, -1) : "bad value");
    ok = false;
  }
  lua_settop(L, base);
  if (!V->standalone) world_status(V);             // Save / Undo light up right away
  return ok;
}

static bool g_no_dialogs;                        // (tests: scripted events: no questions asked)
static void tree_action(Viewer *V, SDL_Window *win, const char *path, const char *item) {   // the tree's menu: New ..., Rename, Duplicate, Delete
  lua_State *L = V->L;
  if (V->world == LUA_NOREF) return;
  if (!strcmp(item, "Delete") && !g_no_dialogs) {  // asked first (it goes with what's below it)
    char what[700] = "", msg[900];
    lua_getglobal(L, "viewer_tree_delete_what");
    lua_rawgeti(L, LUA_REGISTRYINDEX, V->world);
    lua_pushstring(L, path);
    push_selection(L, V);
    if (lua_pcall(L, 3, 1, 0) == 0 && lua_isstring(L, -1)) SDL_strlcpy(what, lua_tostring(L, -1), sizeof what);
    lua_pop(L, 1);
    SDL_snprintf(msg, sizeof msg, "Delete %s?\n\nNodes stay on disk until you save. Assets' files move to the game's .trash folder at once.\n\nUndo brings it back: the tree's menu, or CTRL+Z over the tree.", what);
    const SDL_MessageBoxButtonData bt[2] = { { SDL_MESSAGEBOX_BUTTON_RETURNKEY_DEFAULT, 1, "Delete" },
                                             { SDL_MESSAGEBOX_BUTTON_ESCAPEKEY_DEFAULT, 0, "Cancel" } };
    SDL_MessageBoxData box = { SDL_MESSAGEBOX_WARNING, win, "Delete", msg, 2, bt, NULL };
    int which = 0;
    if (!SDL_ShowMessageBox(&box, &which) || which != 1) return;
  }
  int base = lua_gettop(L);
  lua_getglobal(L, "viewer_tree_action");
  lua_rawgeti(L, LUA_REGISTRYINDEX, V->world);
  lua_pushstring(L, path);
  lua_pushstring(L, item);
  push_selection(L, V);                            // (right-clicked inside the selection: all of it)
  if (lua_pcall(L, 4, 2, 0) != 0) ov_log(OV_ERROR, "tree: %s", lua_tostring(L, -1));
  else if (lua_isboolean(L, -2) && !lua_toboolean(L, -2)) ov_log(OV_ERROR, "tree: %s", lua_tostring(L, -1) ? lua_tostring(L, -1) : "?");
  else if (lua_toboolean(L, -2) && lua_isstring(L, -1) && !strncmp(lua_tostring(L, -1), "lite:", 5) && editor_running())
    editor_exec(lua_tostring(L, -1) + 5);          // (Open with: the editor opens it: plugins/openwith.lua)
  lua_settop(L, base);
  if (!V->standalone) world_status(V);
}
static void tree_undo(Viewer *V) {                 // CTRL+Z over the tree: the tree's last change, undone
  lua_State *L = V->L;
  if (V->world == LUA_NOREF) return;
  int base = lua_gettop(L);
  lua_getglobal(L, "viewer_tree_undo");
  lua_rawgeti(L, LUA_REGISTRYINDEX, V->world);
  if (lua_pcall(L, 1, 2, 0) != 0) ov_log(OV_ERROR, "undo: %s", lua_tostring(L, -1));
  else if (lua_isboolean(L, -2) && !lua_toboolean(L, -2)) ov_log(OV_INFO, "undo: %s", lua_tostring(L, -1) ? lua_tostring(L, -1) : "?");
  lua_settop(L, base);
  if (!V->standalone) world_status(V);
}

// the tab's frame, drawn by the host: the toolbar's strip (its icons:
// draw_bar), lite's part (the tree, the properties) from its surface, the
// edge you drag
static void draw_tab(Viewer *V, int h, float mx, float my, bool tip, int win_w) {
  (void)mx; (void)my; (void)tip; (void)win_w;
  float tw = (float)V->tab_w;
  ui_color(V->ren, ui.bg2);                        // (lite's side bar)
  SDL_RenderFillRect(V->ren, &(SDL_FRect){ 0, 0, tw, (float)h });
  SDL_Texture *lt = editor_texture();
  SDL_FRect side = { 0, TOOLS_H + 1, tw - 3, (float)h - TOOLS_H - 1 };
  if (lt && side.w > 0 && side.h > 0) {
    SDL_FRect src = { side.x * g_retina, side.y * g_retina, side.w * g_retina, side.h * g_retina };
    SDL_RenderTexture(V->ren, lt, &src, &side);
  }
  ui_color(V->ren, ui.divider);                    // under the toolbar
  SDL_RenderLine(V->ren, 0, TOOLS_H, tw - 1, TOOLS_H);
  ui_color(V->ren, g_edge_drag ? ui.pane_drag : g_edge_hot ? ui.pane_hover : ui.pane);
  SDL_RenderFillRect(V->ren, &(SDL_FRect){ tw - 3, 0, 3, (float)h });
}

// yellow boxes around everything the selected node drew this frame: its own
// parts (a class/asset part shows in every instance), or, for an instance,
// everything drawn through it
static void draw_selection(Viewer *V) {
  if (!V->selected[0]) return;
  SDL_SetRenderDrawColor(V->ren, 255, 220, 60, 255);
  for (int i = 0; i < npicks; i++) {
    if (!is_selected(V, picks[i].path) && !is_selected(V, picks[i].via)) continue;
    if (!picks[i].bounded) { SDL_RenderRect(V->ren, &picks[i].r); continue; }
    for (int q = picks[i].poly0; q < picks[i].poly1; q++) {  // its real (rotated) shape
      const SDL_FPoint *p = &ppts[polys[q].a];
      for (int j = 0, n = polys[q].n; j < n; j++)
        SDL_RenderLine(V->ren, p[j].x, p[j].y, p[(j + 1) % n].x, p[(j + 1) % n].y);
    }
  }
}

// the tree item under the mouse (replay.c sets it on mouse moves): while the
// game runs or is paused and shows (opacity over 0%), what that node draws,
// and its children, outlined in teal
static char g_tree_hover[256];
static void draw_tree_hover(Viewer *V) {
  if (!g_tree_hover[0] || V->stopped || V->fade <= 0.001f) return;
  size_t n = strlen(g_tree_hover);
  SDL_SetRenderDrawColor(V->ren, 60, 200, 200, 255);
  for (int i = 0; i < npicks; i++) {
    const char *p = picks[i].path;
    bool in = p && !strncmp(p, g_tree_hover, n) && (p[n] == 0 || p[n] == '/' || (n == 1 && g_tree_hover[0] == '/'));
    if (!in) continue;
    if (!picks[i].bounded) { SDL_RenderRect(V->ren, &picks[i].r); continue; }
    for (int q = picks[i].poly0; q < picks[i].poly1; q++) {
      const SDL_FPoint *pt = &ppts[polys[q].a];
      for (int j = 0, k = polys[q].n; j < k; j++)
        SDL_RenderLine(V->ren, pt[j].x, pt[j].y, pt[(j + 1) % k].x, pt[(j + 1) % k].y);
    }
  }
}

// click log for the P overlay: the last mouse button events and where they went
#define CLICKLOG 8
static char clicklog[CLICKLOG][160];
static int clicklog_n;
static void clicklog_text(const char *text) {
  SDL_strlcpy(clicklog[clicklog_n++ % CLICKLOG], text, sizeof clicklog[0]);
}
static void clicklog_add(const SDL_Event *raw, const SDL_Event *e, const char *what) {
  char *l = clicklog[clicklog_n++ % CLICKLOG];
  SDL_snprintf(l, sizeof clicklog[0], "%s%s raw %.0f,%.0f px %.0f,%.0f win %u: %s",
               e->button.button == SDL_BUTTON_RIGHT ? "R" : e->button.button == SDL_BUTTON_LEFT ? "L" : "?",
               e->type == SDL_EVENT_MOUSE_BUTTON_DOWN ? "dn" : "up",
               raw->button.x, raw->button.y, e->button.x, e->button.y,
               (unsigned)e->button.windowID, what);
}

// P: debug overlay for picking. Magenta = `bounds` (picked first), cyan =
// boxes of solid shapes, thin cyan lines = outlines (hit within 5 px), crosshair = where
// the game thinks the mouse is (game-area pixels).
static void draw_pick_debug(Viewer *V, float mx, float my) {
  for (int i = 0; i < npicks; i++) {
    SDL_SetRenderDrawColor(V->ren, 255, 60, 255, 220);
    for (int q = picks[i].poly0; q < picks[i].poly1; q++) {
      const SDL_FPoint *p = &ppts[polys[q].a];
      for (int j = 0, n = polys[q].n; j < n; j++)
        SDL_RenderLine(V->ren, p[j].x, p[j].y, p[(j + 1) % n].x, p[(j + 1) % n].y);
    }
    SDL_SetRenderDrawColor(V->ren, 0, 220, 255, 160);
    if (picks[i].solid) SDL_RenderRect(V->ren, &picks[i].r);
    for (int s = picks[i].seg0; s < picks[i].seg1; s++)
      SDL_RenderLine(V->ren, segs[s][0].x, segs[s][0].y, segs[s][1].x, segs[s][1].y);
  }
  SDL_SetRenderDrawColor(V->ren, 255, 60, 60, 255);
  SDL_RenderLine(V->ren, mx - 10, my, mx + 10, my);
  SDL_RenderLine(V->ren, mx, my - 10, mx, my + 10);
  const Pick *k = pick_at(mx, my);
  SDL_RenderDebugText(V->ren, mx + 6, my + 6, !k ? "(nothing)" : k->via[0] ? k->via : k->path);
}

// last clicks, oldest first, bottom-left of the game area (drawn on top,
// not in the game layer, so it stays readable while the editor has focus)

// Open the source of a node in the editor (or the OS default app).
// `note` is shown after the path, e.g. " (instance of /assets/ship)".
static void inspect(Viewer *V, const char *path, const char *note, bool *edfocus) {
  lua_State *L = V->L;
  char p[256], v[256];
  SDL_strlcpy(p, path, sizeof p);
  SDL_strlcpy(v, note ? note : "", sizeof v);
  SDL_strlcpy(V->selected, p, sizeof V->selected);
  SDL_strlcpy(V->via, v, sizeof V->via);
  nsel_more = 0;                                   // a plain inspect selects just this one
  V->reveal = true;
  V->info[0] = 0;
  if (V->world == LUA_NOREF) return;

  lua_getglobal(L, "viewer_source");
  lua_rawgeti(L, LUA_REGISTRYINDEX, V->world);
  lua_pushstring(L, p);
  if (lua_pcall(L, 2, 2, 0) != 0) {
    SDL_snprintf(V->err, sizeof V->err, "inspect: %s", lua_tostring(L, -1));
    lua_pop(L, 1);
    return;
  }
  int list = lua_gettop(L) - 1, n = (int)objlen(L, list), opened = 0;
  const char *where = lua_tostring(L, -1);
  char first[1024] = { 0 };
  int first_line = 1;
  for (int i = n; i >= 1; i--) {                   // last opened = active tab = first file
    lua_rawgeti(L, list, i);
    int e = lua_gettop(L);
    lua_getfield(L, e, "file");
    lua_getfield(L, e, "line");
    const char *file = lua_tostring(L, -2);
    int line = (int)lua_tointeger(L, -1);
    if (file) {
      if (i == 1) { SDL_strlcpy(first, file, sizeof first); first_line = line; }
      if (editor_running() && editor_open(file, line)) opened++;
    }
    lua_settop(L, e - 1);
  }
  if (n == 0) {
    SDL_snprintf(V->info, sizeof V->info, "%s has no components (folder %s)", p, where ? where : "?");
  } else if (editor_running()) {
    SDL_snprintf(V->info, sizeof V->info, "editing %s%s: %s:%d%s", p,
                 v, SDL_strrchr(first, '/') ? SDL_strrchr(first, '/') + 1 : first,
                 first_line, n > 1 ? " (+ more tabs)" : "");
    if (opened && edfocus && V->stopped) { *edfocus = true; editor_focus(true); }   // (playing: the game stays in front)
  } else {                                          // no editor: hand it to the OS
    char url[1100];
    SDL_snprintf(url, sizeof url, "file:///%s", first[0] == '/' ? first + 1 : first);
    for (char *c = url; *c; c++) if (*c == '\\') *c = '/';
    SDL_OpenURL(url);
    SDL_snprintf(V->info, sizeof V->info, "opened %s", first);
  }
  lua_settop(L, list - 1);
  if (!editor_running() || opened || n == 0) return;
  SDL_snprintf(V->err, sizeof V->err, "%s", editor_error());
}

// Open "file:line" (a log entry's origin) in the editor. Code leaves run
// under their node path ("/game/systems/ball:12"): in a world folder that's
// the leaf file; in a script world, the node's source.

// a system row was clicked: open its file (world folder) or the node's source
static void open_system(Viewer *V, const char *comp, bool *edfocus) {
  lua_State *L = V->L;
  int top = lua_gettop(L);
  const char *file = NULL;
  lua_getglobal(L, "viewer_leaf");
  lua_pushstring(L, V->selected);
  lua_pushstring(L, comp);
  if (lua_pcall(L, 2, 1, 0) == 0 && lua_isstring(L, -1)) file = lua_tostring(L, -1);
  if (file && editor_running() && editor_open(file, 1)) {
    if (V->stopped) { *edfocus = true; editor_focus(true); }   // (playing: the game stays in front)
    SDL_snprintf(V->info, sizeof V->info, "editing %s", file);
  } else inspect(V, V->selected, NULL, edfocus);
  lua_settop(L, top);
}
