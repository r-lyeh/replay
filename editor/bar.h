// editor/bar.h - the status bar: buttons, timeline, console, tooltips, screenshots.
// Part of replay.c: included once, in order, from there (one compilation unit).

// ---------------------------------------------------------------------------
// status bar: full window width, below the tree tab and the game area
//   [play/pause] [stop] [rewind] [power] [players] [network] [speed]  [==== timeline ====|------]  t / total  xN
// ---------------------------------------------------------------------------

#define VIEW_BUTTON 1                              // 1: the 2nd toolbar button (game / mixed / editor views)
static int BAR_H = 28;                             // status bar height (0 when standalone)
#define TIP_DELAY_MS 400                           // mouse rest before tooltips show

// status bar buttons, left to right
enum { BTN_SAVE, BTN_EXPORT, BTN_FADE, BTN_GIZMO, BTN_PICK, BTN_CAM, BTN_MENU, BTN_PLAY, BTN_STOP, BTN_REW, BTN_POWER, BTN_PLAYERS, BTN_NET, BTN_SPEED, BTN_N };
typedef struct { SDL_FRect btn[BTN_N], track, con; } Bar;

static int g_tab_w;                                // tree tab width (0 = no tab)
static SDL_AtomicInt g_export_state;               // Export (export.h): 0 idle, 1 its dialog open, 2 answered
static void export_name(const Viewer *V, char *out, size_t n);

// save, export | fade, gizmo, picking, camera: toolbar at the top of the tree tab;
// play, stop, rewind, speed: left end of the status bar
static Bar bar_layout(int w, int h) {
  Bar b;
  float x = 4;
  for (int i = BTN_SAVE; i <= BTN_CAM; i++) {
    if (i == BTN_FADE && !VIEW_BUTTON) { b.btn[i] = (SDL_FRect){ -100, -100, 0, 0 }; continue; }   // hidden for now
    if (i == BTN_EXPORT + 1) x += 8;               // save, export | the rest
    b.btn[i] = g_tab_w > 0 && x + 24 <= g_tab_w - 32 ? (SDL_FRect){ x, 2, 24, 24 } : (SDL_FRect){ -100, -100, 0, 0 };   // (a narrow tab: what doesn't fit before the menu is left out, not drawn over it)
    x += 28;
  }
  // the main menu, right-aligned: a menu (see burger below)
  b.btn[BTN_MENU] = g_tab_w > 0 ? (SDL_FRect){ g_tab_w - 28.f, 2, 24, 24 } : (SDL_FRect){ -100, -100, 0, 0 };
  float y = (float)(h - BAR_H);
  x = 4;
  for (int i = BTN_PLAY; i <= BTN_SPEED; i++) {
    b.btn[i] = (SDL_FRect){ x, y + 2, 24, 24 };
    x += 28;
  }
  float cw = w * 0.30f;                            // console: the right part of the bar
  if (cw < 200) cw = 200;
  if (cw > 520) cw = 520;
  b.con   = (SDL_FRect){ w - cw - 4, y + 3, cw, 22 };
  b.track = (SDL_FRect){ x + 6, y + 3, b.con.x - x - 16, 22 };
  if (b.track.w < 20) b.track.w = 20;
  return b;
}

// The one rule for every button: enabled = bright, hover highlight, hand
// cursor, clickable; disabled = dim, no highlight, arrow, ignored. Toggles
// (gizmos, picking, power) are white when on, dim when off (still clickable);
// yellow is kept for Save's unsaved edits.
// The speed button: a click goes to the next whole step, x1 x2 x3 x4 x1
// (x1.23 -> x2); the wheel fine-tunes it from x0.01 to x4.00 in 0.05 steps.
static float speed_next(const Viewer *V) { return (float)((int)V->speed % 4 + 1); }
static float speed_wheel(const Viewer *V, float dir) {
  float s = SDL_roundf((V->speed + (dir > 0 ? 0.05f : -0.05f)) * 20) / 20;
  return s < 0.01f ? 0.01f : s > 4 ? 4 : s;          // never 0: time always moves
}

// The power button: the network device (runtime/players.lua PL.mode). Off:
// the Players button's players are this computer's (local multiplayer); on:
// Play goes online (hosting, or joining an address). Set while stopped only.
static bool power_mode(const Viewer *V, bool *host, char *line, size_t n) {   // on? hosting? its line
  bool on = false;
  if (line) line[0] = 0;
  if (host) *host = true;
  int top = lua_gettop(V->L);
  lua_getglobal(V->L, "viewer_online_mode");
  if (lua_pcall(V->L, 0, 3, 0) == 0) {
    on = lua_toboolean(V->L, -3);
    if (host) *host = !SDL_strcmp(luaL_optstring(V->L, -2, "host"), "host");
    if (line && lua_isstring(V->L, -1)) SDL_strlcpy(line, lua_tostring(V->L, -1), n);
  }
  lua_settop(V->L, top);
  return on;
}
static int online_mask(const Viewer *V) {          // the Players button, the switch on: the seat (stopped) or who's in; -1: off
  int top = lua_gettop(V->L), mask = -1;
  lua_getglobal(V->L, "viewer_online_mask");
  if (lua_pcall(V->L, 0, 1, 0) == 0) mask = (int)lua_tonumber(V->L, -1);
  lua_settop(V->L, top);
  return mask;
}

static bool button_enabled(const Viewer *V, int id) {
  switch (id) {
  case BTN_POWER: return V->stopped && !V->standalone;   // (playing or paused: locked)
  case BTN_SAVE: return V->stopped && V->savable && V->dirty;
  case BTN_EXPORT: return V->path && V->path[0] && SDL_GetAtomicInt(&g_export_state) == 0;   // (not while its dialog is open)
  case BTN_CAM:  return !(V->camx == 0 && V->camy == 0 && V->zoom == 1);
  case BTN_STOP: return !V->stopped;
  case BTN_FADE: return editor_running();         // the game's opacity over the editor (each state its own)
  default:       return true;                      // play, speed, gizmos, picking, menu
  }
}

static int bar_button_at(const Bar *b, float x, float y) {
  for (int i = 0; i < BTN_N; i++) if (in_rect(&b->btn[i], x, y)) return i;
  return -1;
}

static void fill_tri(SDL_Renderer *ren, float x0, float y0, float x1, float y1,
                     float x2, float y2, SDL_FColor c) {
  SDL_Vertex v[3] = { { { x0, y0 }, c, { 0, 0 } }, { { x1, y1 }, c, { 0, 0 } },
                      { { x2, y2 }, c, { 0, 0 } } };
  SDL_RenderGeometry(ren, NULL, v, 3, NULL, 0);
}

// fps series of the snapshots, copied from Lua only when the timeline changed
static float *ser_t, *ser_f;
static int ser_n, ser_cap, ser_ver = -1;

static void series_sync(Viewer *V) {
  lua_State *L = V->L;
  lua_getglobal(L, "viewer_hist_series");
  lua_pushinteger(L, ser_ver);
  if (lua_pcall(L, 1, 3, 0) != 0) { lua_pop(L, 1); return; }
  int ver = (int)lua_tointeger(L, -3);
  if (ver != ser_ver && lua_istable(L, -2)) {
    int n = (int)objlen(L, -2);
    if (n > ser_cap) {
      ser_cap = n + 256;
      ser_t = (float *)SDL_realloc(ser_t, ser_cap * sizeof *ser_t);
      ser_f = (float *)SDL_realloc(ser_f, ser_cap * sizeof *ser_f);
    }
    for (int i = 0; i < n; i++) {
      lua_rawgeti(L, -2, i + 1); ser_t[i] = (float)lua_tonumber(L, -1); lua_pop(L, 1);
      lua_rawgeti(L, -1, i + 1); ser_f[i] = (float)lua_tonumber(L, -1); lua_pop(L, 1);
    }
    ser_n = n;
    ser_ver = ver;
  }
  lua_pop(L, 3);
}

// The timeline is drawn as an "fps equalizer": a centred strip whose
// thickness shows hitches. At the target fps (or above) it's a thin line;
// the lower the fps, the thicker (0 fps = full track height). Played part
// blue, the rest grey, like the plain timeline it replaces.
static float fps_target = 60;                      // what the timeline treats as full speed
static float fps_limit_arg = -1;                   // --fps: -1 = monitor Hz, 0 = unlimited, N
static float fps_limit;                            // the limit while focused (0 = unlimited)
static float g_monitor_hz;                         // the refresh rate of the display the window is on (0: unknown)

// focused: --fps N, else the menu's FPS (settings.h: 0 = the monitor's refresh rate)
static void update_fps_limit(SDL_Window *win) {
  float hz = 0;
  const SDL_DisplayMode *m = SDL_GetCurrentDisplayMode(SDL_GetDisplayForWindow(win));
  if (m && m->refresh_rate > 0) hz = m->refresh_rate;
  g_monitor_hz = hz;
  float set = (float)settings_fps();
  fps_limit = fps_limit_arg >= 0 ? fps_limit_arg : set > 0 ? set : hz;
  fps_target = fps_limit > 0 ? fps_limit : (hz > 0 ? hz : 60);
}
// the limit this frame: minimized or unfocused, the menu's (never faster than
// focused); else focused. Only the editor (not a standalone game, not a test)
static float fps_limit_now(SDL_Window *win, bool editor) {
  if (!editor) return fps_limit;
  SDL_WindowFlags f = SDL_GetWindowFlags(win);
  int v = (f & SDL_WINDOW_MINIMIZED) ? settings_fps_minimized() : !(f & SDL_WINDOW_INPUT_FOCUS) ? settings_fps_unfocused() : 0;
  if (v > 0 && (fps_limit <= 0 || v < fps_limit)) return (float)v;
  return fps_limit;
}

static float hitch_thickness(float fps, float full) {
  const float thin = 4;
  if (fps <= 0) return thin;                       // no measurement: draw it plain
  float k = 1 - fps / fps_target;
  if (k < 0) k = 0;
  if (k > 1) k = 1;
  return thin + (full - thin) * k;
}

static void band_rect(SDL_Renderer *r, float x0, float x1, float cy, float th, float split) {
  if (x1 <= x0) return;
  if (x0 < split) {                                // played: blue
    SDL_FRect a = { x0, cy - th / 2, (x1 < split ? x1 : split) - x0, th };
    ui_color(r, ui_mix(ui.bg, ui.caret, 0.55f));
    SDL_RenderFillRect(r, &a);
  }
  if (x1 > split) {                                // not played (future after a seek): grey
    float s0 = x0 > split ? x0 : split;
    SDL_FRect b = { s0, cy - th / 2, x1 - s0, th };
    ui_color(r, ui.line);
    SDL_RenderFillRect(r, &b);
  }
}

static void draw_timeline_band(Viewer *V, const SDL_FRect *tr, double len, float playhead) {
  SDL_Renderer *r = V->ren;
  series_sync(V);
  float cy = tr->y + tr->h / 2, full = tr->h;
  float x_end = tr->x;
  for (int i = 1; i < ser_n; i++) {                // sample i covers (t[i-1], t[i]]
    float x0 = SDL_floorf(tr->x + (float)(ser_t[i - 1] / len) * tr->w);   // whole pixels:
    float x1 = SDL_ceilf(tr->x + (float)(ser_t[i] / len) * tr->w);         // no hairline gaps
    if (x1 - x0 < 1) x1 = x0 + 1;
    band_rect(r, x0, x1, cy, hitch_thickness(ser_f[i], full), playhead);
    x_end = x1;
  }
  float x_now = tr->x + (float)(V->gtime / len) * tr->w;   // since the last snapshot
  if (x_now > x_end) band_rect(r, x_end, SDL_ceilf(x_now), cy, hitch_thickness(0, full), playhead);
}

// fps of the snapshot interval containing time t (0 if none)
static float fps_at(double t) {
  for (int i = 1; i < ser_n; i++)
    if (t <= ser_t[i]) return ser_f[i];
  return 0;
}

// recorded length vs the span the track shows: the span steps up like the
// length of a recorded video (30 s, 1 min, 2 min...), so the recording
// fills the track slowly from the left
static double timeline_span(double recorded) {
  static const double steps[] = { 30, 60, 120, 300, 600, 1200, 1800, 3600 };
  for (size_t i = 0; i < sizeof steps / sizeof steps[0]; i++)
    if (recorded <= steps[i]) return steps[i];
  return SDL_ceil(recorded / 3600) * 3600;
}

static double timeline_len(Viewer *V) {
  int n; double last;
  hist_info(V, &n, &last);
  double t = last > V->gtime ? last : V->gtime;
  return t < 0.5 ? 0.5 : t;
}

// ---------------------------------------------------------------------------
// console: one line of Lua against the live world (right part of the bar)
// ---------------------------------------------------------------------------

#define CON_HIST 64
static struct {
  bool focus;
  LineEd e;                        // the line being typed
  char out[1024];                  // last result (or error) of a run
  bool err;
  char hist[CON_HIST][512];        // previous lines, oldest first
  int nhist, hpos;                 // hpos == nhist: editing a new line
  Uint64 blink;                    // caret shown solid right after a key
} con;

static void con_run(Viewer *V) {
  if (!con.e.len) return;
  if (!con.nhist || strcmp(con.hist[con.nhist - 1], con.e.s)) {   // history, no repeats
    if (con.nhist == CON_HIST) { memmove(con.hist[0], con.hist[1], sizeof con.hist[0] * (CON_HIST - 1)); con.nhist--; }
    SDL_strlcpy(con.hist[con.nhist++], con.e.s, sizeof con.hist[0]);
  }
  con.hpos = con.nhist;
  lua_State *L = V->L;
  if (V->world == LUA_NOREF) {
    SDL_strlcpy(con.out, "no world loaded", sizeof con.out);
    con.err = true;
  } else {
    lua_getglobal(L, "viewer_eval");
    lua_rawgeti(L, LUA_REGISTRYINDEX, V->world);
    lua_pushstring(L, con.e.s);
    lua_pushstring(L, V->selected);
    if (lua_pcall(L, 3, 2, 0) != 0) {
      SDL_snprintf(con.out, sizeof con.out, "%s", lua_tostring(L, -1));
      con.err = true;
      lua_pop(L, 1);
    } else {
      con.err = !lua_toboolean(L, -2);
      const char *o = lua_tostring(L, -1);
      SDL_snprintf(con.out, sizeof con.out, "%s", o ? o : "");
      lua_pop(L, 2);
    }
  }
  printf("> %s\n%s %s\n", con.e.s, con.err ? "!" : "=", con.out);
  fflush(stdout);
  le_set(&con.e, "");
}

// The prompt types in lite while lite runs (plugins/textproxy.lua: its own
// editing, selection, words, clipboard, undo); lite's answers come back as
// host_call("prompt <what>") (menus.h -> prompt_host). Without lite: LineEd.
static bool con_lite;                              // typing in lite now
static bool con_drag;                              // a press in it, held: selecting
static float con_view;                             // scrolled this far (px) so the caret shows

// focus on/off; text input stays on while lite still has the keyboard
static void con_focus(SDL_Window *win, bool on, bool edfocus) {
  if (on == con.focus) return;
  con.focus = on;
  con.blink = SDL_GetTicks();
  bool was = con_lite;
  con_lite = false;
  if (on && editor_running()) con_lite = editor_prompt("focus", con.e.s, 0, 0, 0);
  if (!on && was) editor_prompt("blur", NULL, 0, 0, 0);
  if (on) SDL_StartTextInput(win);
  else if (!edfocus) SDL_StopTextInput(win);
}

// keyboard while the console has focus
static void con_event(Viewer *V, SDL_Window *win, const SDL_Event *e, bool edfocus) {
  if (e->type == SDL_EVENT_TEXT_INPUT) {
    const char *t = e->text.text;
    le_insert(&con.e, t);
    con.blink = SDL_GetTicks();
    return;
  }
  if (e->type != SDL_EVENT_KEY_DOWN) return;
  bool ctrl = (e->key.mod & SDL_KMOD_CTRL) != 0;
  con.blink = SDL_GetTicks();
  switch (e->key.key) {
  case SDLK_RETURN: case SDLK_KP_ENTER: con_run(V); break;
  case SDLK_ESCAPE: con_focus(win, false, edfocus); break;
  case SDLK_UP:
    if (con.hpos > 0) le_set(&con.e, con.hist[--con.hpos]);
    break;
  case SDLK_DOWN:
    if (con.hpos < con.nhist - 1) le_set(&con.e, con.hist[++con.hpos]);
    else { con.hpos = con.nhist; le_set(&con.e, ""); }
    break;
  case SDLK_C: if (ctrl) { if (le_has_sel(&con.e)) le_copy(&con.e); else SDL_SetClipboardText(con.e.len ? con.e.s : con.out); } break;
  case SDLK_L: if (ctrl) con.out[0] = 0; break;
  default: le_key(&con.e, e->key.key, e->key.mod); break;
  }
}

// does a text fit in the console field after the prompt?
static bool con_fits(const SDL_FRect *f, const char *t) { return ui_w(t) <= f->w - 15 - ui_w(">"); }

static void draw_console(Viewer *V, const SDL_FRect *f, bool hover) {
  // lite's look: what you type in its code colour, the rest dim
  SDL_Renderer *r = V->ren;
  ui_color(r, ui.bg);
  SDL_RenderFillRect(r, f);
  ui_color(r, con.focus || hover ? ui.dim : ui.line);
  SDL_RenderRect(r, f);
  float x = f->x + 6, ty = f->y + 1 + SDL_floorf((f->h - TAB_ROW) / 2);   // (a row: ui.h's ui_text)
  ui_color(r, ui.dim);
  x = ui_text(r, x, ty, ">") + 5;
  float room = f->x + f->w - 4 - x;
  bool caret = con.focus && ((SDL_GetTicks() - con.blink) / 530) % 2 == 0;
  char t[512];
  int cur, s1, s2;
  if (con.focus && con_lite && editor_prompt_get(t, sizeof t, &cur, &s1, &s2, &caret)) {   // typing in lite: its text, selection, caret
    le_set(&con.e, t);
    char pre[512];
    int n = (int)strlen(t);
    cur = cur < 0 ? 0 : cur > n ? n : cur;
    SDL_snprintf(pre, sizeof pre, "%.*s", cur, t);
    float cx = ui_w(pre);                           // (scrolled so the caret shows)
    if (cx - con_view > room - 3) con_view = cx - room + 3;
    if (cx < con_view) con_view = cx;
    if (ui_w(t) - con_view < room - 3 && con_view > 0) con_view = SDL_max(0.f, ui_w(t) - room + 3);
    SDL_Rect old;
    bool clipped = SDL_RenderClipEnabled(r);
    SDL_GetRenderClipRect(r, &old);
    SDL_SetRenderClipRect(r, &(SDL_Rect){ (int)x, (int)f->y, (int)room + 1, (int)f->h });
    float ox = x - con_view;
    editor_prompt("place", NULL, ox, ty, TAB_ROW); // (where a click lands: lite places the caret)
    if (s1 >= 0 && s2 > s1) {
      SDL_snprintf(pre, sizeof pre, "%.*s", s1, t);
      float a = ui_w(pre);
      SDL_snprintf(pre, sizeof pre, "%.*s", s2 > n ? n : s2, t);
      ui_color(r, ui.selection);
      SDL_RenderFillRect(r, &(SDL_FRect){ ox + a, ty - 1, ui_w(pre) - a, TAB_ROW });
    }
    ui_color(r, ui.normal);
    ui_text(r, ox, ty, t);
    if (caret) { ui_color(r, ui.caret); SDL_RenderFillRect(r, &(SDL_FRect){ ox + cx, ty - 1, g_lite_font ? 2 : 1, TAB_ROW }); }
    SDL_SetRenderClipRect(r, clipped ? &old : NULL);
    if (!n && !con.out[0]) return;
    if (n) return;
    caret = false;                                 // (empty: the last answer, dim, below)
  }
  if (con.e.len && !(con.focus && con_lite)) le_draw(r, &con.e, x, ty, room, caret, ui.normal);
  else {                                           // last answer (or a hint): dim
    char buf[600];
    con.e.view = 0;
    ui_color(r, ui.dim);
    ui_text(r, x, ty, fit(buf, sizeof buf, con.out[0] ? con.out : con.focus ? "" : "lua", room));
    if (caret) { ui_color(r, ui.caret); SDL_RenderFillRect(r, &(SDL_FRect){ x, ty - 1, g_lite_font ? 2 : 1, TAB_ROW }); }
  }
}

// A tooltip box, centred on x and kept inside the window. Asking for one
// only remembers it (the last asked wins); draw_tooltips() draws it at the
// end of the frame, over everything: contents, scrollbars, separators, menus.
static struct { bool on; int w; float x, y; char text[600]; } tip_q;

static void draw_tooltip(SDL_Renderer *r, int w, float x, float y, const char *text) {
  (void)r;
  tip_q.on = true; tip_q.w = w; tip_q.x = x; tip_q.y = y;
  SDL_strlcpy(tip_q.text, text ? text : "", sizeof tip_q.text);
}

static void draw_tooltips(SDL_Renderer *r) {
  if (!tip_q.on) return;
  tip_q.on = false;
  int w = tip_q.w;
  float x = tip_q.x, y = tip_q.y;
  const char *text = tip_q.text;
  char tip[600];
  fit(tip, sizeof tip, text, (float)w - 16);
  float tw = SDL_ceilf(ui_w(tip)) + 10, tx = SDL_floorf(x - tw / 2);   // (lite's font, its popups' colours)
  if (tx < 2) tx = 2;
  if (tx + tw > w - 2) tx = w - 2 - tw;
  SDL_FRect bgr = { tx, y, tw, TAB_ROW + 4 };
  ui_colora(r, ui.bg3, 245);
  SDL_RenderFillRect(r, &bgr);
  ui_color(r, ui.line);
  SDL_RenderRect(r, &bgr);
  ui_color(r, ui.accent);
  ui_text_in(r, tx + 5, y, bgr.h, tip);
}

// ---------------------------------------------------------------------------
// the main menu: a popup like the node graph's (dark, blue hover):
//   Plugins >        a submenu: the plugins that show a tab (the particle
//                    editor, sfxr, the tilemap editor...): a click opens one
//                    in a tab apart (their P.tab: projectplugins.lua); hovering
//                    one shows its menu beside: New tab / Open a file, its
//                    commands with their keys (P.commands: the node graph's
//                    Find CTRL+F, its changes and diff...), its settings, about
//   ----------
//   Log window       a checkbox: lite's Log tab (shown / hidden)
//   Confirm close    a checkbox: closing a tab with unsaved changes asks
//                    first (off: it just closes, the changes are dropped)
//   Thumbnails       a slider: the size of the tree's /assets previews
//                    (off, 16..80 px; drag it, or LMB / RMB / wheel a step)
//   ----------
//   FPS              the limit while focused: monitor (its refresh rate) or 6, 12, 18 ...
//   FPS unfocused    ... while another window has the focus (as focused, or N)
//   FPS minimized    ... while minimized
//   ----------
//   Help             docs/HELP.md in the markdown viewer (also F1)
//   Reset editor... asks, then forgets .preferences.lua and lite's
//                   .workspace.lua (tabs, graph views: folded nodes, pins)
//                   and starts again (replay.c: reset_defaults)
// Each change is saved to .preferences.lua at once (settings.h). A click on
// a checkbox or Reset does it and closes the menu; on a number: LMB the next
// value, RMB the one before, the wheel a step (the menu stays open).
// ---------------------------------------------------------------------------

enum { BURGER_PLUGINS, BURGER_SEP0, BURGER_LOG, BURGER_CONFIRM, BURGER_THEME, BURGER_THUMBS, BURGER_SEP1, BURGER_FPS, BURGER_FPS_BG, BURGER_FPS_MIN, BURGER_SEP2, BURGER_HELP, BURGER_RESET, BURGER_N };
static const char *burger_text[BURGER_N] = { "Plugins", NULL, "Log window", "Confirm close", "Theme", "Thumbnails", NULL, "FPS", "FPS unfocused", "FPS minimized", NULL, "Help", "Reset editor" };
static bool g_want_reset;                          // asked for: the main loop confirms, then does it (reset_defaults)
static bool g_want_help;                           // Help (or F1): the main loop opens docs/HELP.md
static struct { bool open; } burger;               // the main menu is open (lite's: menus.h)
#define PTABS_MAX 32
static struct { int n; char name[PTABS_MAX][48], title[PTABS_MAX][64]; } g_ptabs;   // Plugins >: asked of lite when the menu opens
static void ptabs_refresh(void) {
  static char buf[PTABS_MAX * 120];
  g_ptabs.n = 0;
  if (!editor_plugin_tabs(buf, sizeof buf)) return;
  for (char *line = buf; *line && g_ptabs.n < PTABS_MAX; ) {
    char *nl = strchr(line, '\n');
    if (nl) *nl = 0;
    char *tab = strchr(line, '\t');
    if (tab) {
      *tab = 0;
      SDL_strlcpy(g_ptabs.name[g_ptabs.n], line, sizeof g_ptabs.name[0]);
      SDL_strlcpy(g_ptabs.title[g_ptabs.n], tab + 1, sizeof g_ptabs.title[0]);
      g_ptabs.n++;
    }
    if (!nl) break;
    line = nl + 1;
  }
}
#define PMENU_MAX 40
static struct { int owner, n; char kind[PMENU_MAX]; char text[PMENU_MAX][64], info[PMENU_MAX][32]; } g_pmenu = { -1 };   // Plugins > <one> >
static void pmenu_refresh(int owner) {             // (asked of lite when the mouse comes to that plugin)
  static char buf[PMENU_MAX * 110];
  g_pmenu.owner = owner; g_pmenu.n = 0;
  if (owner < 0 || !editor_plugin_menu(g_ptabs.name[owner], buf, sizeof buf)) return;
  for (char *line = buf; *line && g_pmenu.n < PMENU_MAX; ) {
    char *nl = strchr(line, '\n');
    if (nl) *nl = 0;
    char *t1 = strchr(line, '\t'), *t2 = t1 ? strchr(t1 + 1, '\t') : NULL;
    if (t1 && t2) {
      *t1 = 0; *t2 = 0;
      int k = g_pmenu.n++;
      g_pmenu.kind[k] = line[0];
      SDL_strlcpy(g_pmenu.text[k], t1 + 1, sizeof g_pmenu.text[0]);
      SDL_strlcpy(g_pmenu.info[k], t2 + 1, sizeof g_pmenu.info[0]);
    }
    if (!nl) break;
    line = nl + 1;
  }
}
static void burger_value(int i, char *out, size_t n) {   // a number item's value, as shown
  if (i == BURGER_THEME) { SDL_snprintf(out, n, settings_light() ? "light" : "dark"); return; }
  if (i == BURGER_THUMBS) { if (settings_thumbs()) SDL_snprintf(out, n, "%d px", settings_thumbs()); else SDL_snprintf(out, n, "off"); return; }
  int v = i == BURGER_FPS ? settings_fps() : i == BURGER_FPS_BG ? settings_fps_unfocused() : settings_fps_minimized();
  if (i == BURGER_FPS && fps_limit_arg >= 0) SDL_snprintf(out, n, "--fps %g", fps_limit_arg);
  else if (v == 0 && i == BURGER_FPS) SDL_snprintf(out, n, g_monitor_hz > 0 ? "monitor %g" : "monitor", g_monitor_hz);
  else if (v == 0) SDL_snprintf(out, n, "as focused");
  else SDL_snprintf(out, n, "%d", v);
}

// "Help (v2026.10)": the build's year and month (when this was compiled: __DATE__, "Oct 16 2026")
static const char *build_version(void) {
  static char v[16];
  if (!v[0]) {
    static const char *mon = "JanFebMarAprMayJunJulAugSepOctNovDec";
    const char *d = __DATE__;
    char m[4] = { d[0], d[1], d[2], 0 };
    const char *at = SDL_strstr(mon, m);
    SDL_snprintf(v, sizeof v, "%s.%02d", d + 7, at ? (int)(at - mon) / 3 + 1 : 0);
  }
  return v;
}
static void burger_labels(void) {
  static char help[32];
  if (help[0]) return;
  SDL_snprintf(help, sizeof help, "Help (v%s)", build_version());
  burger_text[BURGER_HELP] = help;
}

// online? (the Network menu, menus.h: net_menu_open)
static bool online_on(Viewer *V, char *info, size_t n) {   // online? its line (runtime/players.lua)
  bool on = false;
  if (info) info[0] = 0;
  int top = lua_gettop(V->L);
  lua_getglobal(V->L, "viewer_online_info");
  if (lua_pcall(V->L, 0, 1, 0) == 0 && lua_isstring(V->L, -1)) { on = true; if (info) SDL_strlcpy(info, lua_tostring(V->L, -1), n); }
  lua_settop(V->L, top);
  return on;
}


static bool g_want_join;                           // (replay.c opens the console with join(""): the host's address)
static void power_set(Viewer *V, int on, const char *role) {   // on: 1 / 0 / -1 (as is)
  int top = lua_gettop(V->L);
  lua_getglobal(V->L, "viewer_online_set");
  if (on < 0) lua_pushnil(V->L); else lua_pushboolean(V->L, on);
  if (role) lua_pushstring(V->L, role); else lua_pushnil(V->L);
  if (lua_pcall(V->L, 2, 0, 0) != 0) SDL_snprintf(V->err, sizeof V->err, "online: %s", lua_tostring(V->L, -1));
  lua_settop(V->L, top);
}
static void power_click(Viewer *V) {               // LMB: on / off (on as it was: hosting, or joining its address)
  char line[200];
  bool host, on = power_mode(V, &host, line, sizeof line);
  if (!on && !host && strstr(line, "(no address yet)")) { g_want_join = true; return; }   // (joining nowhere yet: ask)
  power_set(V, !on, NULL);
}
// The Players button, the switch on: quarter k (runtime/players.lua viewer_players_click)
static void players_online_click(Viewer *V, int k, bool rmb) {
  if (V->world == LUA_NOREF) return;
  int top = lua_gettop(V->L);
  lua_getglobal(V->L, "viewer_players_click");
  lua_rawgeti(V->L, LUA_REGISTRYINDEX, V->world);
  lua_pushinteger(V->L, k);
  lua_pushboolean(V->L, rmb);
  if (lua_pcall(V->L, 3, 2, 0) != 0) SDL_snprintf(V->err, sizeof V->err, "online: %s", lua_tostring(V->L, -1));
  else {
    if (lua_toboolean(V->L, -2)) g_want_join = true;
    if (lua_isstring(V->L, -1)) SDL_snprintf(V->err, sizeof V->err, "online: %s", lua_tostring(V->L, -1));
  }
  lua_settop(V->L, top);
}

// tip: the mouse has rested long enough for tooltips (TIP_DELAY_MS)
// a stroke through n points, w[i] wide at each (triangles: smooth at any scale)
static void stroke(SDL_Renderer *r, const SDL_FPoint *p, const float *w, int n, SDL_FColor c) {
  SDL_Vertex v[2 * 32];
  int idx[6 * 31], m = 0;
  if (n < 2 || n > 32) return;
  for (int k = 0; k < n; k++) {
    SDL_FPoint a = p[k > 0 ? k - 1 : k], b = p[k < n - 1 ? k + 1 : k];
    float dx = b.x - a.x, dy = b.y - a.y, l = SDL_sqrtf(dx * dx + dy * dy);
    float nx = l > 0 ? -dy / l : 0, ny = l > 0 ? dx / l : 0, h = w[k] / 2;
    v[k * 2] = (SDL_Vertex){ { p[k].x + nx * h, p[k].y + ny * h }, c, { 0, 0 } };
    v[k * 2 + 1] = (SDL_Vertex){ { p[k].x - nx * h, p[k].y - ny * h }, c, { 0, 0 } };
  }
  for (int k = 0; k < n - 1; k++) {
    int a0 = k * 2;
    idx[m++] = a0; idx[m++] = a0 + 1; idx[m++] = a0 + 2;
    idx[m++] = a0 + 1; idx[m++] = a0 + 3; idx[m++] = a0 + 2;
  }
  SDL_RenderGeometry(r, NULL, v, n * 2, idx, m);
}
static void draw_bar(Viewer *V, int w, int h, float mx, float my, bool tip) {
  SDL_Renderer *r = V->ren;
  Bar b = bar_layout(w, h);
  SDL_FRect bg = { 0, (float)(h - BAR_H), (float)w, BAR_H };
  ui_color(r, ui.bg2);                             // (lite's theme: its side bar's colours)
  SDL_RenderFillRect(r, &bg);
  ui_color(r, ui.divider);
  SDL_RenderLine(r, 0, bg.y, (float)w, bg.y);

  int hot = bar_button_at(&b, mx, my);
  if (hot >= 0 && button_enabled(V, hot)) {        // hover highlight (enabled only)
    ui_color(r, ui.hilite);
    SDL_RenderFillRect(r, &b.btn[hot]);
  }
  ui_color(r, ui.line);                            // group separators
  {                                                // separator: save, export | the rest
    int i = VIEW_BUTTON ? BTN_FADE : BTN_GIZMO;
    float sx = b.btn[i].x - 6;
    SDL_RenderLine(r, sx, b.btn[i].y + 4, sx, b.btn[i].y + 20);
  }
  #define FCOL(c) (SDL_FColor){ (c).r / 255.f, (c).g / 255.f, (c).b / 255.f, 1 }
  SDL_FColor ic = FCOL(ui.accent), dim = FCOL(ui.dim);   // icons: lite's accent, dim, and its strings' colour (yellow-ish) for "on"
  SDL_FColor yel = FCOL(ui.string);
  #define SETC(c) SDL_SetRenderDrawColorFloat(r, (c).r, (c).g, (c).b, (c).a)
  float x = b.btn[BTN_PLAY].x, y = b.btn[BTN_PLAY].y;
  if (V->stopped || V->paused) {                   // play / resume
    fill_tri(r, x + 7, y + 5, x + 7, y + 19, x + 19, y + 12, ic);
  } else {                                         // pause
    SDL_FRect p1 = { x + 7, y + 5, 4, 14 }, p2 = { x + 14, y + 5, 4, 14 };
    SETC(ic);
    SDL_RenderFillRect(r, &p1);
    SDL_RenderFillRect(r, &p2);
  }
  x = b.btn[BTN_STOP].x; y = b.btn[BTN_STOP].y;    // stop: a square
  { SDL_FRect q = { x + 7, y + 7, 10, 10 }; SETC(button_enabled(V, BTN_STOP) ? ic : dim); SDL_RenderFillRect(r, &q); }
  x = b.btn[BTN_REW].x; y = b.btn[BTN_REW].y;      // rewind: two left triangles
  fill_tri(r, x + 12, y + 6, x + 12, y + 18, x + 4, y + 12, button_enabled(V, BTN_REW) ? ic : dim);
  fill_tri(r, x + 20, y + 6, x + 20, y + 18, x + 12, y + 12, button_enabled(V, BTN_REW) ? ic : dim);
  x = b.btn[BTN_POWER].x; y = b.btn[BTN_POWER].y;  // power: an open ring (one filled strip), a bar through its top gap
  {                                                // (off: dim, as Stop while stopped; on: lit, as Stop while playing)
    SDL_FColor c = power_mode(V, NULL, NULL, 0) ? ic : dim;
    enum { SEG = 14 };                             // 300 degrees in 14 quads: 28 triangles, a single draw
    SDL_Vertex v[SEG * 6];
    float cx = x + 12, cy = y + 13, ro = 7.5f, ri = 5.5f;
    for (int i = 0; i < SEG; i++) {
      float a0 = -SDL_PI_F / 2 + SDL_PI_F / 6 + i * (SDL_PI_F * 5 / 3) / SEG, a1 = a0 + (SDL_PI_F * 5 / 3) / SEG;
      float c0 = SDL_cosf(a0), s0 = SDL_sinf(a0), c1 = SDL_cosf(a1), s1 = SDL_sinf(a1);
      SDL_FPoint p[6] = { { cx + ro * c0, cy + ro * s0 }, { cx + ri * c0, cy + ri * s0 }, { cx + ro * c1, cy + ro * s1 },
                          { cx + ri * c0, cy + ri * s0 }, { cx + ri * c1, cy + ri * s1 }, { cx + ro * c1, cy + ro * s1 } };
      for (int k = 0; k < 6; k++) v[i * 6 + k] = (SDL_Vertex){ p[k], c, { 0, 0 } };
    }
    SDL_RenderGeometry(r, NULL, v, SEG * 6, NULL, 0);
    SETC(c);
    SDL_FRect bar = { cx - 1, y + 4, 2, 9 };
    SDL_RenderFillRect(r, &bar);
  }
  x = b.btn[BTN_PLAYERS].x; y = b.btn[BTN_PLAYERS].y;   // players: a quarter each (their views), lit = in
  int omask = online_mask(V);                      // (the switch on: this editor's seat, stopped; who's in, playing)
  for (int k = 0; k < 4; k++) {
    SDL_FRect q = { x + 5 + (k % 2) * 8.f, y + 5 + (k / 2) * 8.f, 6, 6 };
    bool in = ((omask >= 0 ? omask : V->pmask) >> k) & 1;
    SETC(in ? ic : dim);
    if (in) SDL_RenderFillRect(r, &q); else SDL_RenderRect(r, &q);
  }
  x = b.btn[BTN_NET].x; y = b.btn[BTN_NET].y;      // network: 4 signal bars, lit = its quality (0..4 bars)
  for (int i = 0; i < 4; i++) {
    float bh = 4.f + i * 3.f;
    SDL_FRect bar = { x + 4 + i * 4.5f, y + 19 - bh, 3, bh };
    float part = V->net * 4 - i;                   // bar i shows (i, i+1]: full, partial or off
    SDL_FColor c = part >= 1 ? ic : part > 0 ? (SDL_FColor){ ic.r, ic.g, ic.b, 0.25f + 0.6f * part } : dim;
    SETC(part > 0 ? c : dim);
    SDL_RenderFillRect(r, &bar);
  }
  x = b.btn[BTN_SPEED].x; y = b.btn[BTN_SPEED].y;  // speed: a gauge, the needle from x0.01 (left) to x4 (right)
  {
    float cx = x + 12, cy = y + 16, rr = 8;
    SETC(ic);
    for (int i = 0; i < 12; i++) {                 // the dial: a half circle
      float a0 = SDL_PI_F * (1 + i / 12.f), a1 = SDL_PI_F * (1 + (i + 1) / 12.f);
      SDL_RenderLine(r, cx + rr * SDL_cosf(a0), cy + rr * SDL_sinf(a0), cx + rr * SDL_cosf(a1), cy + rr * SDL_sinf(a1));
    }
    for (int i = 1; i <= 4; i++) {                 // ticks at x1 .. x4
      float a = SDL_PI_F * (1 + i / 4.f);
      SDL_RenderLine(r, cx + (rr - 2) * SDL_cosf(a), cy + (rr - 2) * SDL_sinf(a), cx + rr * SDL_cosf(a), cy + rr * SDL_sinf(a));
    }
    float a = SDL_PI_F * (1 + V->speed / 4.f);
    SETC(ic);
    SDL_RenderLine(r, cx, cy, cx + (rr - 1) * SDL_cosf(a), cy + (rr - 1) * SDL_sinf(a));
    SDL_FRect hub = { cx - 1, cy - 1, 3, 3 };
    SDL_RenderFillRect(r, &hub);
  }
  x = b.btn[BTN_SAVE].x; y = b.btn[BTN_SAVE].y;    // save: a floppy; yellow = unsaved edits
  {
    SDL_FColor c = button_enabled(V, BTN_SAVE) ? yel : dim;   // yellow: unsaved changes
    SDL_FRect body = { x + 5, y + 5, 14, 14 }, shutter = { x + 8, y + 5, 7, 5 }, label = { x + 8, y + 12, 8, 7 };
    SETC(c);
    SDL_RenderRect(r, &body);
    SDL_RenderFillRect(r, &shutter);
    SDL_RenderRect(r, &label);
  }
  x = b.btn[BTN_EXPORT].x; y = b.btn[BTN_EXPORT].y;   // export: an open box, an arrow up out of it
  {
    SDL_FColor c = button_enabled(V, BTN_EXPORT) ? ic : dim;
    SETC(c);
    SDL_RenderLine(r, x + 5, y + 12, x + 5, y + 19);   // the box: sides and bottom, open at the top
    SDL_RenderLine(r, x + 19, y + 12, x + 19, y + 19);
    SDL_RenderLine(r, x + 5, y + 19, x + 19, y + 19);
    SDL_RenderLine(r, x + 12, y + 5, x + 12, y + 15);   // the arrow
    fill_tri(r, x + 12, y + 3, x + 8, y + 8, x + 16, y + 8, c);
  }
  x = b.btn[BTN_GIZMO].x; y = b.btn[BTN_GIZMO].y;  // gizmos: two axes
  {
    SDL_FColor c = V->gizmos ? ic : dim;   // (on: white; off: grey, still clickable)
    fill_tri(r, x + 19, y + 18, x + 15, y + 16, x + 15, y + 20, c);
    fill_tri(r, x + 6, y + 5, x + 4, y + 9, x + 8, y + 9, c);
    SETC(c);
    SDL_RenderLine(r, x + 6, y + 18, x + 16, y + 18);
    SDL_RenderLine(r, x + 6, y + 18, x + 6, y + 8);
  }
  x = b.btn[BTN_PICK].x; y = b.btn[BTN_PICK].y;    // picking debug: a dashed box + cross
  {
    SDL_FColor c = V->pickdbg ? ic : dim;
    SETC(c);
    for (int i = 0; i < 14; i += 4) {
      SDL_RenderLine(r, x + 5 + i, y + 5, x + 6 + i, y + 5);
      SDL_RenderLine(r, x + 5 + i, y + 19, x + 6 + i, y + 19);
      SDL_RenderLine(r, x + 5, y + 5 + i, x + 5, y + 6 + i);
      SDL_RenderLine(r, x + 19, y + 5 + i, x + 19, y + 6 + i);
    }
    SDL_RenderLine(r, x + 12, y + 9, x + 12, y + 15);
    SDL_RenderLine(r, x + 9, y + 12, x + 15, y + 12);
  }
  x = b.btn[BTN_CAM].x; y = b.btn[BTN_CAM].y;      // camera home: a target
  {
    bool home = V->camx == 0 && V->camy == 0 && V->zoom == 1;
    (void)home;
    SETC(button_enabled(V, BTN_CAM) ? ic : dim);
    SDL_FRect o = { x + 6, y + 6, 12, 12 }, d = { x + 11, y + 11, 2, 2 };
    SDL_RenderRect(r, &o);
    SDL_RenderFillRect(r, &d);
    SDL_RenderLine(r, x + 12, y + 3, x + 12, y + 6);
    SDL_RenderLine(r, x + 12, y + 18, x + 12, y + 21);
    SDL_RenderLine(r, x + 3, y + 12, x + 6, y + 12);
    SDL_RenderLine(r, x + 18, y + 12, x + 21, y + 12);
  }
  x = b.btn[BTN_FADE].x; y = b.btn[BTN_FADE].y;    // the game's opacity: an eye, its pupil as opaque as the game
  {                                                // game: solid pupil; mixed: `fade` full; editor: an empty ring
    SDL_FColor c = !button_enabled(V, BTN_FADE) ? dim : ic;
    float cx = x + 12, cy = y + 12.5f;
    SDL_FPoint p[17]; float wd[17];
    for (int k = 0; k <= 16; k++) {                // the upper lid: a brush stroke, thick in the middle, thin at the ends
      float t = k / 16.f;
      p[k] = (SDL_FPoint){ x + 1.5f + t * 21, cy - 0.5f - SDL_sinf(t * SDL_PI_F) * 6 - t * 2.5f + (t < 0.15f ? (0.15f - t) * 6 : 0) };
      wd[k] = 0.9f + SDL_sinf(SDL_powf(t, 0.7f) * SDL_PI_F) * 1.5f;
    }
    stroke(r, p, wd, 17, c);
    for (int k = 0; k <= 10; k++) {                // the lower lid: thinner, open at the outer corner
      float t = k / 10.f;
      p[k] = (SDL_FPoint){ x + 4.5f + t * 15, cy + 5.5f + SDL_sinf(t * SDL_PI_F) * 1.5f - t * 2 };
      wd[k] = 0.9f + SDL_sinf(t * SDL_PI_F) * 0.5f;
    }
    stroke(r, p, wd, 11, c);
#if 0
    p[0] = (SDL_FPoint){ cx - 4.6f, cy - 5.5f }; p[1] = (SDL_FPoint){ cx - 4, cy + 4.2f };   // the iris's two sides
    wd[0] = wd[1] = 1.1f;
    stroke(r, p, wd, 2, c);
    p[0] = (SDL_FPoint){ cx + 4.4f, cy - 7.2f }; p[1] = (SDL_FPoint){ cx + 3.8f, cy + 3.6f };
    stroke(r, p, wd, 2, c);
#endif
    float pr = 2.7f, fill = V->fade;               // the pupil: a disc, `fade` opaque, inside a ring
    cy -= 0.5f;
    if (fill > 0) {
      SDL_Vertex v[3 * 16];
      SDL_FColor f = { c.r, c.g, c.b, fill };
      for (int k = 0; k < 16; k++) {
        float a0 = k * 2 * SDL_PI_F / 16, a1 = (k + 1) * 2 * SDL_PI_F / 16;
        v[k * 3 + 0] = (SDL_Vertex){ { cx, cy }, f, { 0, 0 } };
        v[k * 3 + 1] = (SDL_Vertex){ { cx + SDL_cosf(a0) * pr, cy + SDL_sinf(a0) * pr }, f, { 0, 0 } };
        v[k * 3 + 2] = (SDL_Vertex){ { cx + SDL_cosf(a1) * pr, cy + SDL_sinf(a1) * pr }, f, { 0, 0 } };
      }
      SDL_RenderGeometry(r, NULL, v, 3 * 16, NULL, 0);
    }
    for (int k = 0; k <= 16; k++) { p[k] = (SDL_FPoint){ cx + SDL_cosf(k * 2 * SDL_PI_F / 16) * pr, cy + SDL_sinf(k * 2 * SDL_PI_F / 16) * pr }; wd[k] = 0.9f; }
    stroke(r, p, wd, 17, c);
  }
  x = b.btn[BTN_MENU].x; y = b.btn[BTN_MENU].y;    // menu: three bars, lit while it's open
  {
    SETC(burger.open ? yel : ic);
    for (int i = 0; i < 3; i++) { SDL_FRect bar = { x + 5, y + 6 + i * 5.f, 14, 2 }; SDL_RenderFillRect(r, &bar); }
  }
  #undef SETC

  // timeline
  double len = timeline_len(V), span = timeline_span(len);
  float px = b.track.x + (float)(V->gtime / span) * b.track.w;
  ui_color(r, ui.bg);                              // empty track: not recorded yet
  SDL_RenderFillRect(r, &b.track);
  draw_timeline_band(V, &b.track, span, px);
  ui_color(r, ui.dim);                             // 6 ticks across the span
  for (int i = 1; i < 6; i++) {
    float tx = b.track.x + b.track.w * i / 6.f;
    SDL_RenderLine(r, tx, b.track.y + b.track.h, tx, b.track.y + b.track.h + 2);
  }
  bool hover = my >= b.track.y - 3 && my < b.track.y + b.track.h + 3 &&
               mx >= b.track.x && mx < b.track.x + b.track.w;
  if (hover) {
    ui_color(r, ui.accent);                        // where a click would go
    SDL_RenderLine(r, mx, b.track.y - 2, mx, b.track.y + b.track.h + 2);
  }
  SDL_FRect head = { px - 1.5f, b.track.y - 2, 3, b.track.h + 4 };
  ui_color(r, ui.string);                          // (yellow-ish, like the toolbar's "on")
  SDL_RenderFillRect(r, &head);

  draw_console(V, &b.con, in_rect(&b.con, mx, my));

  // tooltips: only once the mouse has rested on one spot (see TIP_DELAY_MS)
  if (!tip) return;
  char t_[1100];
  float ty = b.track.y - 18;
  int hot_ = bar_button_at(&b, mx, my);
  if (hot_ >= BTN_SAVE && hot_ <= BTN_MENU) ty = b.btn[hot_].y + 27;   // toolbar: tip below it
  if (hover && V->stopped) {
    SDL_snprintf(t_, sizeof t_, "Stopped: press play to record a timeline");
  } else if (hover) {                              // time and fps under the mouse
    double t = (mx - b.track.x) / b.track.w * span;
    float f = fps_at(t);
    if (t > len) SDL_snprintf(t_, sizeof t_, "%.1fs  not recorded yet", t);
    else if (f > 0) SDL_snprintf(t_, sizeof t_, "%.1fs  %.0f fps  - click to jump", t, f);
    else SDL_snprintf(t_, sizeof t_, "%.1fs  - click to jump", t);
  } else if (hot >= 0) {
    switch (hot) {
    case BTN_PLAY:
      if (V->stopped) SDL_snprintf(t_, sizeof t_, "Play: from disk, unsaved editor files win   RMB: standalone, disk only");
      else if (V->paused) SDL_snprintf(t_, sizeof t_, "Resume   %.1fs / %.1fs", V->gtime, len);
      else SDL_snprintf(t_, sizeof t_, "Pause   %.1fs / %.1fs", V->gtime, len);
      break;
    case BTN_STOP:
      if (V->stopped) SDL_snprintf(t_, sizeof t_, "Stopped: edits go to the world on disk (save)");
      else SDL_snprintf(t_, sizeof t_, "Stop: back to the edited world, play changes dropped");
      break;
    case BTN_REW:
      SDL_snprintf(t_, sizeof t_, "Restart: t=0, x1, playing");
      break;
    case BTN_POWER: {
      char line[200];
      bool host, on = power_mode(V, &host, line, sizeof line);
      const char *hint = V->stopped ? "   click: on / off   (the Players button: P1 hosts, P2-P4 join)" : "   (stop to change it)";
      if (!on) SDL_snprintf(t_, sizeof t_, "Network: offline (local players)%s", hint);
      else if (!V->stopped && online_on(V, line, sizeof line)) SDL_snprintf(t_, sizeof t_, "Online: %s%s", line, hint);
      else SDL_snprintf(t_, sizeof t_, "Network: online (%s) on Play%s", line, hint);
      break;
    }
    case BTN_PLAYERS: {
      int top = lua_gettop(V->L);
      lua_getglobal(V->L, "viewer_players_tip");     // (the switch on: seats, online)
      if (lua_pcall(V->L, 0, 1, 0) == 0 && lua_isstring(V->L, -1)) SDL_strlcpy(t_, lua_tostring(V->L, -1), sizeof t_);
      else {
        char who[32] = "";
        for (int k = 1; k <= 4; k++) if ((V->pmask >> (k - 1)) & 1) SDL_snprintf(who + strlen(who), sizeof who - strlen(who), " %d", k);
        SDL_snprintf(t_, sizeof t_, "Players:%s%s   click a quarter: that player in / out",
                     who[0] ? who : " none (server alone)", V->stopped ? " (on play)" : "");
      }
      lua_settop(V->L, top);
      break;
    }
    case BTN_NET: {
      char ni[96];
      players_net_info(V, ni, sizeof ni);
      double bw = players_bandwidth(V);
      char extra[64] = "";
      if (V->net < 1 && bw > 0) SDL_snprintf(extra, sizeof extra, ", %d/s, %.1f kB/s", g_net_rate, bw / 1024);
      char on_[200];
      if (online_on(V, on_, sizeof on_)) SDL_snprintf(t_, sizeof t_, "Online: %s   RMB: ghosts, rate, lines", on_);
      else SDL_snprintf(t_, sizeof t_, "Network %s%s   click: next preset down   wheel: 1%%   RMB: ghosts, rate, lines", ni, extra);
      break;
    }
    case BTN_SPEED:
      SDL_snprintf(t_, sizeof t_, "Speed x%.2f   click: x%.0f   wheel: 0.05 (x0.01..x4)", V->speed, speed_next(V));
      break;
    case BTN_SAVE:
      if (!V->savable) SDL_snprintf(t_, sizeof t_, "Save: this world can't be saved");
      else if (!V->stopped) SDL_snprintf(t_, sizeof t_, "Save: stop the game first (play changes aren't saved)");
      else if (V->dirty && V->script) SDL_snprintf(t_, sizeof t_, "Save everything: edits to %s (overrides on top of the script)", V->opath);
      else if (V->dirty) SDL_snprintf(t_, sizeof t_, "Save everything: the whole world to %s", V->path);
      else SDL_snprintf(t_, sizeof t_, "Save everything: no changes");
      break;
    case BTN_EXPORT: {
      char nm[256];
      export_name(V, nm, sizeof nm);
      SDL_snprintf(t_, sizeof t_, "Export %s: %s.exe and what it needs, into a folder you pick (from the disk: save first)", nm, nm);
      break;
    }
    case BTN_GIZMO: SDL_snprintf(t_, sizeof t_, "Enable gizmos for all selected nodes (and what's under them; / : all): %s", V->gizmos ? "on" : "off"); break;
    case BTN_PICK: SDL_snprintf(t_, sizeof t_, "Picking debug: %s", V->pickdbg ? "on" : "off"); break;
    case BTN_CAM: SDL_snprintf(t_, sizeof t_, button_enabled(V, BTN_CAM) ? "Reset camera  (drag = pan, wheel = zoom)"
                                                                     : "Camera: already reset  (drag = pan, wheel = zoom)"); break;
    case BTN_MENU: if (burger.open) return; SDL_snprintf(t_, sizeof t_, "Main menu"); break;
    case BTN_FADE: {                               // the game's opacity over the editor, in this state
      int pc = (int)(V->fade * 100 + 0.5f);
      const char *st = V->stopped ? "Stopped" : V->paused ? "Paused" : "Playing";
      SDL_snprintf(t_, sizeof t_, "%s: %s%d%%%s   click: editor / mixed / game   wheel: 5%% up / down", st,
                   pc <= 0 ? "the editor only (game " : pc >= 100 ? "the game only (" : "the game at ", pc,
                   pc <= 0 || pc >= 100 ? ")" : " over the editor");
      break;
    }
    }
  } else if (in_rect(&b.con, mx, my)) {
    if (!con_fits(&b.con, con.out) && !con.e.len)
      SDL_snprintf(t_, sizeof t_, "%s", con.out);  // the whole result
    else if (!con.focus)
      SDL_snprintf(t_, sizeof t_, "Lua on the live world: w, sel, ls(), print()");
    else return;
  } else return;
  draw_tooltip(r, w, mx, ty, t_);
}

// timeline time under an x coordinate
static double bar_time_at(Viewer *V, int w, int h, float x) {
  Bar b = bar_layout(w, h);
  double k = (x - b.track.x) / b.track.w;
  if (k < 0) k = 0;
  if (k > 1) k = 1;
  return k * timeline_span(timeline_len(V));        // seek() clamps to what was recorded
}

static void save_shot(Viewer *V, const char *file) {
  SDL_Surface *s = SDL_RenderReadPixels(V->ren, NULL);
  if (!s) { SDL_Log("shot failed: %s", SDL_GetError()); return; }
  if (!SDL_SaveBMP(s, file)) SDL_Log("save failed: %s", SDL_GetError());
  else SDL_Log("saved %s", file);
  SDL_DestroySurface(s);
}
