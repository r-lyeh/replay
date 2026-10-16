// editor/tab.h - the left tab: tree, property editor, selection outlines, inspect.
// Part of play.c: included once, in order, from there (one compilation unit).

// row drag & drop state (see the end of this file)
enum { RDRAG_NONE, RDRAG_TREE, RDRAG_SYSTEM };
static struct {
  int kind;
  char path[256];                  // tree: the node; system: its node
  char comp[64];                   // system: its component name
  float y0;
  bool moving;
  char target[256];                // drop next to this (tree path / system name), "" = nowhere
  bool after;
} rdrag;

// the drop marker: a line between rows
static void rdrag_draw(SDL_Renderer *r, float x0, float x1, float rowy) {
  float y = rowy + (rdrag.after ? TAB_ROW - 1 : -1);
  ui_color(r, ui.caret);
  SDL_FRect m = { x0, y - 1, x1 - x0, 2 };
  SDL_RenderFillRect(r, &m);
}

// ---------------------------------------------------------------------------
// property editor (bottom half of the tab): the selection's components.
// Numbers: drag sideways to scrub (Shift x10, Ctrl x0.1), click to type.
// Booleans: click toggles. Text and tables: click to type (a Lua literal).
// Drop-downs (a member's type / kind, a value's options, a member's menu):
// click, then pick from the list (see pick below).
// Code: click opens it in the editor. Several nodes selected: the first one
// gives the rows, "--" marks values that differ, edits apply to all.
// ---------------------------------------------------------------------------

#define PROP_MAX 512
typedef struct {
  char id[160]; char label[48]; char text[256]; char kind; Uint8 depth; bool mixed, over;
  char cls;                        // its class (/classes/<component>): 'i' inherited (the node lacks it), 'd' differs, 0
  char def[256];                   // ... the class's value (+ member / + class: the types / classes)
  bool range, rint;                // its member's min..max: a slider (rint: whole numbers)
  double lo, hi;
  char opts[600];                  // a drop-down's items, '|'-separated (kinds p, h; M: its types)
  char tip[200];                   // its tooltip (from the viewer's Lua), or ""
  char ktext[48], kopts[600];      // a member's row (M): its kind ("single", "map:int"), the kinds' list
} PropRow;
static struct {
  PropRow rows[PROP_MAX];
  int n, scroll, vis;              // rows, first visible, how many fit
  float y0;                        // y of the first visible row
  bool press, scrub;               // number row: mouse down / dragging
  bool slide;                      // ... a slider (its class gives a range): the mouse sets it
  float vx, vw;                    // the value column: x, width (set while drawing)
  char press_id[160];
  float press_x;
  double base, sent;               // scrub step per pixel, amount applied so far
  bool isint;
  bool editing;                    // typing a value
  int clicks;                      // the click's count (2: a double-click), set before prop_click
  char edit_id[160], edit_kind;
  LineEd e;
  Uint64 blink;
  SDL_FRect save_r, undo_r;        // header text buttons (set while drawing)
} prop;

// the line between the tree and the properties: a share of the tab's height
// (settings: tree_split, %), dragged with the mouse (play.c); each part
// keeps some room whatever the share or the window's size
static float tab_split(int h) {
  float y = SDL_floorf(h * settings_tree_split() / 100.f);
  float lo = TREE_TOP + 3 * TAB_ROW, hi = h - 6 * TAB_ROW;
  if (y > hi) y = hi;
  if (y < lo) y = lo;
  return y;
}
#define TAB_PAD 12                               // the tab's left margin, px (lite: style.padding.x 14)
static bool g_split_hot;                         // the line under the mouse, or being dragged: drawn bright
static bool g_split_drag, g_edge_drag;           // ... being dragged (play.c sets them)
static Scroll g_sb_tree, g_sb_props;             // their scrollbars (set while drawing)
static bool tab_split_at(int h, float x, float y, int tab_w) {   // the line (+-3 px) under the mouse?
  return x < tab_w && SDL_fabsf(y - tab_split(h)) <= 3;
}
// the tab's right edge (between it and the editor): dragged sideways, it
// makes the tab (the tree, the properties) wider or narrower (play.c;
// settings: tab_width, px)
static bool g_edge_hot;                          // the edge under the mouse, or being dragged: drawn bright
static bool tab_edge_at(int h, float x, float y, int tab_w) {   // the edge (+-3 px) under the mouse?
  return tab_w > 0 && y < h && SDL_fabsf(x - tab_w) <= 3;
}
static int tab_width_fit(int want, int win_w) {  // a width that leaves the editor some room
  int hi = win_w - 240;
  if (want > hi) want = hi;
  if (want < 120) want = 120;
  return want;
}

static void prop_fetch(Viewer *V) {
  prop.n = 0;
  lua_State *L = V->L;
  if (V->world == LUA_NOREF || !V->selected[0]) return;
  lua_getglobal(L, "viewer_props");
  lua_rawgeti(L, LUA_REGISTRYINDEX, V->world);
  push_selection(L, V);
  if (lua_pcall(L, 2, 1, 0) != 0) { lua_pop(L, 1); return; }
  int n = (int)objlen(L, -1);
  for (int i = 1; i <= n && prop.n < PROP_MAX; i++) {
    lua_rawgeti(L, -1, i);
    PropRow *r = &prop.rows[prop.n++];
    const char *f[4];
    for (int j = 0; j < 4; j++) { lua_rawgeti(L, -1 - j, j + 1); f[j] = lua_tostring(L, -1); }
    SDL_strlcpy(r->id, f[0] ? f[0] : "", sizeof r->id);
    SDL_strlcpy(r->label, f[1] ? f[1] : "?", sizeof r->label);
    SDL_strlcpy(r->text, f[2] ? f[2] : "", sizeof r->text);
    const char *k = f[3] ? f[3] : "lit";
    r->kind = !strcmp(k, "num") ? 'n' : !strcmp(k, "bool") ? 'b' : !strcmp(k, "str") ? 's' :
              !strcmp(k, "code") ? 'c' : !strcmp(k, "table") ? 't' : !strcmp(k, "info") ? 'i' :
              !strcmp(k, "color") ? 'k' : !strcmp(k, "choice") ? 'h' : !strcmp(k, "add") ? 'a' :
              !strcmp(k, "member") ? 'm' : !strcmp(k, "pick") ? 'p' : !strcmp(k, "member_row") ? 'M' :
              !strcmp(k, "action") ? 'A' : 'l';   // (A: a link that does something: opts "open:<file>" / "lite:<code>")
    lua_pop(L, 4);
    lua_rawgeti(L, -1, 5); r->depth = (Uint8)lua_tointeger(L, -1); lua_pop(L, 1);
    lua_rawgeti(L, -1, 6); r->mixed = lua_toboolean(L, -1); lua_pop(L, 1);
    lua_rawgeti(L, -1, 7); r->over = lua_toboolean(L, -1); lua_pop(L, 1);
    lua_rawgeti(L, -1, 8); r->cls = lua_isstring(L, -1) ? lua_tostring(L, -1)[0] : 0; lua_pop(L, 1);
    lua_rawgeti(L, -1, 9); SDL_strlcpy(r->def, lua_isstring(L, -1) ? lua_tostring(L, -1) : "", sizeof r->def); lua_pop(L, 1);
    lua_rawgeti(L, -1, 10);                        // its type: "range lo hi int" / "choice" / "color"
    int ri = 0;
    r->range = lua_isstring(L, -1) && sscanf(lua_tostring(L, -1), "range %lf %lf %d", &r->lo, &r->hi, &ri) == 3;
    r->rint = ri != 0;
    lua_pop(L, 1);
    lua_rawgeti(L, -1, 11); SDL_strlcpy(r->opts, lua_isstring(L, -1) ? lua_tostring(L, -1) : "", sizeof r->opts); lua_pop(L, 1);
    lua_rawgeti(L, -1, 12); SDL_strlcpy(r->tip, lua_isstring(L, -1) ? lua_tostring(L, -1) : "", sizeof r->tip); lua_pop(L, 1);
    lua_rawgeti(L, -1, 13); SDL_strlcpy(r->ktext, lua_isstring(L, -1) ? lua_tostring(L, -1) : "", sizeof r->ktext); lua_pop(L, 1);
    lua_rawgeti(L, -1, 14); SDL_strlcpy(r->kopts, lua_isstring(L, -1) ? lua_tostring(L, -1) : "", sizeof r->kopts); lua_pop(L, 1);
    lua_pop(L, 1);
  }
  lua_pop(L, 1);
}

static int prop_row_at(float y) {
  if (y < prop.y0) return -1;
  int i = (int)((y - prop.y0) / TAB_ROW);
  if (i < 0 || i >= prop.vis) return -1;
  i += prop.scroll;
  return i < prop.n ? i : -1;
}

static int prop_find(const char *id) {
  for (int i = 0; i < prop.n; i++) if (!strcmp(prop.rows[i].id, id)) return i;
  return -1;
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

static void prop_text_input(SDL_Window *win, bool on, bool edfocus) {
  if (on) SDL_StartTextInput(win);
  else if (!edfocus) SDL_StopTextInput(win);
}

static void prop_begin_edit(SDL_Window *win, int row) {
  PropRow *r = &prop.rows[row];
  prop.editing = true;
  SDL_strlcpy(prop.edit_id, r->id, sizeof prop.edit_id);
  prop.edit_kind = r->kind;
  le_set(&prop.e, r->kind == 'p' || r->kind == 'M' ? r->label : r->mixed || r->kind == 'm' ? "" : r->text);   // (p: a rename; m: + member / + class, typed from nothing)
  le_select_all(&prop.e);                          // typing replaces it; arrows keep it
  prop.blink = SDL_GetTicks();
  prop_text_input(win, true, false);
}

static void prop_end_edit(Viewer *V, SDL_Window *win, bool commit, bool edfocus) {
  if (!prop.editing) return;
  prop.editing = false;
  if (!commit && !strcmp(prop.edit_id, "return { \"?name\" }")) {   // (renaming a node: ESC keeps its name, the row goes)
    lua_pushnil(V->L); lua_setglobal(V->L, "viewer_naming");
  }
  if (commit) {
    lua_pushstring(V->L, prop.e.s);
    lua_pushstring(V->L, prop.edit_kind == 's' ? "str" : "lit");
    prop_call(V, "viewer_prop_set", prop.edit_id, 2);
  }
  prop_text_input(win, false, edfocus);
}

// keyboard while typing a value
static void prop_event(Viewer *V, SDL_Window *win, const SDL_Event *e, bool edfocus) {
  prop.blink = SDL_GetTicks();
  if (e->type == SDL_EVENT_TEXT_INPUT) { le_insert(&prop.e, e->text.text); return; }
  if (e->type != SDL_EVENT_KEY_DOWN) return;
  bool ctrl = (e->key.mod & SDL_KMOD_CTRL) != 0;
  switch (e->key.key) {
  case SDLK_RETURN: case SDLK_KP_ENTER: prop_end_edit(V, win, true, edfocus); return;
  case SDLK_ESCAPE: prop_end_edit(V, win, false, edfocus); return;
  case SDLK_TAB: {                                 // commit, then type the next value
    char id[160];
    SDL_strlcpy(id, prop.edit_id, sizeof id);
    prop_end_edit(V, win, true, edfocus);
    int i = prop_find(id);
    for (int j = i + 1; i >= 0 && j < prop.n; j++)
      if (strchr("nsl", prop.rows[j].kind)) { prop_begin_edit(win, j); break; }
    return;
  }
  }
  le_key(&prop.e, e->key.key, ctrl);
}

// a slider (its class gives the field a range): the value where the mouse is
static void prop_slide(Viewer *V, float x) {
  float f = prop.vw > 0 ? (x - prop.vx) / prop.vw : 0;
  lua_pushnumber(V->L, f < 0 ? 0 : f > 1 ? 1 : f);
  prop_call(V, "viewer_prop_slide", prop.press_id, 1);
}

// ---------------------------------------------------------------------------
// pick: a drop-down list under a row (kinds p and h: its opts; a member's
// row: its type, its kind, or its menu). An item with a sub-list
// ("map>bool,int,...") opens it beside the list when hovered or clicked
// (or Right / Enter on it; Left goes back). A click on an item:
// viewer_prop_pick(w, selection, id, item, which) (a sub-item: "map:<it>";
// Rename: type the new name instead); a click anywhere else, or ESC,
// closes it. Drawn over everything (play.c: draw_pick); the item that's
// the current value is marked.
// Typing filters the list (the sub-list while it's open): any part of a
// name, any case; a search line on top (always for a list of values, an
// enum's options or a type, and for more than PICK_SEARCH items; a short
// menu: once typed). Up / Down / PageUp / PageDown move, Enter picks,
// Backspace takes a letter back (play.c: pick_key). A list taller than the
// window scrolls: the wheel, its scrollbar, the keys.
// ---------------------------------------------------------------------------
#define PROP_PICK_MAX 48
#define PICK_IH (TAB_ROW + 6)
#define PICK_SEARCH 6                              // more items than this: the search line shows at once
typedef struct {
  int n;
  char item[PROP_PICK_MAX][48];
  char filter[48];                 // typed: the items shown are those with it in their name
  int vis[PROP_PICK_MAX], nvis;    // the items shown (indices), in order
  int cursor;                      // the keyboard's item (in vis)
  int top, rows;                   // the first shown (in vis), how many fit
  float x, y, w;                   // its box
  Scroll sb;                       // (set while drawing)
} PickList;
static struct {
  bool open;
  char id[160], cur[64], which[8];
  PickList m, s;                   // the list, and its sub-list
  int subof;                       // the item with a sub-list (-1: none)
  bool sub_open;
  bool keyed;                      // the keyboard moved: its item drawn
  bool search;                     // a list of values (an enum's options, a type): its search line always
  float below_y, above_y;          // where it opened (it re-lays out as it filters)
  int win_h;
} pick;

static bool pl_searching(const PickList *l) { return l->n > PICK_SEARCH || l->filter[0] || (pick.search && l == &pick.m); }
static float pl_top(const PickList *l) { return l->y + 3 + (pl_searching(l) ? PICK_IH : 0); }   // its first item's top
static float pl_height(const PickList *l, int rows) { return (rows ? rows : 1) * PICK_IH + 6 + (pl_searching(l) ? PICK_IH : 0); }
static void pl_filter(PickList *l) {
  l->nvis = 0;
  for (int i = 0; i < l->n; i++)
    if (!l->filter[0] || SDL_strcasestr(l->item[i], l->filter)) l->vis[l->nvis++] = i;
  if (l->cursor >= l->nvis) l->cursor = l->nvis - 1;
  if (l->cursor < 0) l->cursor = 0;
}
static void pl_fit(PickList *l, float room) {      // as many rows as fit in room px (1 at least)
  int r = (int)((room - pl_height(l, 0) + PICK_IH) / PICK_IH);
  l->rows = SDL_max(1, SDL_min(l->nvis, r));
}
static void pl_clamp(PickList *l) {
  if (l->top > l->nvis - l->rows) l->top = l->nvis - l->rows;
  if (l->top < 0) l->top = 0;
}
static void pl_show_cursor(PickList *l) {          // scrolled so the keyboard's item shows
  if (l->cursor < l->top) l->top = l->cursor;
  if (l->cursor >= l->top + l->rows) l->top = l->cursor - l->rows + 1;
  pl_clamp(l);
}
static int pl_at(const PickList *l, float mx, float my) {   // -> an item's index (not the search line's), or -1
  float top = pl_top(l);
  if (mx < l->x || mx >= l->x + l->w || my < top) return -1;
  int k = (int)((my - top) / PICK_IH);
  return k >= 0 && k < l->rows && l->top + k < l->nvis ? l->vis[l->top + k] : -1;
}
static bool pl_in(const PickList *l, float mx, float my) {
  return mx >= l->x && mx < l->x + l->w && my >= l->y && my < l->y + pl_height(l, l->rows);
}

// what's shown (the filters), where (down from below_y, or up from above_y
// when there's no room; too long for either: the roomier, scrolling), the
// sub-list by its item, kept in the window
static void pick_layout(void) {
  PickList *m = &pick.m, *s = &pick.s;
  pl_filter(m);
  float below = pick.win_h - 2 - pick.below_y, above = pick.above_y - 2, full = pl_height(m, m->nvis);
  m->rows = m->nvis;
  if (full <= below) m->y = pick.below_y;
  else if (full <= above) m->y = pick.above_y - full;
  else if (below >= above) { pl_fit(m, below); m->y = pick.below_y; }
  else { pl_fit(m, above); m->y = pick.above_y - pl_height(m, m->rows); }
  if (m->y < 2) m->y = 2;
  pl_clamp(m);
  int at = -1;
  for (int k = m->top; k < m->top + m->rows && k < m->nvis; k++) if (m->vis[k] == pick.subof) at = k;
  if (at < 0) { pick.sub_open = false; return; }
  pl_filter(s);
  s->rows = s->nvis;
  if (pl_height(s, s->rows) > pick.win_h - 4) pl_fit(s, pick.win_h - 4.f);
  pl_clamp(s);
  float sh = pl_height(s, s->rows);
  s->x = m->x + m->w - 2;
  s->y = pl_top(m) - 3 + (at - m->top) * PICK_IH;
  if (s->y + sh > pick.win_h - 2) s->y = pick.win_h - 2 - sh;
  if (s->y < 2) s->y = 2;
}
static void pick_sub_show(bool on) {               // the sub-list opens (afresh) / closes
  if (on && !pick.sub_open) { pick.s.filter[0] = 0; pick.s.cursor = pick.s.top = 0; }
  pick.sub_open = on;
  pick_layout();
}
static float pl_parse(PickList *l, const char *s, size_t len, char sep) {   // its items -> the widest, px
  float w = ui_w("------");
  for (const char *t = s; t < s + len && l->n < PROP_PICK_MAX; ) {
    const char *c = memchr(t, sep, (size_t)(s + len - t));
    size_t il = c ? (size_t)(c - t) : (size_t)(s + len - t);
    const char *gt = sep == '|' ? memchr(t, '>', il) : NULL;
    size_t nl = gt ? (size_t)(gt - t) : il;
    if (nl >= sizeof l->item[0]) nl = sizeof l->item[0] - 1;
    memcpy(l->item[l->n], t, nl); l->item[l->n][nl] = 0;
    if (gt && pick.subof < 0) {                    // its sub-list (one per list)
      pick.subof = l->n;
      pick.s.w = pl_parse(&pick.s, gt + 1, il - nl - 1, ',');
    }
    float iw = ui_w(l->item[l->n]) + (gt ? ui_w("  >") : 0);
    if (iw > w) w = iw;
    l->n++;
    if (!c) break;
    t = c + 1;
  }
  if ((l->n > PICK_SEARCH || (pick.search && l == &pick.m)) && w < ui_w("type to filter__")) w = ui_w("type to filter__");   // (room for what's typed)
  return SDL_ceilf(w + ui_w("> ") + 12 + SCROLL_W + 2);
}
// items: "a|b|c>x,y,z" (c: a sub-list x, y, z); cur: the value now (marked);
// id: what it's for (a row's id; the tree's menu: a node's path); the list
// opens down from below_y, or (no room) up from above_y
static void pick_open_at(Viewer *V, const char *id, const char *items, const char *cur, float x, float below_y, float above_y,
                         const char *which, int win_h) {
  SDL_zero(pick.m); SDL_zero(pick.s);
  pick.subof = -1;
  pick.sub_open = false;
  pick.search = !which || !which[0] || !strcmp(which, "type");   // (values: searchable; menus: Rename / Remove, the kinds, the tree's)
  pick.m.w = pl_parse(&pick.m, items, strlen(items), '|');
  if (!pick.m.n) return;
  SDL_strlcpy(pick.id, id, sizeof pick.id);
  SDL_strlcpy(pick.cur, cur ? cur : "", sizeof pick.cur);
  SDL_strlcpy(pick.which, which ? which : "", sizeof pick.which);
  pick.m.x = x - 4;
  if (pick.m.x + pick.m.w > V->tab_w - 2 && V->tab_w - 2 - pick.m.w > 2) pick.m.x = V->tab_w - 2 - pick.m.w;
  pick.keyed = false;
  pick.below_y = below_y; pick.above_y = above_y; pick.win_h = win_h;
  pick.open = true;
  pick_layout();
  SDL_Window *kw = SDL_GetKeyboardFocus();          // (typing filters it)
  if (kw) SDL_StartTextInput(kw);
}
static void pick_open_list(Viewer *V, int row, const char *items, const char *cur, float x, const char *which, int win_h) {   // under a row
  float rowy = prop.y0 + (row - prop.scroll) * TAB_ROW;
  pick_open_at(V, prop.rows[row].id, items, cur, x, rowy + TAB_ROW, rowy - 2, which, win_h);
}
static void pick_open(Viewer *V, int row, int win_h) {   // a row's own list (kinds p, h)
  PropRow *r = &prop.rows[row];
  pick_open_list(V, row, r->opts, r->kind == 'p' && r->depth == 0 ? "" : r->text, prop.vx, "", win_h);
}

static int pick_item_at(float mx, float my) { return pick.open ? pl_at(&pick.m, mx, my) : -1; }
static int pick_sub_at(float mx, float my) { return pick.open && pick.sub_open ? pl_at(&pick.s, mx, my) : -1; }
static void pick_hover(float mx, float my) {       // the mouse over the list: the sub-list opens / closes
  if (!pick.open || pick.subof < 0 || pick_sub_at(mx, my) >= 0) return;
  if (pick.sub_open && pl_in(&pick.s, mx, my)) return;   // (its search line, its scrollbar)
  int i = pick_item_at(mx, my);
  if (i >= 0) pick_sub_show(i == pick.subof);
}
// the wheel over a list: it scrolls (3 rows a step)
static void pick_wheel(float mx, float my, int rows) {
  PickList *l = pick.sub_open && pl_in(&pick.s, mx, my) ? &pick.s : pl_in(&pick.m, mx, my) ? &pick.m : NULL;
  if (!l) return;
  l->top += rows;
  pl_clamp(l);
  if (l == &pick.m) pick_layout();                 // (its sub-list follows its item)
}
// a press on a list's scrollbar: dragging it -> true
static bool pick_scroll_press(float mx, float my) {
  PickList *l = pick.sub_open && scroll_hit(&pick.s.sb, mx, my) ? &pick.s : scroll_hit(&pick.m.sb, mx, my) ? &pick.m : NULL;
  if (!l) return false;
  sbdrag.which = l == &pick.s ? DRAG_SB_PICK_SUB : DRAG_SB_PICK;
  sbdrag.grab = scroll_press(&l->sb, my, &l->top);
  if (l == &pick.m) pick_layout();
  return true;
}
static void pick_scroll_drag(float my) {
  PickList *l = sbdrag.which == DRAG_SB_PICK_SUB ? &pick.s : &pick.m;
  l->top = scroll_first_at(&l->sb, my, sbdrag.grab);
  if (l == &pick.m) pick_layout();
}

static void prop_begin_edit(SDL_Window *win, int row);
static void pick_send(Viewer *V, const char *item) {
  lua_pushstring(V->L, item);
  lua_pushstring(V->L, pick.which);
  prop_call(V, "viewer_prop_pick", pick.id, 2);
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
static void pick_do(Viewer *V, SDL_Window *win, int i) {   // an item picked (one with a sub-list: opens it)
  if (!strcmp(pick.which, "tree")) {               // (the tree's menu: a node's path)
    pick.open = false;
    if (i >= 0 && i < pick.m.n) tree_action(V, win, pick.id, pick.m.item[i]);
    return;
  }
  int row = prop_find(pick.id);
  if (row < 0 || i < 0 || i >= pick.m.n) { pick.open = false; return; }
  if (i == pick.subof) { pick_sub_show(true); return; }
  pick.open = false;
  if (!strcmp(pick.m.item[i], "Rename")) { prop_begin_edit(win, row); return; }
  pick_send(V, pick.m.item[i]);
}
static void pick_sub_do(Viewer *V, int j) {        // a sub-list's item: "<its item>:<it>"
  char item[100];
  SDL_snprintf(item, sizeof item, "%s:%s", pick.m.item[pick.subof], pick.s.item[j]);
  pick.open = false;
  pick_send(V, item);
}

// a list: hot / key: the mouse's and the keyboard's item (indices, -1:
// none), cur: the one marked, parent: the item with a sub-list ('>' at its
// right); a search line on top while searching; its scrollbar over it
static void pick_draw_list(SDL_Renderer *r, PickList *l, int hot, int key, const char *cur, int parent, float mx, float my) {
  float x = l->x, y = l->y, w = l->w;
  SDL_FRect box = { x, y, w, pl_height(l, l->rows) };
  SDL_SetRenderDrawColor(r, 0, 0, 0, 90);         // a shadow, then the box (lite's popups: background3)
  SDL_FRect sh = { box.x + 2, box.y + 3, box.w, box.h };
  SDL_RenderFillRect(r, &sh);
  ui_color(r, ui.bg3);
  SDL_RenderFillRect(r, &box);
  ui_color(r, ui.line);
  SDL_RenderRect(r, &box);
  if (pl_searching(l)) {                           // the search line: what's typed, a caret (or how to)
    float sy = y + 3;
    SDL_FRect f = { x + 3, sy + 1, w - 6, PICK_IH - 2 };
    ui_color(r, ui.bg);
    SDL_RenderFillRect(r, &f);
    bool caret = (SDL_GetTicks() / 530) % 2 == 0;
    if (l->filter[0]) {
      ui_color(r, ui.accent);
      float ex = ui_text_in(r, x + 8, sy, PICK_IH, l->filter);
      SDL_FRect c = { ex + 1, sy + 3, g_lite_font ? 2 : 1, PICK_IH - 6 };
      ui_color(r, ui.caret);
      if (caret) SDL_RenderFillRect(r, &c);
    } else { ui_color(r, ui.dim); ui_text_in(r, x + 8, sy, PICK_IH, "type to filter"); }
    if (l->nvis == 0) { ui_color(r, ui.dim); ui_text_in(r, x + 8, sy + PICK_IH, PICK_IH, "(none)"); }
  }
  float top = pl_top(l);
  for (int k = 0; k < l->rows && l->top + k < l->nvis; k++) {
    int i = l->vis[l->top + k];
    float iy = top + k * PICK_IH;
    if (i == hot || i == key) {
      SDL_FRect hl = { x + 2, iy, w - 4, PICK_IH };
      ui_color(r, i == hot ? ui.selection : ui.hilite);
      SDL_RenderFillRect(r, &hl);
    }
    bool on = cur && cur[0] && !strcmp(l->item[i], cur);
    ui_color(r, on ? ui.caret : i == hot || i == key ? ui.accent : ui.text);
    if (on) ui_text_in(r, x + 5, iy, PICK_IH, ">");
    ui_text_in(r, x + 5 + ui_w("> "), iy, PICK_IH, l->item[i]);
    if (i == parent) ui_text_in(r, x + w - 8 - SCROLL_W - ui_w(">"), iy, PICK_IH, ">");
  }
  l->sb = (Scroll){ x + w - 2, top, l->rows * PICK_IH, l->nvis, l->rows, l->top };
  bool which = sbdrag.which == (l == &pick.s ? DRAG_SB_PICK_SUB : DRAG_SB_PICK);
  scroll_draw(r, &l->sb, which || scroll_hit(&l->sb, mx, my));
}
static void draw_pick(Viewer *V, float mx, float my) {
  if (!pick.open) return;
  char cur[64], subcur[64] = "";                   // "map:int": map marked, int in its sub-list
  SDL_strlcpy(cur, pick.cur, sizeof cur);
  char *colon = strchr(cur, ':');
  if (colon) { SDL_strlcpy(subcur, colon + 1, sizeof subcur); *colon = 0; }
  int hot = pick_item_at(mx, my);
  if (pick.sub_open && hot < 0) hot = pick.subof;
  int key = !pick.sub_open && (pick.keyed || pick.m.filter[0]) && pick.m.nvis > 0 ? pick.m.vis[pick.m.cursor] : -1;
  pick_draw_list(V->ren, &pick.m, hot, key, cur, pick.subof, mx, my);
  if (pick.sub_open) {
    int skey = (pick.keyed || pick.s.filter[0]) && pick.s.nvis > 0 ? pick.s.vis[pick.s.cursor] : -1;
    pick_draw_list(V->ren, &pick.s, pick_sub_at(mx, my), skey, subcur, -1, mx, my);
  }
}
// the keyboard while a drop-down is open (play.c): typing filters the list
// (its sub-list while that's open), Up / Down / PageUp / PageDown / Home /
// End move, Right opens the sub-list (on its item), Left closes it, Enter
// picks, Backspace takes a letter back (none left: out of the sub-list),
// ESC closes it all -> true: taken
static bool pick_key(Viewer *V, SDL_Window *win, const SDL_Event *e) {
  if (!pick.open) return false;
  PickList *l = pick.sub_open ? &pick.s : &pick.m;
  if (e->type == SDL_EVENT_TEXT_INPUT) {
    size_t n = strlen(l->filter);
    SDL_strlcpy(l->filter + n, e->text.text, sizeof l->filter - n);
    l->cursor = 0;
    pick_layout();
    pl_show_cursor(l);
    return true;
  }
  if (e->type == SDL_EVENT_TEXT_EDITING) return true;
  if (e->type == SDL_EVENT_KEY_UP) return true;
  if (e->type != SDL_EVENT_KEY_DOWN) return false;
  int move = 0;
  switch (e->key.key) {
  case SDLK_ESCAPE: pick.open = false; return true;
  case SDLK_BACKSPACE: {
    size_t n = strlen(l->filter);
    if (n) { l->filter[n - 1] = 0; pick_layout(); pl_show_cursor(l); }
    else if (pick.sub_open) pick_sub_show(false);
    return true;
  }
  case SDLK_UP: move = -1; break;
  case SDLK_DOWN: move = 1; break;
  case SDLK_PAGEUP: move = -SDL_max(1, l->rows - 1); break;
  case SDLK_PAGEDOWN: move = SDL_max(1, l->rows - 1); break;
  case SDLK_HOME: move = -PROP_PICK_MAX; break;
  case SDLK_END: move = PROP_PICK_MAX; break;
  case SDLK_RIGHT:
    if (!pick.sub_open && pick.m.nvis > 0 && pick.m.vis[pick.m.cursor] == pick.subof) { pick_sub_show(true); pick.keyed = true; }
    return true;
  case SDLK_LEFT: if (pick.sub_open) pick_sub_show(false); return true;
  case SDLK_RETURN: case SDLK_KP_ENTER:
    if (pick.sub_open) { if (pick.s.nvis > 0) pick_sub_do(V, pick.s.vis[pick.s.cursor]); }
    else if (pick.m.nvis > 0) { pick.keyed = true; pick_do(V, win, pick.m.vis[pick.m.cursor]); }
    return true;
  default: return true;                            // (any other key: nobody else's while it's open)
  }
  l->cursor = SDL_clamp(l->cursor + move, 0, SDL_max(0, l->nvis - 1));
  pick.keyed = true;
  pl_show_cursor(l);
  if (l == &pick.m) pick_layout();
  return true;
}

// the properties' width: the tab's, less a margin on the right that its
// scrollbar is drawn in (so it never covers a value)
#define PROP_PAD_R 14
static float prop_w(const Viewer *V) { return (float)V->tab_w - PROP_PAD_R; }
// a member's row (kind M): its name, then its type (a link), then its kind
// (a link: a glyph), from these x
static void member_cols(float tw, float *tx, float *kx) {
  *tx = SDL_floorf(tw * 0.40f);
  *kx = SDL_floorf(tw - SDL_max(ui_w("{}"), ui_w("var")) - 2);
}
// a kind, collapsed: var, [] array, () set, {} map (its list says the names:
// "var", "[] array", "() set", "{} map" -- a map's row: "{} map:<values' type>")
static const char *kind_glyph(const char *k) {
  return k[0] == '[' ? "[]" : k[0] == '(' ? "()" : k[0] == '{' ? "{}" : "var";   // (its text starts with it; var: its name, a link needs something to click)
}
// A drop-down's value, drawn as a link (like the node graph's "3 warnings"):
// its text in its colour, underlined; under the mouse, bright. A click opens
// its list as before (prop_click: the same places). -> the x after it
static float draw_link(SDL_Renderer *r, float x, float y, const char *text, SDL_Color c, float maxw, bool hot) {
  char buf[300];
  fit(buf, sizeof buf, text, maxw);
  ui_color(r, hot ? ui.accent : c);
  float ex = ui_text(r, x, y, buf);
  float ty = y - 1 + SDL_floorf((TAB_ROW - g_font_h) / 2);   // (ui_text's top)
  ui_color(r, c);
  SDL_RenderFillRect(r, &(SDL_FRect){ x, ty + g_font_h - (g_lite_font ? 2 : 0), ex - x, 1 });
  return ex;
}

// mouse down on a row (left button)
static void prop_click(Viewer *V, SDL_Window *win, int row, float x, bool edfocus) {
  if (prop.editing) prop_end_edit(V, win, true, edfocus);
  PropRow *r = &prop.rows[row];
  switch (r->kind) {
  case 'n':                                        // scrub or (on release) type
    if (r->range && (SDL_GetModState() & SDL_KMOD_CTRL)) { prop_begin_edit(win, row); break; }   // a slider: CTRL+click types it
    prop.press = true; prop.scrub = false; prop.slide = r->range;
    SDL_strlcpy(prop.press_id, r->id, sizeof prop.press_id);
    prop.press_x = x;
    prop.sent = 0;
    {
      double v = atof(r->text), a = v < 0 ? -v : v;  // the first node's value, even if mixed
      prop.isint = v == SDL_floor(v);
      prop.base = prop.isint ? 0.5 : a < 1 ? 0.005 : a < 100 ? 0.05 : 0.5;
    }
    if (prop.slide) { prop.scrub = true; prop_slide(V, x); }   // (a slider: set where pressed; no typing on release)
    break;
  case 'b': prop_call(V, "viewer_prop_toggle", r->id, 0); break;
  case 'h': case 'p': {                            // a drop-down: its list (a choice's options, a type...)
    int ww = 0, wh = 0;
    SDL_GetWindowSize(win, &ww, &wh);
    pick_open(V, row, wh);
    break;
  }
  case 'M': {                                      // a member's row: its name (double-click: rename), type, kind
    int ww = 0, wh = 0;
    SDL_GetWindowSize(win, &ww, &wh);
    float tx, kx;
    member_cols(prop_w(V), &tx, &kx);
    if (x >= kx - 2) pick_open_list(V, row, r->kopts, r->ktext, kx, "kind", wh);
    else if (x >= tx - 2) pick_open_list(V, row, r->opts, r->text, tx, "type", wh);
    else if (prop.clicks >= 2) prop_begin_edit(win, row);
    break;
  }
  case 'a': prop_call(V, "viewer_prop_add_class", r->id, 0); break;   // + a component from its class
  case 'A':                                        // an action: open a file here, or run a line in the editor (a plugin reloaded)
    if (!strncmp(r->opts, "open:", 5) && editor_running()) {
      editor_open(r->opts + 5, 1);
    } else if (!strncmp(r->opts, "lite:", 5) && editor_running()) editor_exec(r->opts + 5);
    break;
  case 's': case 'l': case 'k': case 'm': prop_begin_edit(win, row); break;   // (m: + member / + class, typed)
  default: break;                                  // tables: headers only; code: caller opens it
  }
}

// mouse motion while a number row is held: scrub once it moved a few pixels
static void prop_drag(Viewer *V, float x) {
  if (prop.slide) { prop_slide(V, x); return; }
  float dx = x - prop.press_x;
  if (!prop.scrub && (dx > 3 || dx < -3)) prop.scrub = true;
  if (!prop.scrub) return;
  SDL_Keymod m = SDL_GetModState();
  double k = (m & SDL_KMOD_SHIFT) ? 10 : (m & SDL_KMOD_CTRL) ? 0.1 : 1;
  double want = dx * prop.base * k;
  if (prop.isint && k >= 1) want = SDL_floor(want + 0.5);
  double d = want - prop.sent;
  if (d == 0) return;
  if (prop.isint && d == SDL_floor(d)) lua_pushinteger(V->L, (lua_Integer)d);
  else lua_pushnumber(V->L, d);
  prop_call(V, "viewer_prop_add", prop.press_id, 1);
  prop.sent = want;
}

static void draw_tooltip(SDL_Renderer *r, int w, float x, float y, const char *text);

static bool prop_can_save(Viewer *V) { return V->stopped && V->savable && V->selected[0] && V->sel_dirty; }
static bool prop_can_undo(Viewer *V) {
  return V->selected[0] && V->sel_dirty && (V->stopped ? V->savable : !V->standalone);
}

static void prop_tooltip(Viewer *V, float top, float mx, float my, bool tip, int win_w) {
  if (!tip) return;
  bool on_save = in_rect(&prop.save_r, mx, my), on_undo = in_rect(&prop.undo_r, mx, my);
  if (!on_save && !on_undo) {
    int row = mx < V->tab_w ? prop_row_at(my) : -1;
    if (row < 0 || prop.press || prop.editing) return;
    PropRow *p = &prop.rows[row];
    char t[400], comp[64] = "";
    {                                              // the component: the row's parent header
      for (int i = row; i >= 0; i--) if (prop.rows[i].depth == 0) { SDL_strlcpy(comp, prop.rows[i].label, sizeof comp); break; }
    }
    if (p->over)
      draw_tooltip(V->ren, win_w, mx, my + 14, "Overridden: differs from the script. Right-click: back to the script's value");
    else if (p->kind == 'M') {                     // a member's row: what's under the mouse
      float tx, kx;
      member_cols(prop_w(V), &tx, &kx);
      char kt[300];
      const char *mv = strchr(p->ktext, ':');      // (a map: its values' type after the colon)
      SDL_snprintf(kt, sizeof kt, "%s%s%s. Click: one value (var), a list ([] array), keys alone (() set), or keys and values ({} map: then its values' type; its keys: the type)",
                   mv ? "{} map of " : p->ktext, mv ? mv + 1 : "", mv ? " values" : "");
      draw_tooltip(V->ren, win_w, mx, my + 14, mx >= kx - 2 ? kt
                                              : mx >= tx - 2 ? "Its type: a plain one or one of your classes"
                                              : "A member. Double-click: rename it. Right-click: rename or remove");
    }
    else if (p->tip[0]) draw_tooltip(V->ren, win_w, mx, my + 14, p->tip);
    else if (p->cls == 'e') draw_tooltip(V->ren, win_w, mx, my + 14, "An item of its collection. Right-click: remove it");
    else if (p->kind == 'a') {
      SDL_snprintf(t, sizeof t, "Add a %s component: what its class /classes/%s starts with", p->label + 2, p->label + 2);
      draw_tooltip(V->ren, win_w, mx, my + 14, t);
    } else if (p->cls == 'i') {
      SDL_snprintf(t, sizeof t, "From its class /classes/%s (this node doesn't have it). Change it, or right-click: it's set here", comp);
      draw_tooltip(V->ren, win_w, mx, my + 14, t);
    } else if (p->range) {
      SDL_snprintf(t, sizeof t, "%g..%g%s (its member's min, max): drag to set it, CTRL+click to type it", p->lo, p->hi, p->rint ? ", whole numbers" : "");
      draw_tooltip(V->ren, win_w, mx, my + 14, t);
    } else if (p->kind == 'h') {
      draw_tooltip(V->ren, win_w, mx, my + 14, "One of a few (its member's options): click to pick one");
    } else if (p->cls == 'd') {
      SDL_snprintf(t, sizeof t, "Differs from its class /classes/%s: %s. Right-click: back to the class's value", comp, p->def);
      draw_tooltip(V->ren, win_w, mx, my + 14, t);
    } else if (p->kind == 'i') {                   // (an info row: all of it)
      SDL_snprintf(t, sizeof t, "%s %s", p->label, p->text);
      draw_tooltip(V->ren, win_w, mx, my + 14, t);
    } else if (p->kind == 't' && p->depth == 0 && !strcmp(p->text, "class")) {
      SDL_snprintf(t, sizeof t, "A %s has a class: /classes/%s, what every %s starts with", comp, comp, comp);
      draw_tooltip(V->ren, win_w, mx, my + 14, t);
    }
    return;
  }
  char t[300];
  const char *what = nsel_more ? "the selected nodes" : "this node";
  if (!V->selected[0]) SDL_snprintf(t, sizeof t, "Select a node first");
  else if (on_save && !V->savable) SDL_snprintf(t, sizeof t, "This world can't be saved");
  else if (on_save && !V->stopped) SDL_snprintf(t, sizeof t, "Stop the game first: changes made while playing aren't saved");
  else if (on_undo && V->stopped && !V->savable) SDL_snprintf(t, sizeof t, "Undo: this world has no saved copy");
  else if (!V->sel_dirty) SDL_snprintf(t, sizeof t, V->stopped ? "No changes: %s matches the disk"
                                                                : "No changes since Play for %s", what);
  else if (on_save && V->script) SDL_snprintf(t, sizeof t, "Save %s as overrides (%s)", what, V->opath);
  else if (on_save) SDL_snprintf(t, sizeof t, "Save %s to disk (only its own components)", what);
  else if (V->stopped) SDL_snprintf(t, sizeof t, "Undo: put %s back as it is on disk", what);
  else SDL_snprintf(t, sizeof t, "Undo: put %s back as it was when Play was pressed", what);
  draw_tooltip(V->ren, win_w, mx, top + 18, t);
}

static void draw_props(Viewer *V, float top, float bottom, float mx, float my, bool tip, int win_w) {
  SDL_Renderer *r = V->ren;
  float full = (float)V->tab_w, tw = prop_w(V);   // (tw: what the rows use; the scrollbar's in the rest)
  float maxw = tw - 10;                            // (px)
  char buf[600];
  prop_fetch(V);
  {                                                // a field just added (+ component > a plain type): type its name now
    lua_State *L = V->L;
    lua_getglobal(L, "viewer_rename");
    if (lua_isstring(L, -1)) {
      int row = prop_find(lua_tostring(L, -1));
      SDL_Window *kw = SDL_GetKeyboardFocus();
      if (!kw) kw = SDL_GetMouseFocus();
      if (row >= 0 && kw && !prop.editing) {
        if (prop.rows[row].kind == 'p' || prop.rows[row].kind == 'h') {   // (a drop-down row: its list opens)
          int ww = 0, wh = 0;
          SDL_GetWindowSize(kw, &ww, &wh);
          pick_open(V, row, wh);
        } else prop_begin_edit(kw, row);
      }
      lua_pushnil(L); lua_setglobal(L, "viewer_rename");
    }
    lua_pop(L, 1);
  }
  if (!V->selected[0]) SDL_snprintf(buf, sizeof buf, "props");
  else if (nsel_more) SDL_snprintf(buf, sizeof buf, "props  %d selected", nsel_more + 1);
  else {
    const char *name = SDL_strrchr(V->selected, '/');
    SDL_snprintf(buf, sizeof buf, "props  %s", name && name[1] ? name + 1 : "/");
  }
  char fitbuf[600];
  // Save / Undo for the selected nodes: enabled while stopped with changes
  float bw = SDL_ceilf(SDL_max(ui_w("Save"), ui_w("Undo"))) + 8;
  prop.undo_r = (SDL_FRect){ tw - 4 - bw, top + 3, bw, TAB_ROW + 1 };
  prop.save_r = (SDL_FRect){ tw - 8 - 2 * bw, top + 3, bw, TAB_ROW + 1 };
  bool cans[2] = { prop_can_save(V), prop_can_undo(V) };
  const SDL_FRect *br[2] = { &prop.save_r, &prop.undo_r };
  static const char *bl[2] = { "Save", "Undo" };
  for (int i = 0; i < 2; i++) {
    bool can = cans[i];
    bool over = can && in_rect(br[i], mx, my);
    ui_color(r, over ? ui.selection : ui.hilite);
    SDL_RenderFillRect(r, br[i]);
    ui_color(r, !can ? ui.dim : i == 0 ? ui.string : ui.accent);   // (Save: yellow-ish, like the bar's)
    ui_text_in(r, br[i]->x + SDL_floorf((br[i]->w - ui_w(bl[i])) / 2), br[i]->y, br[i]->h, bl[i]);
  }
  prop.y0 = top + TAB_TOP;
  prop.vis = (int)((bottom - prop.y0 - 4) / TAB_ROW);
  if (prop.vis < 1) prop.vis = 1;
  if (prop.scroll > prop.n - prop.vis) prop.scroll = prop.n - prop.vis;
  if (prop.scroll < 0) prop.scroll = 0;
  ui_color(r, ui.accent);                          // the header: "props  <name>"
  ui_text(r, TAB_PAD, top + 4, fit(fitbuf, sizeof fitbuf, buf, prop.save_r.x - 4 - TAB_PAD));
  if (!V->selected[0]) {
    ui_color(r, ui.dim);
    ui_text(r, TAB_PAD, prop.y0, fit(fitbuf, sizeof fitbuf, "select a node", maxw));
    ui_text(r, TAB_PAD, prop.y0 + TAB_ROW, fit(fitbuf, sizeof fitbuf, "CTRL+click: more", maxw));
    g_sb_props = (Scroll){ 0 };
    return;
  }
  float vx = SDL_floorf(tw * 0.5f);                // value column
  float vw = tw - vx - 4;                          // the value's room, px
  prop.vx = vx; prop.vw = tw - 6 - vx;             // (a slider's span: the value column)
  int hover = mx < full && my >= top && !pick.open ? prop_row_at(my) : -1;   // (a drop-down open: it has the mouse)
  for (int i = prop.scroll, k = 0; i < prop.n && k < prop.vis; i++, k++) {
    PropRow *p = &prop.rows[i];
    float y = prop.y0 + k * TAB_ROW;
    bool editing = prop.editing && !strcmp(prop.edit_id, p->id);
    bool active = (prop.press && !strcmp(prop.press_id, p->id)) || editing;
    if ((i == hover && p->kind != 't' && p->kind != 'i') || active) {
      SDL_FRect hl = { 2, y - 1, full - 5, TAB_ROW };
      ui_color(r, active ? ui.selection : ui.hilite);
      SDL_RenderFillRect(r, &hl);
    }
    float lx = TAB_PAD + p->depth * 9.f;
    if (p->kind == 'M') {                          // a member: a line above it, its name, its type and kind boxes
      float tx, kx;
      member_cols(tw, &tx, &kx);
      if (k > 0) {
        ui_color(r, ui.divider);
        SDL_RenderLine(r, 2, y - 2, full - 3, y - 2);
      }
      if (editing) {                               // renaming: the name typed in its place
        SDL_FRect box = { lx - 2, y - 2, tx - lx - 4, TAB_ROW + 1 };
        ui_color(r, ui.bg);
        SDL_RenderFillRect(r, &box);
        ui_color(r, ui.line);
        SDL_RenderRect(r, &box);
        bool caret = ((SDL_GetTicks() - prop.blink) / 530) % 2 == 0;
        le_draw(r, &prop.e, lx, y, tx - lx - 8, caret, ui.normal);
      } else {
        ui_color(r, ui.accent);
        ui_text(r, lx, y, fit(fitbuf, sizeof fitbuf, p->label, tx - lx - 6));
      }
      bool on_row = i == hover;                    // (its type and kind: links, each hot under the mouse)
      draw_link(r, tx, y, p->text, ui.func, kx - tx - 8, on_row && mx >= tx - 2 && mx < kx - 2);
      draw_link(r, kx, y, kind_glyph(p->ktext), ui.func, tw - kx, on_row && mx >= kx - 2);
      continue;
    }
    float lw = vx - 4 - lx;                        // the label's room, px
    if (p->kind == 't' && p->text[0] == 0) lw = tw - 4 - lx;
    ui_color(r, p->depth == 0 ? ui.accent : ui.text);   // (a component: bright; its fields: lite's text)
    if (p->cls == 'i') ui_color(r, ui.dim);        // inherited from its class: dim
    if (p->cls == 'd') {                           // differs from its class: a bar (the caret's colour)
      ui_color(r, ui.caret);
      SDL_FRect m = { 4, y - 1, 2, TAB_ROW - 1 };
      SDL_RenderFillRect(r, &m);
      ui_color(r, ui.text);
    }
    if (p->over) {                                 // overridden (script worlds): the warning colour + bar
      ui_color(r, ui.warn);
      SDL_FRect m = { 4, y - 1, 2, TAB_ROW - 1 };
      SDL_RenderFillRect(r, &m);
    }
    if (p->kind == 'a' || p->kind == 'm' || (p->kind == 'p' && p->label[0] == '+'))
      ui_color(r, ui.caret);                       // + item, + member, + component (a drop-down)
    ui_text(r, lx, y, fit(fitbuf, sizeof fitbuf, p->label, lw));
    if (rdrag.kind == RDRAG_SYSTEM && rdrag.moving && p->kind == 'c' && p->depth == 0 &&
        !strcmp(rdrag.target, p->label)) rdrag_draw(r, 2, full - 3, y);
    if (editing) {
      SDL_FRect box = { vx - 2, y - 2, tw - vx - 1, TAB_ROW + 1 };
      ui_color(r, ui.bg);
      SDL_RenderFillRect(r, &box);
      ui_color(r, ui.line);
      SDL_RenderRect(r, &box);
      bool caret = ((SDL_GetTicks() - prop.blink) / 530) % 2 == 0;
      le_draw(r, &prop.e, vx, y, vw, caret, ui.normal);
      continue;
    }
    if (p->kind == 't' && p->text[0] == 0) continue;
    if (p->kind == 'n' && p->range && !p->mixed) {  // a slider: its place in the range, behind the number
      double f = (atof(p->text) - p->lo) / (p->hi - p->lo);
      if (f < 0) f = 0;
      if (f > 1) f = 1;
      SDL_FRect bar = { vx - 2, y - 1, prop.vw + 2, TAB_ROW - 1 };
      ui_color(r, ui.bg);
      SDL_RenderFillRect(r, &bar);
      bar.w = (float)SDL_floor((prop.vw + 2) * f);
      ui_color(r, ui.selection);
      SDL_RenderFillRect(r, &bar);
    }
    float tx = vx;
    if (p->kind == 'k' && !p->mixed) {             // a colour: a swatch, then its numbers
      int c[4] = { 0, 0, 0, 255 };
      sscanf(p->text, "%d, %d, %d, %d", &c[0], &c[1], &c[2], &c[3]);
      SDL_FRect sw = { vx, y, SDL_floorf(TAB_ROW * 1.4f), TAB_ROW - 3 };
      SDL_SetRenderDrawColor(r, (Uint8)c[0], (Uint8)c[1], (Uint8)c[2], 255);
      SDL_RenderFillRect(r, &sw);
      ui_color(r, ui.line);
      SDL_RenderRect(r, &sw);
      tx = vx + sw.w + 4;
    }
    bool drop = ((p->kind == 'h' || (p->kind == 'p' && (p->depth > 0 || p->label[0] == '+'))) && !p->mixed) || p->kind == 'A';   // a drop-down (an action): its value, a link
    const char *t = p->mixed ? "--" : p->text;
    switch (p->kind) {                             // values: coloured as lite colours code
    case 'n': ui_color(r, ui.number); break;
    case 'b': ui_color(r, ui.literal); break;
    case 's': ui_color(r, ui.string); break;
    case 'c': ui_color(r, ui.keyword); break;
    default:  ui_color(r, ui.normal); break;
    }
    if (p->kind == 't' && !strcmp(p->text, "class")) ui_color(r, ui.caret);
    if (p->kind == 'i') ui_color(r, ui.comment);
    if (p->mixed || p->cls == 'i') ui_color(r, ui.dim);
    if (p->kind == 's' && !p->mixed) { SDL_snprintf(buf, sizeof buf, "\"%s\"", t); t = buf; }
    if (p->kind == 'h') ui_color(r, ui.string);
    if (p->kind == 'p' && p->depth > 0) ui_color(r, ui.func);   // a member's type, kind, values
    if (p->kind == 'p' && p->depth == 0) ui_color(r, ui.comment);   // a member's summary
    if (p->kind == 'a' || p->kind == 'A') ui_color(r, ui.caret);
    if (p->kind == 'm') ui_color(r, ui.dim);       // (what to type: a hint)
    if (p->cls == 'i') ui_color(r, ui.dim);
    if (drop) {                                    // a drop-down: a link (a click opens its list)
      SDL_Color c;
      if (p->kind == 'p' && p->label[0] == '+') ui_color(r, ui.caret);   // (+ component: an action)
      SDL_GetRenderDrawColor(r, &c.r, &c.g, &c.b, &c.a);
      draw_link(r, tx, y, t, c, vw - (tx - vx), i == hover && mx >= vx - 2 && mx < tw);
      continue;
    }
    ui_text(r, tx, y, fit(fitbuf, sizeof fitbuf, t, vw - (tx - vx)));
  }
  g_sb_props = (Scroll){ full - 5, prop.y0 - 1, prop.vis * TAB_ROW, prop.n, prop.vis, prop.scroll };   // (over the rows)
  scroll_draw(r, &g_sb_props, sbdrag.which == DRAG_SB_PROPS || (scroll_hit(&g_sb_props, mx, my) && !pick.open));
  prop_tooltip(V, top, mx, my, tip, win_w);
}

// the profiler's bar behind a tree row: the node's ms a tick (with its
// children's) out of a frame's budget (1000 / 60 ms), right to left. Its
// colour: 10 bands of a turbo-like scale (blue, cyan, green, lime, yellow,
// orange, red: perceptually even, readable on the dark tab), one per 10% of
// the budget: from 90% on it's the last, brightest one.
static void prof_bar(Viewer *V, float tw, float y, double ms) {
  const double budget = 1000.0 / 60.0;
  double f = ms / budget;
  if (ms < 0.001) return;
  if (f > 1) f = 1;
  static const Uint8 band[10][3] = {
    {  52, 144, 248 }, {  37, 192, 222 }, {  46, 229, 175 }, {  82, 250, 127 }, { 136, 252,  87 },
    { 195, 236,  60 }, { 242, 203,  44 }, { 255, 157,  34 }, { 255, 105,  30 }, { 255,  55,  55 } };
  int k = (int)(f * 10);
  if (k > 9) k = 9;
  float w = (float)(f * (tw - 6));
  if (w < 2) w = 2;                                // (something ran there: a sliver at least)
  SDL_FRect bar = { tw - 3 - w, y - 1, w, TAB_ROW };
  SDL_SetRenderDrawColor(V->ren, band[k][0], band[k][1], band[k][2], (Uint8)(110 + k * 14));   // (costlier: more opaque)
  SDL_RenderFillRect(V->ren, &bar);
}

// The tree's lines, from a row's shape (viewer_outline), Windows style:
// level L has its line at x = TREE_CX(L): the line down its siblings, with
// each row's box (if it has children) centred on it, so the '+' / '-' box's
// middle pixel column is that line's. From there a stub runs right to the
// name; an open branch's children hang from that stub, at TREE_CX(L + 1).
// Per level above the row: '|' its line goes on down through the row; then
// the row's own: 'T' (more siblings below) / 'L' (the last one); then '-' /
// '+' (open / closed: a click toggles it) or ' ' (no children). '' = the
// root: its '/' centred on the first level's line. All whole pixels, from
// the constants below, so the lines and the boxes' middles always match.
#define TREE_X0   TAB_PAD                        // the tab's left margin
#define TREE_HALF 4                              // a box: 2 * 4 + 1 = 9 px, middle column included
#define TREE_IND  11                             // one level, px
#define TREE_CX(L)   (TREE_X0 + TREE_HALF + (L) * TREE_IND)   // level L's line (and boxes' middle)
#define TREE_NAME(L) (TREE_CX(L) + TREE_IND + 5)              // where a level L name starts
static char g_tree_shape[256][64];               // per visible row (for clicks)
static float tree_lines(SDL_Renderer *r, const char *shape, float y) {
  int lv = (int)strlen(shape) - 2;                 // this row's level (0: first)
  if (lv < 0) return SDL_floorf(TREE_CX(0) - ui_w("/") / 2);   // the root: '/' centred on level 0's line
  float top = y - 1, mid = ROW_MID(y), bot = y - 1 + TAB_ROW;
  float cx = (float)TREE_CX(lv), name = (float)TREE_NAME(lv);
  char own = shape[lv], fold = shape[lv + 1];
  ui_color(r, ui.dim);
  for (int i = 0; i < lv; i++)
    if (shape[i] == '|') SDL_RenderLine(r, (float)TREE_CX(i), top, (float)TREE_CX(i), bot);
  if (fold == 'g') {                               // a row of thumbnails: its siblings' line goes on (more after it)
    if (own == 'T') SDL_RenderLine(r, cx, top, cx, bot);
    return name;
  }
  SDL_RenderLine(r, cx, top, cx, own == 'T' ? bot : mid);   // the siblings' line
  SDL_RenderLine(r, cx, mid, name - 3, mid);                // the stub to the name
  if (fold == '-') SDL_RenderLine(r, (float)TREE_CX(lv + 1), mid, (float)TREE_CX(lv + 1), bot);   // to the children
  if (fold == '-' || fold == '+') {
    SDL_FRect b = { cx - TREE_HALF, mid - TREE_HALF, 2 * TREE_HALF + 1, 2 * TREE_HALF + 1 };
    ui_color(r, ui.bg2);
    SDL_RenderFillRect(r, &b);
    ui_color(r, ui.text);
    SDL_RenderRect(r, &b);
    ui_color(r, ui.accent);
    SDL_RenderLine(r, cx - 2, mid, cx + 2, mid);
    if (fold == '+') SDL_RenderLine(r, cx, mid - 2, cx, mid + 2);
  }
  return name;
}

// Thumbnails (settings: thumbnails, px; 0 off): an /assets folder's files
// that their plugin previews (its config.lua: thumbnails = "image") show as
// a matrix under it, after its other rows: lines of cells (the picture,
// its aspect kept, its name under it), each line a few tree rows high
// (viewer_outline's kind 'g' rows: g_tree_grid). A cell is a node like a row:
// click selects (CTRL: adds), RMB its menu, double-click opens it.
// Later: a kind of preview per plugin ("frames": animated; an overlay:
// play / pause for sounds), from the same grids string ("k\nkind\npaths").
#define THUMB_PAD 4
static char *g_tree_grid[256];                   // per visible row: its grid ("k\nkind\npath\npath..."), or NULL
static float thumb_cw(int S) { return (float)(S + 2 * THUMB_PAD); }
static int thumb_span(int S) { return (int)SDL_ceilf((S + THUMB_PAD + 3 + TAB_ROW) / (float)TAB_ROW); }
static float thumb_x0(int lv) { return (float)(TREE_CX(lv) + 7); }
typedef struct { int k, n; char kind[16]; const char *cells[64]; char buf[64 * 256]; } TreeGrid;
static bool tree_grid(int i, TreeGrid *g) {      // row i's grid, parsed
  if (i < 0 || i >= 256 || !g_tree_grid[i]) return false;
  SDL_strlcpy(g->buf, g_tree_grid[i], sizeof g->buf);
  char *p = g->buf, *nl;
  g->k = SDL_atoi(p);
  g->n = 0;
  g->kind[0] = 0;
  if ((nl = strchr(p, '\n'))) p = nl + 1; else return false;
  if ((nl = strchr(p, '\n'))) { *nl = 0; SDL_strlcpy(g->kind, p, sizeof g->kind); p = nl + 1; } else return false;
  while (*p && g->n < 64) {
    g->cells[g->n++] = p;
    if ((nl = strchr(p, '\n'))) { *nl = 0; p = nl + 1; } else break;
  }
  return g->n > 0;
}
static int tree_cell_at(int i, float x, float y, TreeGrid *g) {   // the cell of row i's grid under (x, y), or -1
  if (!tree_grid(i, g)) return -1;
  int S = settings_thumbs();
  int lv = (int)strlen(g_tree_shape[i]) - 2;
  float cw = thumb_cw(S), x0 = thumb_x0(lv);
  float y0 = TREE_TOP + (i - g->k) * TAB_ROW - 1;
  int j = (int)SDL_floorf((x - x0) / cw);
  if (x < x0 || j < 0 || j >= g->n || y < y0 || y >= y0 + thumb_span(S) * TAB_ROW) return -1;
  return j;
}
static void draw_tree_grid(Viewer *V, int i, float mx, float my) {   // row i: a line of thumbnails (once: its first row shown)
  TreeGrid g;
  if (!tree_grid(i, &g)) return;
  SDL_Renderer *r = V->ren;
  int S = settings_thumbs(), lv = (int)strlen(g_tree_shape[i]) - 2;
  float cw = thumb_cw(S), x0 = thumb_x0(lv);
  float y0 = TREE_TOP + (i - g.k) * TAB_ROW - 1, ch = thumb_span(S) * TAB_ROW;
  SDL_Rect clip = { 0, TREE_TOP - 1, V->tab_w - 5, V->rows * TAB_ROW };   // (a line half scrolled away: cut)
  SDL_SetRenderClipRect(r, &clip);
  char buf[256];
  for (int j = 0; j < g.n; j++) {
    SDL_FRect c = { x0 + j * cw, y0, cw - 1, ch - 1 };
    if (c.x + c.w > V->tab_w - 5) break;
    bool primary = V->selected[0] && !strcmp(g.cells[j], V->selected);
    bool issel = primary || is_selected(V, g.cells[j]);
    bool hot = in_rect(&c, mx, my) && !pick.open;
    if (issel || hot) {
      ui_color(r, primary ? ui.selection : issel ? ui.hilite : ui.bg3);
      SDL_RenderFillRect(r, &c);
    }
    SDL_FRect im = { c.x + THUMB_PAD, c.y + THUMB_PAD, (float)S, (float)S };
    ui_color(r, ui.bg);
    SDL_RenderFillRect(r, &im);
    Tex *tx = !strcmp(g.kind, "image") ? tex_get(V, g.cells[j]) : NULL;
    if (tx && tx->tex && tx->w > 0 && tx->h > 0) { // the picture, its aspect kept, centred
      float k = SDL_min((float)S / tx->w, (float)S / tx->h);
      if (k > 1 && S >= 2 * SDL_max(tx->w, tx->h)) k = SDL_floorf(k);   // (small art: whole pixels)
      SDL_FRect d = { im.x + SDL_floorf((S - tx->w * k) / 2), im.y + SDL_floorf((S - tx->h * k) / 2), tx->w * k, tx->h * k };
      SDL_SetTextureColorMod(tx->tex, 255, 255, 255);
      SDL_SetTextureAlphaMod(tx->tex, 255);
      SDL_RenderTexture(r, tx->tex, NULL, &d);
    } else {                                       // can't show it: its extension
      const char *ext = SDL_strrchr(g.cells[j], '.');
      ui_color(r, ui.dim);
      ui_text(r, im.x + 3, im.y + 2, ext ? ext + 1 : "?");
    }
    const char *name = SDL_strrchr(g.cells[j], '/');
    char stem[128];                                // its name without the extension (the picture says what it is)
    SDL_strlcpy(stem, name ? name + 1 : g.cells[j], sizeof stem);
    char *dot = SDL_strrchr(stem, '.');
    if (dot && dot != stem) *dot = 0;
    const char *shown = fit(buf, sizeof buf, stem, cw - 4);
    ui_color(r, issel || hot ? ui.accent : ui.text);
    ui_text(r, c.x + SDL_floorf((c.w - ui_w(shown)) / 2), c.y + THUMB_PAD + S + 2, shown);
  }
  SDL_SetRenderClipRect(r, NULL);
}

static char (*g_viewer_panel_paths)[256];        // the tree rows (for drag & drop)
static int g_viewer_panel_n;

// The tree's filter (the box above "/"): typing shows the nodes whose name
// holds the text (any case), and the nodes that lead to them; with a "/" in
// it, their path. Enter keeps it and leaves the box; ESC empties it (again:
// leaves); the x empties it too.
static struct { LineEd e; bool focus; Uint64 blink; SDL_FRect r, x; } tf;

static void tf_focus(SDL_Window *win, bool on, bool edfocus) {
  if (on == tf.focus) return;
  tf.focus = on;
  tf.blink = SDL_GetTicks();
  if (on) SDL_StartTextInput(win);
  else if (!edfocus) SDL_StopTextInput(win);
}

static void tf_event(Viewer *V, SDL_Window *win, const SDL_Event *e, bool edfocus) {
  tf.blink = SDL_GetTicks();
  if (e->type == SDL_EVENT_TEXT_INPUT) { le_insert(&tf.e, e->text.text); V->scroll = 1; return; }
  if (e->type != SDL_EVENT_KEY_DOWN) return;
  switch (e->key.key) {
  case SDLK_RETURN: case SDLK_KP_ENTER: tf_focus(win, false, edfocus); break;
  case SDLK_ESCAPE:
    if (tf.e.len) { le_set(&tf.e, ""); V->scroll = 1; } else tf_focus(win, false, edfocus);
    break;
  default:
    if (le_key(&tf.e, e->key.key, (e->key.mod & SDL_KMOD_CTRL) != 0)) V->scroll = 1;
    break;
  }
}

static void draw_tree_filter(Viewer *V, float tw, float mx, float my) {
  SDL_Renderer *r = V->ren;
  tf.r = (SDL_FRect){ 6, TREE_FILTER_Y, tw - 12, TAB_ROW + 2 };
  bool hover = in_rect(&tf.r, mx, my);
  ui_color(r, ui.bg);
  SDL_RenderFillRect(r, &tf.r);
  ui_color(r, tf.focus || hover ? ui.dim : ui.line);
  SDL_RenderRect(r, &tf.r);
  float x = tf.r.x + 6, ty = tf.r.y + 1 + SDL_floorf((tf.r.h - TAB_ROW) / 2);
  float xw = tf.e.len ? ui_w("x") + 10 : 0;
  tf.x = (SDL_FRect){ tf.r.x + tf.r.w - xw, tf.r.y, xw, tf.r.h };
  float room = tf.r.w - 12 - xw;
  bool caret = tf.focus && ((SDL_GetTicks() - tf.blink) / 530) % 2 == 0;
  if (tf.e.len) {
    le_draw(r, &tf.e, x, ty, room, caret, ui.normal);
    ui_color(r, in_rect(&tf.x, mx, my) ? ui.normal : ui.dim);
    ui_text(r, tf.x.x + 4, ty, "x");
  } else {
    tf.e.view = 0;
    if (!tf.focus) { ui_color(r, ui.dim); ui_text(r, x, ty, "filter"); }
    if (caret) { ui_color(r, ui.caret); SDL_RenderFillRect(r, &(SDL_FRect){ x, ty - 1, g_lite_font ? 2 : 1, TAB_ROW }); }
  }
}

static void draw_tab(Viewer *V, int h, float mx, float my, bool tip, int win_w) {
  lua_State *L = V->L;
  g_viewer_panel_paths = V->panel_paths;
  float tw = (float)V->tab_w;
  char buf[512];

  SDL_FRect bg = { 0, 0, tw, (float)h };
  ui_color(V->ren, ui.bg2);                        // (lite's side bar)
  SDL_RenderFillRect(V->ren, &bg);

  if (V->world != LUA_NOREF) draw_tree_filter(V, tw, mx, my);
  float footer = tab_split(h);                     // tree above, properties below
  V->rows = (int)((footer - TREE_TOP - 4) / TAB_ROW);
  if (V->rows < 1) V->rows = 1;
  if (V->rows > 256) V->rows = 256;
  V->panel_n = 0;

  int total = 0;
  if (V->world != LUA_NOREF && !V->stopped) prof_select(V);   // the profiler's costs: live, or the frame shown
  if (V->world != LUA_NOREF) {
    for (int pass = 0; pass < 2; pass++) {         // 2nd pass only if we had to scroll
      lua_getglobal(L, "viewer_outline");
      lua_rawgeti(L, LUA_REGISTRYINDEX, V->world);
      lua_pushinteger(L, V->scroll < 1 ? 1 : V->scroll);
      lua_pushinteger(L, V->rows);
      lua_pushstring(L, V->selected);
      lua_pushboolean(L, V->reveal);
      lua_pushstring(L, tf.e.len ? tf.e.s : "");  // (the filter box's text)
      int S = settings_thumbs();
      if (S > 0) {                                 // thumbnails: the cells' size, for its matrix
        lua_createtable(L, 0, 4);
        lua_pushnumber(L, thumb_cw(S)); lua_setfield(L, -2, "cw");
        lua_pushinteger(L, thumb_span(S)); lua_setfield(L, -2, "span");
        lua_pushnumber(L, tw - 8 - thumb_x0(0)); lua_setfield(L, -2, "room");
        lua_pushnumber(L, TREE_IND); lua_setfield(L, -2, "ind");
      } else lua_pushnil(L);
      if (lua_pcall(L, 7, 7, 0) != 0) { lua_pop(L, 1); break; }
      total = (int)lua_tointeger(L, -6);
      int sel = (int)lua_tointeger(L, -4);
      int first = V->scroll;
      if (V->reveal && sel > 0 && (sel < V->scroll || sel >= V->scroll + V->rows))
        V->scroll = sel - V->rows / 2;
      V->reveal = false;
      if (V->scroll > total - V->rows + 1) V->scroll = total - V->rows + 1;
      if (V->scroll < 1) V->scroll = 1;
      if (V->scroll != first && pass == 0) { lua_pop(L, 7); continue; }

      int t = lua_gettop(L) - 6, paths = lua_gettop(L) - 4, kinds = lua_gettop(L) - 2, shapes = lua_gettop(L) - 1, grids = lua_gettop(L);
      int n = (int)objlen(L, t);
      for (int i = 0; i < 256; i++) { SDL_free(g_tree_grid[i]); g_tree_grid[i] = NULL; }
      for (int i = 1; i <= n; i++) {
        lua_rawgeti(L, grids, i);                  // a row of thumbnails: lines, then its cells (once)
        if (lua_isstring(L, -1)) {
          g_tree_grid[i - 1] = SDL_strdup(lua_tostring(L, -1));
          lua_pop(L, 1);
          lua_rawgeti(L, paths, i);
          SDL_strlcpy(V->panel_paths[i - 1], lua_tostring(L, -1) ? lua_tostring(L, -1) : "/", sizeof V->panel_paths[0]);
          lua_pop(L, 1);
          lua_rawgeti(L, shapes, i);
          SDL_strlcpy(g_tree_shape[i - 1], lua_tostring(L, -1) ? lua_tostring(L, -1) : " ", sizeof g_tree_shape[0]);
          lua_pop(L, 1);
          float y = TREE_TOP + (i - 1) * TAB_ROW;
          tree_lines(V->ren, g_tree_shape[i - 1], y);
          int k = SDL_atoi(g_tree_grid[i - 1]);
          if (k == 0 || i == 1) draw_tree_grid(V, i - 1, mx, my);
          continue;
        }
        lua_pop(L, 1);
        lua_rawgeti(L, paths, i);
        const char *path = lua_tostring(L, -1);
        SDL_strlcpy(V->panel_paths[i - 1], path ? path : "/", sizeof V->panel_paths[0]);
        lua_pop(L, 1);
        float y = TREE_TOP + (i - 1) * TAB_ROW;
        bool primary = V->selected[0] && !strcmp(V->panel_paths[i - 1], V->selected);
        bool issel = primary || is_selected(V, V->panel_paths[i - 1]);
        if (issel) {
          SDL_FRect hl = { 2, y - 1, tw - 5, TAB_ROW };
          ui_color(V->ren, primary ? ui.selection : ui.hilite);
          SDL_RenderFillRect(V->ren, &hl);
        }
        double pms = V->stopped ? 0 : prof_ms(V, V->panel_paths[i - 1]);   // running / paused: its time
        if (pms > 0) prof_bar(V, tw, y, pms);
        lua_rawgeti(L, kinds, i);
        char kind = lua_tostring(L, -1) ? lua_tostring(L, -1)[0] : 0;
        lua_pop(L, 1);
        lua_rawgeti(L, shapes, i);
        SDL_strlcpy(g_tree_shape[i - 1], lua_tostring(L, -1) ? lua_tostring(L, -1) : " ", sizeof g_tree_shape[0]);
        lua_pop(L, 1);
        float tx = tree_lines(V->ren, g_tree_shape[i - 1], y);
        lua_rawgeti(L, t, i);
        bool hot = mx >= 0 && mx < tw && my >= y - 1 && my < y - 1 + TAB_ROW && !pick.open;
        if (issel || hot) ui_color(V->ren, ui.accent);   // (lite's tree: the hovered / selected item bright)
        else if (kind == 'v') ui_color(V->ren, ui.dim);  // a missing root
        else if (kind == 'c') ui_color(V->ren, ui_mix(ui.text, ui.dim, 0.35f));   // /classes: dimmed
        else if (kind == 'x') ui_color(V->ren, ui.func); // /entities, /tmp: not saved
        else ui_color(V->ren, ui.text);
        {                                          // its name, then (a folder) how many nodes it holds: "input\t(2)", dim
          char name[300];
          SDL_strlcpy(name, lua_tostring(L, -1) ? lua_tostring(L, -1) : "", sizeof name);
          char *count = strchr(name, '\t');
          if (count) *count++ = 0;
          float room = tw - 5 - tx - (count ? ui_w(" (00)") : 0);
          float ex = ui_text(V->ren, tx, y, fit(buf, sizeof buf, name, room));
          if (count) {
            ui_color(V->ren, issel || hot ? ui.text : ui.dim);
            ui_text(V->ren, ex + ui_w(" "), y, count);
          }
        }
        if (pms >= 0.005 && mx >= 0 && mx < tw && my >= y - 1 && my < y - 1 + TAB_ROW) {   // hovered: its ms, right-aligned
          char t[48];
          SDL_snprintf(t, sizeof t, "%.2fms %5.2f%%", pms, pms * 100.0 / (1000.0 / 60.0));   // (of a frame's budget)
          float w = SDL_ceilf(ui_w(t));
          SDL_FRect tb = { tw - 6 - w, y - 1, w + 3, TAB_ROW };
          ui_colora(V->ren, ui.bg3, 230);
          SDL_RenderFillRect(V->ren, &tb);
          ui_color(V->ren, ui.accent);
          ui_text(V->ren, tb.x + 2, y, t);
        }
        if (rdrag.kind == RDRAG_TREE && rdrag.moving && !strcmp(rdrag.target, V->panel_paths[i - 1]))
          rdrag_draw(V->ren, 2, tw - 3, y);
        lua_pop(L, 1);
      }
      V->panel_n = n;
      g_viewer_panel_n = n;
      lua_pop(L, 7);
      break;
    }
  }

  g_sb_tree = (Scroll){ tw - 5, TREE_TOP - 1, V->rows * TAB_ROW, total, V->rows, V->scroll - 1 };   // (over the rows and their bars)
  scroll_draw(V->ren, &g_sb_tree, sbdrag.which == DRAG_SB_TREE || (scroll_hit(&g_sb_tree, mx, my) && !pick.open));
  (void)total;                                     // (no header: "/ (N)" says how many; the scrollbar where you are)

  ui_color(V->ren, ui.divider);                    // under the toolbar (its icons: draw_bar)
  SDL_RenderLine(V->ren, 0, TOOLS_H, tw - 1, TOOLS_H);
  // the two lines you can drag (tree | properties, the tab | the editor):
  // lite's draggable splits (its node.lua): 3 px, teal, lighter under the
  // mouse, aqua while dragged
  ui_color(V->ren, g_split_drag ? ui.pane_drag : g_split_hot ? ui.pane_hover : ui.pane);
  SDL_RenderFillRect(V->ren, &(SDL_FRect){ 0, footer - 1, tw - 3, 3 });
  draw_props(V, footer + 2, (float)h, mx, my, tip, win_w);
  ui_color(V->ren, g_edge_drag ? ui.pane_drag : g_edge_hot ? ui.pane_hover : ui.pane);
  SDL_RenderFillRect(V->ren, &(SDL_FRect){ tw - 3, 0, 3, (float)h });
}

// tree row under a point (window coordinates), or NULL
static const char *panel_hit(Viewer *V, float x, float y) {
  if (x < 0 || x >= V->tab_w || y < TREE_TOP) return NULL;
  int i = (int)SDL_floorf((y - TREE_TOP + 1) / TAB_ROW);
  if (i < 0 || i >= V->panel_n) return NULL;
  if (g_tree_grid[i]) {                            // thumbnails: the cell under it (between them: none)
    static TreeGrid g;
    static char cell[256];
    int j = tree_cell_at(i, x, y, &g);
    if (j < 0) return NULL;
    SDL_strlcpy(cell, g.cells[j], sizeof cell);
    return cell;
  }
  return V->panel_paths[i];
}

// a press on a tree row's '+' / '-' box? Then it closes / opens that
// branch: -> true
static bool panel_fold(Viewer *V, const char *path, float x, float y) {
  int i = (int)SDL_floorf((y - TREE_TOP + 1) / TAB_ROW);
  if (i < 0 || i >= V->panel_n || V->world == LUA_NOREF) return false;
  const char *shape = g_tree_shape[i];
  int lv = (int)strlen(shape) - 2;
  if (lv < 0 || (shape[lv + 1] != '-' && shape[lv + 1] != '+')) return false;
  if (x < TREE_CX(lv) - TREE_HALF - 2 || x > TREE_CX(lv) + TREE_HALF + 2) return false;
  lua_State *L = V->L;
  int top = lua_gettop(L);
  lua_getglobal(L, "viewer_tree_fold");
  lua_rawgeti(L, LUA_REGISTRYINDEX, V->world);
  lua_pushstring(L, path);
  bool ok = lua_pcall(L, 2, 1, 0) == 0 && lua_toboolean(L, -1);
  lua_settop(L, top);
  return ok;
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

// the tree item under the mouse (play.c sets it on mouse moves): while the
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
static void draw_clicklog(Viewer *V, float x0, float bottom) {
  int n = clicklog_n < CLICKLOG ? clicklog_n : CLICKLOG;
  for (int i = 0; i < n; i++) {
    const char *l = clicklog[(clicklog_n - n + i) % CLICKLOG];
    float y = bottom - (n - i) * 10.f;
    SDL_FRect bg = { x0 + 2, y - 1, 8.f * (float)strlen(l) + 4, 10 };
    SDL_SetRenderDrawColor(V->ren, 0, 0, 0, 220);
    SDL_RenderFillRect(V->ren, &bg);
    SDL_SetRenderDrawColor(V->ren, 255, 255, 120, 255);
    SDL_RenderDebugText(V->ren, x0 + 4, y, l);
  }
}

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
  prop.scroll = 0;
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
static void open_where(Viewer *V, const char *where, bool *edfocus) {
  char src[160];
  SDL_strlcpy(src, where, sizeof src);
  char *colon = SDL_strrchr(src, ':');
  int line = 1;
  if (colon && colon != src && colon[1] >= '0' && colon[1] <= '9') { line = atoi(colon + 1); *colon = 0; }
  const char *file = NULL;
  lua_State *L = V->L;
  int top = lua_gettop(L);
  SDL_PathInfo info;
  if (SDL_GetPathInfo(src, &info) && info.type == SDL_PATHTYPE_FILE) file = src;
  else if (src[0] == '/') {                        // a code leaf: node path + component
    char *slash = SDL_strrchr(src, '/');
    char node[160];
    SDL_snprintf(node, sizeof node, "%.*s", slash == src ? 1 : (int)(slash - src), src);
    lua_getglobal(L, "viewer_leaf");
    lua_pushstring(L, node);
    lua_pushstring(L, slash + 1);
    if (lua_pcall(L, 2, 1, 0) == 0 && lua_isstring(L, -1)) file = lua_tostring(L, -1);
    if (!file || !SDL_GetPathInfo(file, &info)) { file = NULL; inspect(V, node, NULL, edfocus); }
  }
  if (file && editor_running() && editor_open(file, line)) {
    *edfocus = true;
    editor_focus(true);
  }
  lua_settop(L, top);
}

// ---------------------------------------------------------------------------
// drag to reorder: tree rows among their siblings, systems (code rows of the
// property panel) among the node's systems. The new order goes into the
// root's `order` list (order.lua). A press that doesn't move is a click.
// ---------------------------------------------------------------------------


static void parent_of(const char *p, char *out, size_t cap) {
  const char *s = SDL_strrchr(p, '/');
  if (!s || s == p) SDL_strlcpy(out, "/", cap);
  else SDL_snprintf(out, cap, "%.*s", (int)(s - p), p);
}

// where would a drop at y go? (fills rdrag.target / after)
static void rdrag_target(float y) {
  rdrag.target[0] = 0;
  if (rdrag.kind == RDRAG_TREE) {
    int i = (int)SDL_floorf((y - TREE_TOP + 1) / TAB_ROW);
    if (y < TREE_TOP || i < 0 || i >= g_viewer_panel_n || g_tree_grid[i]) return;   // (not onto thumbnails)
    const char *t = g_viewer_panel_paths[i];
    char pa[256], pb[256];
    parent_of(rdrag.path, pa, sizeof pa);
    parent_of(t, pb, sizeof pb);
    if (!strcmp(t, rdrag.path) || strcmp(pa, pb) || !strcmp(t, "/")) return;
    SDL_strlcpy(rdrag.target, t, sizeof rdrag.target);
    rdrag.after = y - (TREE_TOP + i * TAB_ROW) > TAB_ROW / 2;
  } else if (rdrag.kind == RDRAG_SYSTEM) {
    int r = prop_row_at(y);
    if (r < 0 || prop.rows[r].kind != 'c' || prop.rows[r].depth != 0 || !strcmp(prop.rows[r].label, rdrag.comp)) return;
    SDL_strlcpy(rdrag.target, prop.rows[r].label, sizeof rdrag.target);
    rdrag.after = y - (prop.y0 + (r - prop.scroll) * TAB_ROW) > TAB_ROW / 2;
  }
}

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

// drop: rewrite the order (Lua), refresh what depends on it
static void rdrag_drop(Viewer *V) {
  lua_State *L = V->L;
  if (!rdrag.target[0] || V->world == LUA_NOREF) return;
  int top = lua_gettop(L);
  if (rdrag.kind == RDRAG_TREE) {
    lua_getglobal(L, "viewer_tree_move");
    lua_rawgeti(L, LUA_REGISTRYINDEX, V->world);
    lua_pushstring(L, rdrag.path);
    lua_pushstring(L, rdrag.target);
    lua_pushboolean(L, rdrag.after);
    if (lua_pcall(L, 4, 1, 0) != 0) ov_log(OV_ERROR, "reorder: %s", lua_tostring(L, -1));
  } else {
    lua_getglobal(L, "viewer_system_move");
    lua_rawgeti(L, LUA_REGISTRYINDEX, V->world);
    lua_pushstring(L, rdrag.path);
    lua_pushstring(L, rdrag.comp);
    lua_pushstring(L, rdrag.target);
    lua_pushboolean(L, rdrag.after);
    if (lua_pcall(L, 5, 1, 0) != 0) ov_log(OV_ERROR, "reorder: %s", lua_tostring(L, -1));
  }
  lua_settop(L, top);
  if (!V->standalone) world_status(V);             // Save / Undo light up
}

