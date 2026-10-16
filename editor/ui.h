// editor/ui.h - small UI helpers: text fitting, selection, one-line text editing.
// Part of replay.c: included once, in order, from there (one compilation unit).

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
// one-line text editing in C, where lite isn't there to do it (the project
// launcher, the console without lite): the code editor's keys, as lite's
// text boxes have them (plugins/textproxy.lua): SHIFT + a move selects,
// CTRL+LEFT / RIGHT a word, CTRL+BACKSPACE / DELETE a word, CTRL+A all,
// CTRL+C / X / V, CTRL+Z / Y (CTRL+SHIFT+Z), CTRL+U the line; a click places
// the caret (SHIFT: selects to it), a drag selects, a double-click a word.
// ---------------------------------------------------------------------------

#define LE_UNDO 32
typedef struct { char s[512]; int cur, anchor; } LineSnap;
typedef struct {
  char s[512]; int len, cur, view;
  int anchor;                      // the selection's other end (== cur: none)
  LineSnap undo[LE_UNDO], redo[LE_UNDO]; int nundo, nredo;
  Uint64 last_edit; int last_kind; // (typing merges into one undo step while it goes on)
} LineEd;

static bool utf8_cont(char c) { return ((unsigned char)c & 0xC0) == 0x80; }

static void le_sel(const LineEd *e, int *a, int *b) { *a = SDL_min(e->cur, e->anchor); *b = SDL_max(e->cur, e->anchor); }
static bool le_has_sel(const LineEd *e) { return e->cur != e->anchor; }

static void le_push(LineSnap *st, int *n, const LineEd *e) {
  if (*n == LE_UNDO) { memmove(st, st + 1, sizeof st[0] * (LE_UNDO - 1)); (*n)--; }
  LineSnap *u = &st[(*n)++];
  SDL_strlcpy(u->s, e->s, sizeof u->s); u->cur = e->cur; u->anchor = e->anchor;
}
static void le_snap(LineEd *e, int kind) {         // before a change: its undo step (kind 1: typing, merged while it goes on)
  Uint64 now = SDL_GetTicks();
  e->nredo = 0;
  if (kind && kind == e->last_kind && now - e->last_edit < 800 && e->nundo) { e->last_edit = now; return; }
  le_push(e->undo, &e->nundo, e);
  e->last_edit = now; e->last_kind = kind;
}
static void le_undo(LineEd *e, bool redo) {         // CTRL+Z (redo: CTRL+Y, CTRL+SHIFT+Z)
  LineSnap *from = redo ? e->redo : e->undo;
  int *nf = redo ? &e->nredo : &e->nundo;
  if (!*nf) return;
  if (redo) le_push(e->undo, &e->nundo, e); else le_push(e->redo, &e->nredo, e);
  LineSnap *u = &from[--(*nf)];
  SDL_strlcpy(e->s, u->s, sizeof e->s);
  e->len = (int)strlen(e->s);
  e->cur = SDL_min(u->cur, e->len); e->anchor = SDL_min(u->anchor, e->len);
  e->last_kind = 0;
}

static void le_set(LineEd *e, const char *t) {      // a new text (history, the host's): the caret at its end
  if (strcmp(e->s, t)) le_snap(e, 0);
  SDL_strlcpy(e->s, t, sizeof e->s);
  e->len = e->cur = e->anchor = (int)strlen(e->s);
  e->view = 0;
}
static void le_select_all(LineEd *e) { e->anchor = 0; e->cur = e->len; }

static void le_cut_sel(LineEd *e) {                 // the selection out (no undo step: the caller made it)
  int a, b;
  le_sel(e, &a, &b);
  if (a == b) return;
  memmove(e->s + a, e->s + b, (size_t)(e->len - b + 1));
  e->len -= b - a;
  e->cur = e->anchor = a;
}
static void le_insert(LineEd *e, const char *t) {   // typed or pasted: replaces the selection
  le_snap(e, le_has_sel(e) ? 0 : 1);
  le_cut_sel(e);
  for (; *t; t++) {
    char c = *t;
    if (c == '\r') continue;
    if (c == '\n' || c == '\t') c = ' ';          // (one line: pasted lines join it)
    else if ((unsigned char)c < 32) continue;
    if (e->len >= (int)sizeof e->s - 1) break;
    memmove(e->s + e->cur + 1, e->s + e->cur, (size_t)(e->len - e->cur + 1));
    e->s[e->cur++] = c;
    e->len++;
  }
  e->anchor = e->cur;
}

static int le_step(const LineEd *e, int i, int d) { // a character left (-1) / right (+1)
  if (d < 0) { while (i > 0 && utf8_cont(e->s[--i])) {} }
  else if (i < e->len) { i++; while (i < e->len && utf8_cont(e->s[i])) i++; }
  return i;
}
static bool le_wordc(char c) { return SDL_isalnum((unsigned char)c) || c == '_' || ((unsigned char)c & 0x80); }
static int le_word(const LineEd *e, int i, int d) { // to the start of the word before (-1) / the end of the one after (+1)
  if (d < 0) {
    while (i > 0 && !le_wordc(e->s[i - 1])) i--;
    while (i > 0 && le_wordc(e->s[i - 1])) i--;
  } else {
    while (i < e->len && !le_wordc(e->s[i])) i++;
    while (i < e->len && le_wordc(e->s[i])) i++;
  }
  return i;
}
static void le_move(LineEd *e, int to, bool shift) { e->cur = to < 0 ? 0 : to > e->len ? e->len : to; if (!shift) e->anchor = e->cur; }

static void le_copy(const LineEd *e) {
  int a, b; char buf[512];
  le_sel(e, &a, &b);
  if (a == b) return;
  SDL_snprintf(buf, sizeof buf, "%.*s", b - a, e->s + a);
  SDL_SetClipboardText(buf);
}

// editing keys (mod: SDL's modifiers); returns false for keys it doesn't handle
static bool le_key(LineEd *e, SDL_Keycode k, SDL_Keymod mod) {
  bool ctrl = (mod & SDL_KMOD_CTRL) != 0, shift = (mod & SDL_KMOD_SHIFT) != 0;
  switch (k) {
  case SDLK_LEFT:
    if (!shift && !ctrl && le_has_sel(e)) { int a, b; le_sel(e, &a, &b); le_move(e, a, false); return true; }
    le_move(e, ctrl ? le_word(e, e->cur, -1) : le_step(e, e->cur, -1), shift); return true;
  case SDLK_RIGHT:
    if (!shift && !ctrl && le_has_sel(e)) { int a, b; le_sel(e, &a, &b); le_move(e, b, false); return true; }
    le_move(e, ctrl ? le_word(e, e->cur, 1) : le_step(e, e->cur, 1), shift); return true;
  case SDLK_HOME: le_move(e, 0, shift); return true;
  case SDLK_END: le_move(e, e->len, shift); return true;
  case SDLK_BACKSPACE: case SDLK_DELETE:
    le_snap(e, 0);
    if (!le_has_sel(e)) {
      int to = k == SDLK_BACKSPACE ? (ctrl ? le_word(e, e->cur, -1) : le_step(e, e->cur, -1))
                                   : (ctrl ? le_word(e, e->cur, 1) : le_step(e, e->cur, 1));
      e->anchor = to;
    }
    le_cut_sel(e);
      return true;
  case SDLK_A: if (!ctrl) return false; le_select_all(e); return true;
  case SDLK_C: if (!ctrl) return false; le_copy(e); return true;
  case SDLK_X: if (!ctrl) return false; if (le_has_sel(e)) { le_copy(e); le_snap(e, 0); le_cut_sel(e); } return true;
  case SDLK_V: if (!ctrl) return false;
    { char *c = SDL_GetClipboardText(); if (c) { le_snap(e, 0); e->last_kind = 0; le_insert(e, c); SDL_free(c); } }
    return true;
  case SDLK_Z: if (!ctrl) return false; le_undo(e, shift); return true;
  case SDLK_Y: if (!ctrl) return false; le_undo(e, true); return true;
  case SDLK_U: if (!ctrl) return false; le_set(e, ""); return true;
  }
  return false;
}

// the mouse: at byte index i (the caller measures where it landed); clicks
// 2: the word; shift: the selection to it. le_drag: while held
static void le_click(LineEd *e, int i, int clicks, bool shift) {
  i = i < 0 ? 0 : i > e->len ? e->len : i;
  while (i > 0 && utf8_cont(e->s[i])) i--;
  if (clicks >= 3) { le_select_all(e); return; }
  if (clicks == 2) {
    int a = i, b = i;
    while (a > 0 && le_wordc(e->s[a - 1])) a--;
    while (b < e->len && le_wordc(e->s[b])) b++;
    e->anchor = a; e->cur = b;
    return;
  }
  e->cur = i;
  if (!shift) e->anchor = i;
}
static void le_drag(LineEd *e, int i) { i = i < 0 ? 0 : i > e->len ? e->len : i; while (i > 0 && utf8_cont(e->s[i])) i--; e->cur = i; }
// the byte index nearest to x px in its text (w(prefix) measures a prefix)
static int le_index_at(const LineEd *e, float x, float (*w)(const char *)) {
  char buf[512];
  int best = 0; float bd = 1e9f;
  for (int i = 0; i <= e->len; i = le_step(e, i, 1)) {
    SDL_snprintf(buf, sizeof buf, "%.*s", i, e->s);
    float d = SDL_fabsf(w(buf) - x);
    if (d < bd) { bd = d; best = i; }
    if (i == e->len) break;
  }
  return best;
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
  if (le_has_sel(e)) {                             // the selection behind it
    int a, bb;
    le_sel(e, &a, &bb);
    char pre[600];
    a = SDL_max(a, e->view); bb = SDL_max(bb, e->view);
    SDL_snprintf(pre, sizeof pre, "%.*s", a - e->view, e->s + e->view);
    float x0 = x + ui_w(pre);
    SDL_snprintf(pre, sizeof pre, "%.*s", bb - e->view, e->s + e->view);
    float x1 = SDL_min(x + ui_w(pre), x + w);
    ui_color(r, ui.selection);
    SDL_RenderFillRect(r, &(SDL_FRect){ x0, y - 1, x1 - x0, TAB_ROW });
  }
  ui_color(r, col);
  ui_text(r, x, y, buf);
  if (caret) {
    ui_color(r, ui.caret);
    SDL_FRect c = { cx, y - 1, g_lite_font ? 2 : 1, TAB_ROW };
    SDL_RenderFillRect(r, &c);
  }
}
