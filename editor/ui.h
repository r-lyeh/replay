// editor/ui.h - small UI helpers: text fitting, selection, one-line text editing.
// Part of play.c: included once, in order, from there (one compilation unit).

// ---------------------------------------------------------------------------
// tab helpers
// ---------------------------------------------------------------------------

// lite's look (editor/editor.c: editor_ui_*): the tab, its drop-downs, tooltips and
// the bar use lite's UI font and its theme's colours, read each frame
// (ui_begin), so a theme or font change in lite shows here at once. Without
// lite (game only): SDL's 8 px debug font, lite's default colours.
typedef struct {
  SDL_Color bg, bg2, bg3;                          // style.background (code), background2 (side bar), background3 (popups)
  SDL_Color text, accent, dim, caret, divider, selection, hilite, line, warn, error;   // hilite: line_highlight; line: scrollbar2
  SDL_Color scroll;                                // style.scrollbar
  SDL_Color pane, pane_hover, pane_drag;           // a split you can drag (this lite's node.lua: style.pane_divider*)
  SDL_Color normal, comment, keyword, keyword2, number, literal, string, op, func;      // style.syntax
} UiLook;
static const UiLook UI_DARK = {                    // (lite's own defaults: core/style.lua)
  { 0x2e, 0x2e, 0x32, 255 }, { 0x25, 0x25, 0x29, 255 }, { 0x25, 0x25, 0x29, 255 },
  { 0x97, 0x97, 0x9c, 255 }, { 0xe1, 0xe1, 0xe6, 255 }, { 0x52, 0x52, 0x57, 255 }, { 0x93, 0xdd, 0xfa, 255 },
  { 0x20, 0x20, 0x24, 255 }, { 0x48, 0x48, 0x4f, 255 }, { 0x34, 0x34, 0x38, 255 }, { 0x4b, 0x4b, 0x52, 255 },
  { 0xe5, 0xa2, 0x3a, 255 }, { 0xe0, 0x6c, 0x75, 255 },
  { 0x41, 0x41, 0x46, 255 },
  { 0x2a, 0x3c, 0x44, 255 }, { 0x3a, 0x7d, 0x90, 255 }, { 0x3f, 0xb8, 0xd8, 255 },
  { 0xe1, 0xe1, 0xe6, 255 }, { 0x67, 0x6b, 0x6f, 255 }, { 0xe5, 0x8a, 0xc9, 255 }, { 0xf7, 0x74, 0x83, 255 },
  { 0xff, 0xa9, 0x4d, 255 }, { 0xff, 0xa9, 0x4d, 255 }, { 0xf7, 0xc9, 0x5c, 255 }, { 0x93, 0xdd, 0xfa, 255 },
  { 0x93, 0xdd, 0xfa, 255 } };
// the light theme's (data/themes/replay_light.lua), for when lite isn't
// running (the project picker at launch): the same colours
static const UiLook UI_LIGHT = {
  { 0xdf, 0xe0, 0xe2, 255 }, { 0xcb, 0xcb, 0xcc, 255 }, { 0xff, 0xff, 0xff, 255 },
  { 0x5b, 0x5f, 0x68, 255 }, { 0x2b, 0x2f, 0x36, 255 }, { 0xa3, 0xa7, 0xaf, 255 }, { 0x0b, 0x97, 0xb0, 255 },
  { 0xdc, 0xde, 0xe2, 255 }, { 0xbf, 0xe5, 0xee, 255 }, { 0xe5, 0xe8, 0xeb, 255 }, { 0xb2, 0xb6, 0xbd, 255 },
  { 0xa6, 0x5e, 0x08, 255 }, { 0xc8, 0x32, 0x3f, 255 },
  { 0xd3, 0xd6, 0xdb, 255 },
  { 0xc4, 0xe2, 0xe8, 255 }, { 0x7c, 0xc8, 0xd6, 255 }, { 0x1a, 0xa6, 0xc0, 255 },
  { 0x4f, 0x54, 0x5d, 255 }, { 0x87, 0x8d, 0x96, 255 }, { 0xa8, 0x31, 0x8f, 255 }, { 0xc8, 0x3a, 0x50, 255 },
  { 0xb8, 0x46, 0x0b, 255 }, { 0xb8, 0x46, 0x0b, 255 }, { 0x2e, 0x85, 0x40, 255 }, { 0x0a, 0x81, 0x99, 255 },
  { 0x0a, 0x81, 0x99, 255 } };
static UiLook ui;                                  // this frame's (ui_begin)
static bool g_ui_light;                            // the Theme setting (settings.h): without lite, UI_LIGHT
static float g_font_h = 8;                         // the font's line height, px
static float g_tab_row = 10;                       // a row: the font's height + a little
static bool g_lite_font;                           // (false: the debug font)
#define TAB_ROW g_tab_row
#define TAB_TOP (TAB_ROW + 8)                      // first row below a header (props)
#define TOOLS_H 28.f                               // toolbar at the top of the tab
#define TREE_FILTER_Y (TOOLS_H + 4)                // the tree's filter box, under the toolbar
#define TREE_TOP (TREE_FILTER_Y + TAB_ROW + 8)     // first tree row (under the filter)
#define ROW_MID(y) ((y) - 1 + SDL_floorf((TAB_ROW - 1) / 2))   // a row's middle (rows drawn at y: [y - 1, y - 1 + TAB_ROW))

static void ui_begin(void) {                       // once a frame, before drawing
  int fh = editor_running() ? editor_ui_begin() : 0;
  g_lite_font = fh > 0;
  g_font_h = g_lite_font ? (float)fh : 8;
  g_tab_row = g_lite_font ? (float)fh + 4 : 10;
  static const struct { const char *key; size_t at; } K[] = {
    { "background", offsetof(UiLook, bg) }, { "background2", offsetof(UiLook, bg2) }, { "background3", offsetof(UiLook, bg3) },
    { "text", offsetof(UiLook, text) }, { "accent", offsetof(UiLook, accent) }, { "dim", offsetof(UiLook, dim) },
    { "caret", offsetof(UiLook, caret) }, { "divider", offsetof(UiLook, divider) }, { "selection", offsetof(UiLook, selection) },
    { "line_highlight", offsetof(UiLook, hilite) }, { "scrollbar2", offsetof(UiLook, line) }, { "warn", offsetof(UiLook, warn) },
    { "error", offsetof(UiLook, error) }, { "scrollbar", offsetof(UiLook, scroll) },
    { "pane_divider", offsetof(UiLook, pane) }, { "pane_divider_hover", offsetof(UiLook, pane_hover) },
    { "pane_divider_drag", offsetof(UiLook, pane_drag) }, { "syntax.normal", offsetof(UiLook, normal) }, { "syntax.comment", offsetof(UiLook, comment) },
    { "syntax.keyword", offsetof(UiLook, keyword) }, { "syntax.keyword2", offsetof(UiLook, keyword2) },
    { "syntax.number", offsetof(UiLook, number) }, { "syntax.literal", offsetof(UiLook, literal) },
    { "syntax.string", offsetof(UiLook, string) }, { "syntax.operator", offsetof(UiLook, op) }, { "syntax.function", offsetof(UiLook, func) } };
  ui = g_ui_light && !editor_running() ? UI_LIGHT : UI_DARK;   // (a colour the theme doesn't set: lite's default, not the last theme's)
  if (editor_running())
    for (size_t i = 0; i < SDL_arraysize(K); i++) editor_ui_color(K[i].key, (SDL_Color *)((char *)&ui + K[i].at));
}
static void ui_color(SDL_Renderer *r, SDL_Color c) { SDL_SetRenderDrawColor(r, c.r, c.g, c.b, c.a); }
static void ui_colora(SDL_Renderer *r, SDL_Color c, Uint8 a) { SDL_SetRenderDrawColor(r, c.r, c.g, c.b, a); }
static SDL_Color ui_mix(SDL_Color a, SDL_Color b, float t) {   // a .. b
  return (SDL_Color){ (Uint8)(a.r + (b.r - a.r) * t), (Uint8)(a.g + (b.g - a.g) * t), (Uint8)(a.b + (b.b - a.b) * t), 255 };
}
static float ui_w(const char *s) {                 // its width, px
  return g_lite_font ? editor_ui_text(NULL, 0, 0, s, (SDL_Color){ 0 }) : 8.f * (float)strlen(s);
}
// text in the draw colour, centred in [top, top + h) -> the x after it
static float ui_text_in(SDL_Renderer *r, float x, float top, float h, const char *s) {
  SDL_Color c;
  SDL_GetRenderDrawColor(r, &c.r, &c.g, &c.b, &c.a);
  float y = top + SDL_floorf((h - g_font_h) / 2);
  if (g_lite_font) return editor_ui_text(r, x, y, s, c);
  SDL_RenderDebugText(r, x, y, s);
  return x + 8.f * (float)strlen(s);
}
static float ui_text(SDL_Renderer *r, float x, float y, const char *s) { return ui_text_in(r, x, y - 1, TAB_ROW, s); }   // (in a row drawn at y)

// A scrollbar like lite's (core/view.lua: View:draw_scrollbar): a thumb only,
// style.scrollbar (scrollbar2 under the mouse or dragged), 4 px wide at the
// right of what it scrolls, drawn over it (after it). In rows: `total` of
// them, `shown` fit, the first shown is `first`. Only the thumb (a little
// wider than drawn) takes the mouse, as in lite: what's under the rest of it
// (a drop-down's arrow) stays clickable.
typedef struct { float x, top, h; int total, shown, first; } Scroll;   // x: its right edge
#define SCROLL_W 4.f
static bool scroll_on(const Scroll *s) { return s->total > s->shown && s->shown > 0 && s->h > 0; }
static SDL_FRect scroll_thumb(const Scroll *s) {
  float th = SDL_max(20.f, s->h * s->shown / s->total);
  if (th > s->h) th = s->h;
  float y = s->top + (s->total > s->shown ? (s->h - th) * s->first / (float)(s->total - s->shown) : 0);
  return (SDL_FRect){ s->x - SCROLL_W, SDL_floorf(y), SCROLL_W, SDL_floorf(th) };
}
static bool scroll_hit(const Scroll *s, float mx, float my) {
  if (!scroll_on(s)) return false;
  SDL_FRect t = scroll_thumb(s);
  return mx >= t.x - 3 && mx < t.x + t.w + 2 && my >= t.y && my < t.y + t.h;
}
// the first row for the thumb's top at (my - grab): its drag
static int scroll_first_at(const Scroll *s, float my, float grab) {
  SDL_FRect t = scroll_thumb(s);
  float span = s->h - t.h;
  if (span <= 0) return 0;
  int f = (int)SDL_lroundf((my - grab - s->top) / span * (s->total - s->shown));
  return f < 0 ? 0 : f > s->total - s->shown ? s->total - s->shown : f;
}
// a press on its thumb -> where it was grabbed (first: the row shown first, as it was)
static float scroll_press(const Scroll *s, float my, int *first) {
  *first = s->first;
  return my - scroll_thumb(s).y;
}
static void scroll_draw(SDL_Renderer *r, const Scroll *s, bool hot) {
  if (!scroll_on(s)) return;
  SDL_Color c = ui.scroll;
  if (hot) c = ui.line;
  SDL_FRect t = scroll_thumb(s);
  ui_color(r, c);
  SDL_RenderFillRect(r, &t);
}
// the scrollbar being dragged (play.c): which one, where it was grabbed
enum { DRAG_SB_NONE, DRAG_SB_TREE, DRAG_SB_PROPS, DRAG_SB_PICK, DRAG_SB_PICK_SUB };
static struct { int which; float grab; } sbdrag;
// the wheel: whole rows, keeping what's left of a fine (touchpad, smooth
// wheel) step for the next one -> rows to scroll (positive: down)
static int wheel_rows(float y, float *rest) {
  *rest += -y * 3;
  int n = (int)*rest;
  *rest -= (float)n;
  return n;
}

// copy s into dst, cut with ".." to fit w px
static const char *fit(char *dst, size_t cap, const char *s, float w) {
  SDL_strlcpy(dst, s, cap);
  if (ui_w(dst) <= w) return dst;
  size_t n = strlen(dst);
  while (n > 0) {
    do n--; while (n > 0 && ((unsigned char)dst[n] & 0xC0) == 0x80);   // (whole UTF-8 characters)
    SDL_snprintf(dst, cap, "%.*s..", (int)n, s);
    if (ui_w(dst) <= w) return dst;
  }
  SDL_strlcpy(dst, "..", cap);
  return dst;
}

// The tree tab: a column on the left, the game area starts right after it.
static bool in_rect(const SDL_FRect *r, float x, float y) {
  return x >= r->x && y >= r->y && x < r->x + r->w && y < r->y + r->h;
}

// ---------------------------------------------------------------------------
// selection: one primary node (V->selected) plus more (Ctrl+click)
// ---------------------------------------------------------------------------

#define SEL_MORE 64
static char sel_more[SEL_MORE][256];

static bool is_selected(Viewer *V, const char *p) {
  if (!p || !p[0]) return false;
  if (V->selected[0] && !strcmp(V->selected, p)) return true;
  for (int i = 0; i < nsel_more; i++) if (!strcmp(sel_more[i], p)) return true;
  return false;
}

// the toolbar's Gizmos: a node's gizmo shows when it, or a node above it, is
// selected (the root selected: all of them)
static bool path_under(const char *p, const char *top) {
  size_t n = strlen(top);
  if (!n) return false;
  if (!strcmp(top, "/")) return true;
  return !strncmp(p, top, n) && (p[n] == 0 || p[n] == '/');
}
static bool gizmo_wanted(Viewer *V, const char *p) {
  if (!p || !p[0]) return false;
  if (path_under(p, V->selected)) return true;
  for (int i = 0; i < nsel_more; i++) if (path_under(p, sel_more[i])) return true;
  return false;
}

// Ctrl+click: add or remove a node, without opening it in the editor
static void sel_toggle(Viewer *V, const char *p) {
  if (V->selected[0] && !strcmp(V->selected, p)) {   // drop the primary: next one moves up
    if (nsel_more) {
      SDL_strlcpy(V->selected, sel_more[0], sizeof V->selected);
      memmove(sel_more[0], sel_more[1], sizeof sel_more[0] * (size_t)(nsel_more - 1));
      nsel_more--;
    } else V->selected[0] = 0;
    V->via[0] = 0;
    return;
  }
  for (int i = 0; i < nsel_more; i++) {
    if (!strcmp(sel_more[i], p)) {
      memmove(sel_more[i], sel_more[i + 1], sizeof sel_more[0] * (size_t)(nsel_more - i - 1));
      nsel_more--;
      return;
    }
  }
  if (!V->selected[0]) { SDL_strlcpy(V->selected, p, sizeof V->selected); V->via[0] = 0; }
  else if (nsel_more < SEL_MORE) SDL_strlcpy(sel_more[nsel_more++], p, sizeof sel_more[0]);
}

static void sel_clear(Viewer *V) { V->selected[0] = 0; V->via[0] = 0; nsel_more = 0; }

// pushes { primary, more... } (the selection as a Lua array)
static void push_selection(lua_State *L, Viewer *V) {
  lua_newtable(L);
  int k = 0;
  if (V->selected[0]) { lua_pushstring(L, V->selected); lua_rawseti(L, -2, ++k); }
  for (int i = 0; i < nsel_more; i++) { lua_pushstring(L, sel_more[i]); lua_rawseti(L, -2, ++k); }
}

// ---------------------------------------------------------------------------
// one-line text editing (console, property values)
// ---------------------------------------------------------------------------

typedef struct { char s[512]; int len, cur, view; bool all; } LineEd;   // all: text selected

static bool utf8_cont(char c) { return ((unsigned char)c & 0xC0) == 0x80; }

static void le_set(LineEd *e, const char *t) {
  SDL_strlcpy(e->s, t, sizeof e->s);
  e->len = e->cur = (int)strlen(e->s);
  e->view = 0;
  e->all = false;
}

static void le_select_all(LineEd *e) { e->all = e->len > 0; }

static void le_insert(LineEd *e, const char *t) {
  if (e->all) le_set(e, "");                       // typing replaces a selected value
  for (; *t; t++) {
    if ((unsigned char)*t < 32) continue;         // pasted newlines/tabs: dropped
    if (e->len >= (int)sizeof e->s - 1) break;
    memmove(e->s + e->cur + 1, e->s + e->cur, (size_t)(e->len - e->cur + 1));
    e->s[e->cur++] = *t;
    e->len++;
  }
}

// editing keys; returns false for keys it doesn't handle
static bool le_key(LineEd *e, SDL_Keycode k, bool ctrl) {
  if (e->all && (k == SDLK_BACKSPACE || k == SDLK_DELETE)) { le_set(e, ""); return true; }
  if (k == SDLK_A && ctrl) { le_select_all(e); return true; }
  if (k == SDLK_LEFT || k == SDLK_RIGHT || k == SDLK_HOME || k == SDLK_END) e->all = false;
  switch (k) {
  case SDLK_BACKSPACE:
    while (e->cur > 0) {
      bool c = utf8_cont(e->s[e->cur - 1]);
      memmove(e->s + e->cur - 1, e->s + e->cur, (size_t)(e->len - e->cur + 1));
      e->cur--; e->len--;
      if (!c) break;
    }
    return true;
  case SDLK_DELETE:
    while (e->cur < e->len) {
      memmove(e->s + e->cur, e->s + e->cur + 1, (size_t)(e->len - e->cur));
      e->len--;
      if (!utf8_cont(e->s[e->cur])) break;
    }
    return true;
  case SDLK_LEFT:  while (e->cur > 0 && utf8_cont(e->s[--e->cur])) {} return true;
  case SDLK_RIGHT: while (e->cur < e->len && utf8_cont(e->s[++e->cur])) {} return true;
  case SDLK_HOME: e->cur = 0; return true;
  case SDLK_END:  e->cur = e->len; return true;
  case SDLK_V: if (!ctrl) return false;
    { char *c = SDL_GetClipboardText(); if (c) { le_insert(e, c); SDL_free(c); } }
    return true;
  case SDLK_U: if (!ctrl) return false; le_set(e, ""); return true;
  }
  return false;
}

// the line at x,y in w px (scrolled so the caret shows), in a row drawn at y
static void le_draw(SDL_Renderer *r, LineEd *e, float x, float y, float w, bool caret, SDL_Color col) {
  char buf[600];
  if (e->cur < e->view) e->view = e->cur;
  if (e->view > e->len) e->view = 0;
  for (;;) {                                       // the caret past the right: scroll on
    SDL_snprintf(buf, sizeof buf, "%.*s", e->cur - e->view, e->s + e->view);
    if (e->view >= e->cur || ui_w(buf) <= w - 2) break;
    while (e->view < e->cur && utf8_cont(e->s[++e->view])) {}
  }
  float cx = x + ui_w(buf);
  int n = e->len - e->view;                        // what fits from there
  SDL_snprintf(buf, sizeof buf, "%s", e->s + e->view);
  while (n > 0 && ui_w(buf) > w) { while (n > 0 && utf8_cont(buf[--n])) {} buf[n] = 0; }
  if (e->all) {                                    // selected: it will be replaced
    SDL_FRect sel = { x - 1, y - 1, ui_w(buf) + 2, TAB_ROW };
    ui_color(r, ui.selection);
    SDL_RenderFillRect(r, &sel);
  }
  ui_color(r, col);
  ui_text(r, x, y, buf);
  if (caret) {
    ui_color(r, ui.caret);
    SDL_FRect c = { cx, y - 1, g_lite_font ? 2 : 1, TAB_ROW };
    SDL_RenderFillRect(r, &c);
  }
}
