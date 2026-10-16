// overlay.h - the developer overlay drawn over the game area (included by
// replay.c; everything is static, no separate compile step).
//
// The overlay is a transparent layer the size of the game area, drawn on top
// of the game. It only exists while the developer UI (tree tab + timeline) is
// on; a standalone game (game --standalone) never updates or draws it, and
// the Lua `dd` calls below become no-ops there. replay.c also hides it while
// the editor is visible (it would cover lite's minimap and status bar); new
// messages then go to ov.forward (lite's status bar) instead.
//
// Draw order, every frame:
//   1. debugdraw primitives (Lua `dd.*`, world or screen space)
//   2. stats              top-right     permanent, refreshed every frame
//   3. warnings/errors    top-left      fade out slowly
//   4. input + frame      bottom-right  held keys/buttons (yellow on the
//                                       frame they were pressed); released fade fast
//
// Lua API (global `dd`, also available inside code leaves / systems):
//   dd.line(x1, y1, x2, y2 [, color])
//   dd.arrow(x1, y1, x2, y2 [, color])
//   dd.rect(x, y, w, h [, color [, fill]])          x, y = top-left corner
//   dd.circle(x, y, r [, color [, fill]])
//   dd.tri(x1, y1, x2, y2, x3, y3 [, color])        filled
//   dd.cross(x, y [, size_px [, color]])
//   dd.text(x, y, text [, color])                    8 px debug font, unscaled
//   dd.screen(on)        following calls use game-area pixels (true) or
//                        world units (false, the default)
//   dd.log(...)  dd.warn(...)  dd.error(...)          messages, top-left
// color = { r, g, b [, a] } (0..255) or "#rrggbb" / "#rrggbbaa"; default white.
// Primitives are kept until the next world tick, so they stay visible while
// the game is paused.

#pragma once

#define OV_INFO  0
#define OV_WARN  1
#define OV_ERROR 2

#define OV_MAX_CMDS  16384
#define OV_TEXT_POOL (256 * 1024)
#define OV_MAX_LOG   16
#define OV_MAX_INPUT 32

enum { DD_LINE, DD_ARROW, DD_RECT, DD_RECTF, DD_CIRCLE, DD_CIRCLEF, DD_TRI, DD_CROSS, DD_TEXT };

typedef struct {
  Uint8 type, screen;
  Uint8 col[4];
  float v[6];
  int text;                                        // offset in ov.pool (DD_TEXT)
} DDCmd;

typedef struct {
  char text[256];
  int level, count;
  Uint64 t;                                        // last time it was logged (ms)
} OvMsg;

typedef struct {
  char name[40];
  bool down, fresh;                                // fresh: pressed this frame (drawn yellow)
  Uint64 t;                                        // press or release time (ms)
} OvInput;

static struct {
  bool enabled;
  char banner[2][160];                             // stopped at a breakpoint: a red frame, these lines on top (replay.c)
  DDCmd cmds[OV_MAX_CMDS];
  int ncmds, dropped;
  char pool[OV_TEXT_POOL];
  int pool_n;
  bool screen;                                     // dd.screen() state
  OvMsg log[OV_MAX_LOG];
  int nlog;
  OvInput in[OV_MAX_INPUT];
  int nin;
  Sint16 axis[8][SDL_GAMEPAD_AXIS_COUNT];          // last reported axis values (pads 0..7)
  SDL_Texture *tex;
  int tw, th;
  float ts;                                        // (its scale: retina)
  void (*forward)(int level, const char *text, const char *where);   // lite's log, while lite runs
} ov;

// The log: every message (overlay ones fade; these stay until they scroll
// out). One entry per message; its text may have several lines (a message
// and its traceback).
#define OV_HIST 1024
typedef struct {
  char *text;                                      // heap copy, may be multi-line
  char where[160];                                 // "file:line" of the Lua caller, or ""
  Uint8 level;
  int count;                                       // repeated n times in a row
} OvLine;
static struct {
  OvLine line[OV_HIST];
  int head, n;                                     // ring buffer
  unsigned seq;                                    // bumps on every change (views follow it)
} ovh;

static OvLine *ov_hist_at(int i) { return &ovh.line[(ovh.head + i) % OV_HIST]; }  // 0 = oldest

// .log.txt: every message of this run, also written to a file (the project's
// folder, emptied at start) as it happens, whatever is shown at the time.
static FILE *ov_logfile;
static char ov_logpath[1200];
// never more than 8 MB: past it, the oldest half goes (the file is rewritten
// with its newest 4 MB, from a line start) and logging carries on
#ifndef OV_LOGFILE_MAX
#define OV_LOGFILE_MAX (8 << 20)
#define OV_LOGFILE_KEEP (4 << 20)
#endif
static void ov_file_roll(void) {
  long size = ftell(ov_logfile);
  fclose(ov_logfile);
  ov_logfile = NULL;
  FILE *f = fopen(ov_logpath, "rb");
  char *buf = f ? (char *)SDL_malloc(OV_LOGFILE_KEEP) : NULL;
  size_t n = 0;
  if (buf) {
    fseek(f, size > OV_LOGFILE_KEEP ? size - OV_LOGFILE_KEEP : 0, SEEK_SET);
    n = fread(buf, 1, OV_LOGFILE_KEEP, f);
  }
  if (f) fclose(f);
  size_t start = 0;
  while (start < n && buf[start] != '\n') start++;  // (from the next whole line)
  if (start < n) start++;
  ov_logfile = fopen(ov_logpath, "wb");
  if (ov_logfile) {
    fprintf(ov_logfile, "-- .log.txt: the newest messages of this run (older ones dropped at 8 MB)\n");
    if (buf && n > start) fwrite(buf + start, 1, n - start, ov_logfile);
  }
  SDL_free(buf);
}
static void ov_file_write(int level, const char *where, const char *text, int count) {
  if (!ov_logfile) return;
  if (ftell(ov_logfile) + (long)strlen(text) + (where ? (long)strlen(where) : 0) + 64 > OV_LOGFILE_MAX) ov_file_roll();
  if (!ov_logfile) return;
  Uint64 ms = SDL_GetTicks();
  fprintf(ov_logfile, "%02u:%02u.%03u %s%s%s%s%s", (unsigned)(ms / 60000), (unsigned)(ms / 1000 % 60), (unsigned)(ms % 1000),
          level == OV_ERROR ? "error: " : level == OV_WARN ? "warning: " : "",
          where && where[0] ? where : "", where && where[0] ? ": " : "", text, count > 1 ? "" : "\n");
  if (count > 1) fprintf(ov_logfile, "  (x%d)\n", count);
  fflush(ov_logfile);
}
static void ov_log_open(const char *path) {        // (what was logged before: written first)
  if (ov_logfile) fclose(ov_logfile);
  SDL_strlcpy(ov_logpath, path, sizeof ov_logpath);
  ov_logfile = fopen(path, "wb");
  if (!ov_logfile) return;
  fprintf(ov_logfile, "-- .log.txt: this run's messages (the Log tab shows them too)\n");
  for (int i = 0; i < ovh.n; i++) { OvLine *l = ov_hist_at(i); ov_file_write(l->level, l->where, l->text, l->count); }
}
// sends what was logged so far to fn (lite, once it runs: its Log tab has all of it)
static void ov_replay(void (*fn)(int level, const char *text, const char *where)) {
  for (int i = 0; i < ovh.n; i++) { OvLine *l = ov_hist_at(i); fn(l->level, l->text, l->where); }
}

static void ov_hist_add(int level, const char *where, const char *text) {
  ovh.seq++;
  if (ovh.n) {                                     // the same message again: count it
    OvLine *last = ov_hist_at(ovh.n - 1);
    if (last->level == level && !strcmp(last->text, text) && !strcmp(last->where, where ? where : "")) {
      last->count++;
      return;
    }
  }
  if (ovh.n == OV_HIST) { SDL_free(ov_hist_at(0)->text); ovh.head = (ovh.head + 1) % OV_HIST; ovh.n--; }
  OvLine *l = ov_hist_at(ovh.n++);
  l->text = SDL_strdup(text);
  for (char *c = l->text; *c; c++) if (*c == '\t') *c = ' ';
  SDL_strlcpy(l->where, where ? where : "", sizeof l->where);
  l->level = (Uint8)level; l->count = 1;
}


// timing: messages stay, then fade; released inputs fade much faster
#define OV_MSG_HOLD_MS  6000
#define OV_MSG_FADE_MS  4000
#define OV_IN_FADE_MS    450

// ---------------------------------------------------------------------------
// messages
// ---------------------------------------------------------------------------

// A message: `where` = "file:line" of the Lua code that sent it (or NULL).
// `text` may have several lines (message + traceback): it is written as one
// unit everywhere (terminal, log, lite), never line by line.
static void ov_log_at(int level, const char *where, const char *text) {
  if (level >= OV_WARN || (where && where[0]))
    fprintf(stderr, "%s%s%s%s\n", level == OV_ERROR ? "error: " : level == OV_WARN ? "warning: " : "",
            where && where[0] ? where : "", where && where[0] ? ": " : "", text);
  ov_file_write(level, where, text, 1);            // .log.txt, always
  if (!ov.enabled) return;
  ov_hist_add(level, where, text);                 // the log keeps it whole
  if (ov.forward) ov.forward(level, text, where);  // lite's log (its Log tab, open or not)
  // the overlay shows the first line, fading
  const char *nl = strchr(text, '\n');
  char buf[256];
  SDL_snprintf(buf, sizeof buf, "%.*s%s", nl ? (int)(nl - text) : (int)strlen(text), text,
               nl ? "  (+ trace: log)" : "");
  for (char *c = buf; *c; c++) if (*c == '\r' || *c == '\t') *c = ' ';
  Uint64 now = SDL_GetTicks();
  for (int i = 0; i < ov.nlog; i++) {             // same message again: bump it
    if (ov.log[i].level == level && !strcmp(ov.log[i].text, buf)) {
      OvMsg m = ov.log[i];
      m.count++; m.t = now;
      memmove(&ov.log[i], &ov.log[i + 1], sizeof(OvMsg) * (size_t)(ov.nlog - i - 1));
      ov.log[ov.nlog - 1] = m;                     // ...to the newest slot
      return;
    }
  }
  if (ov.nlog == OV_MAX_LOG) { memmove(&ov.log[0], &ov.log[1], sizeof(OvMsg) * (OV_MAX_LOG - 1)); ov.nlog--; }
  OvMsg *m = &ov.log[ov.nlog++];
  SDL_strlcpy(m->text, buf, sizeof m->text);
  m->level = level; m->count = 1; m->t = now;
}

static void ov_log(int level, const char *fmt, ...) {
  char buf[1024];
  va_list ap;
  va_start(ap, fmt);
  SDL_vsnprintf(buf, sizeof buf, fmt, ap);
  va_end(ap);
  ov_log_at(level, NULL, buf);
}

// ---------------------------------------------------------------------------
// input
// ---------------------------------------------------------------------------

static void ov_press(const char *name, bool down) {
  if (!name || !name[0]) return;
  Uint64 now = SDL_GetTicks();
  for (int i = 0; i < ov.nin; i++) {
    if (!strcmp(ov.in[i].name, name)) {
      OvInput e = ov.in[i];
      if (e.down == down && down) return;          // already held
      e.down = down; e.t = now;
      if (down) e.fresh = true;                    // a tap (down+up in one frame) still flashes
      if (down) {                                  // a new press moves to the end
        memmove(&ov.in[i], &ov.in[i + 1], sizeof(OvInput) * (size_t)(ov.nin - i - 1));
        ov.in[ov.nin - 1] = e;
      } else ov.in[i] = e;
      return;
    }
  }
  if (ov.nin == OV_MAX_INPUT) {                    // full: drop the oldest released (or oldest)
    int k = 0;
    for (int i = 0; i < ov.nin; i++) if (!ov.in[i].down) { k = i; break; }
    memmove(&ov.in[k], &ov.in[k + 1], sizeof(OvInput) * (size_t)(ov.nin - k - 1));
    ov.nin--;
  }
  OvInput *e = &ov.in[ov.nin++];
  SDL_strlcpy(e->name, name, sizeof e->name);
  e->down = down; e->t = now; e->fresh = down;
}

static const char *ov_mouse_name(int b) {
  switch (b) {
  case SDL_BUTTON_LEFT: return "mouse left";
  case SDL_BUTTON_MIDDLE: return "mouse middle";
  case SDL_BUTTON_RIGHT: return "mouse right";
  case SDL_BUTTON_X1: return "mouse x1";
  case SDL_BUTTON_X2: return "mouse x2";
  }
  return "mouse ?";
}

// every SDL event goes through here (whoever ends up consuming it)
static void ov_input_event(const SDL_Event *e) {
  if (!ov.enabled) return;
  char n[64];
  switch (e->type) {
  case SDL_EVENT_KEY_DOWN:
  case SDL_EVENT_KEY_UP:
    if (e->key.repeat) return;
    ov_press(SDL_GetKeyName(e->key.key), e->type == SDL_EVENT_KEY_DOWN);
    break;
  case SDL_EVENT_MOUSE_BUTTON_DOWN:
  case SDL_EVENT_MOUSE_BUTTON_UP:
    ov_press(ov_mouse_name(e->button.button), e->type == SDL_EVENT_MOUSE_BUTTON_DOWN);
    break;
  case SDL_EVENT_MOUSE_WHEEL:                      // momentary: shown released
    ov_press(e->wheel.y > 0 ? "wheel up" : e->wheel.y < 0 ? "wheel down" :
             e->wheel.x > 0 ? "wheel right" : "wheel left", true);
    ov_press(e->wheel.y > 0 ? "wheel up" : e->wheel.y < 0 ? "wheel down" :
             e->wheel.x > 0 ? "wheel right" : "wheel left", false);
    break;
  case SDL_EVENT_GAMEPAD_ADDED:
    SDL_OpenGamepad(e->gdevice.which);
    break;
  case SDL_EVENT_GAMEPAD_BUTTON_DOWN:
  case SDL_EVENT_GAMEPAD_BUTTON_UP:
    SDL_snprintf(n, sizeof n, "pad %s", SDL_GetGamepadStringForButton((SDL_GamepadButton)e->gbutton.button));
    ov_press(n, e->type == SDL_EVENT_GAMEPAD_BUTTON_DOWN);
    break;
  case SDL_EVENT_GAMEPAD_AXIS_MOTION: {           // shown as held past half way
    int a = e->gaxis.axis, pad = (int)(e->gaxis.which % 8);
    if (a < 0 || a >= SDL_GAMEPAD_AXIS_COUNT) break;
    Sint16 was = ov.axis[pad][a], now = e->gaxis.value;
    const char *an = SDL_GetGamepadStringForAxis((SDL_GamepadAxis)a);
    bool trig = a == SDL_GAMEPAD_AXIS_LEFT_TRIGGER || a == SDL_GAMEPAD_AXIS_RIGHT_TRIGGER;
    const int T = 16384;
    for (int s = -1; s <= 1; s += 2) {             // the - and + directions
      if (trig && s < 0) continue;
      bool on0 = s * was > T, on1 = s * now > T;
      if (on0 == on1) continue;
      SDL_snprintf(n, sizeof n, trig ? "pad %s" : "pad %s%c", an, s < 0 ? '-' : '+');
      ov_press(n, on1);
    }
    ov.axis[pad][a] = now;
    break;
  }
  }
}

// ---------------------------------------------------------------------------
// debugdraw (Lua)
// ---------------------------------------------------------------------------

static void ov_clear_draws(void) { ov.ncmds = 0; ov.pool_n = 0; ov.screen = false; ov.dropped = 0; }

static DDCmd *dd_new(lua_State *L, int type, int colarg) {
  if (!ov.enabled) return NULL;
  if (ov.ncmds >= OV_MAX_CMDS) { ov.dropped++; return NULL; }
  DDCmd *c = &ov.cmds[ov.ncmds++];
  c->type = (Uint8)type;
  c->screen = ov.screen;
  c->text = -1;
  Uint8 col[4] = { 255, 255, 255, 255 };
  if (lua_istable(L, colarg)) {
    for (int i = 0; i < 4; i++) {
      lua_rawgeti(L, colarg, i + 1);
      if (lua_isnumber(L, -1)) {
        lua_Number v = lua_tonumber(L, -1);
        col[i] = (Uint8)(v < 0 ? 0 : v > 255 ? 255 : v);
      }
      lua_pop(L, 1);
    }
  } else if (lua_type(L, colarg) == LUA_TSTRING) { // "#rrggbb" / "#rrggbbaa"
    const char *s = lua_tostring(L, colarg);
    if (*s == '#') s++;
    size_t n = strlen(s);
    if (n == 6 || n == 8) {
      unsigned long v = strtoul(s, NULL, 16);
      if (n == 6) v = (v << 8) | 0xFF;
      col[0] = (Uint8)(v >> 24); col[1] = (Uint8)(v >> 16); col[2] = (Uint8)(v >> 8); col[3] = (Uint8)v;
    }
  }
  memcpy(c->col, col, 4);
  return c;
}

static float dd_num(lua_State *L, int i) { return (float)luaL_checknumber(L, i); }

static int l_dd_line(lua_State *L) {
  DDCmd *c = dd_new(L, DD_LINE, 5);
  if (c) for (int i = 0; i < 4; i++) c->v[i] = dd_num(L, i + 1);
  return 0;
}
static int l_dd_arrow(lua_State *L) {
  DDCmd *c = dd_new(L, DD_ARROW, 5);
  if (c) for (int i = 0; i < 4; i++) c->v[i] = dd_num(L, i + 1);
  return 0;
}
static int l_dd_rect(lua_State *L) {
  DDCmd *c = dd_new(L, lua_toboolean(L, 6) ? DD_RECTF : DD_RECT, 5);
  if (c) for (int i = 0; i < 4; i++) c->v[i] = dd_num(L, i + 1);
  return 0;
}
static int l_dd_circle(lua_State *L) {
  DDCmd *c = dd_new(L, lua_toboolean(L, 5) ? DD_CIRCLEF : DD_CIRCLE, 4);
  if (c) for (int i = 0; i < 3; i++) c->v[i] = dd_num(L, i + 1);
  return 0;
}
static int l_dd_tri(lua_State *L) {
  DDCmd *c = dd_new(L, DD_TRI, 7);
  if (c) for (int i = 0; i < 6; i++) c->v[i] = dd_num(L, i + 1);
  return 0;
}
static int l_dd_cross(lua_State *L) {
  DDCmd *c = dd_new(L, DD_CROSS, 4);
  if (c) { c->v[0] = dd_num(L, 1); c->v[1] = dd_num(L, 2); c->v[2] = (float)luaL_optnumber(L, 3, 6); }
  return 0;
}
static int l_dd_text(lua_State *L) {
  float x = dd_num(L, 1), y = dd_num(L, 2);
  size_t n;
  const char *s = luaL_tolstring(L, 3, &n);        // anything printable
  DDCmd *c = dd_new(L, DD_TEXT, 4);
  if (c) {
    c->v[0] = x; c->v[1] = y;
    if (ov.pool_n + (int)n + 1 > OV_TEXT_POOL) { ov.ncmds--; ov.dropped++; }
    else {
      memcpy(ov.pool + ov.pool_n, s, n + 1);
      c->text = ov.pool_n;
      ov.pool_n += (int)n + 1;
    }
  }
  lua_pop(L, 1);
  return 0;
}
static int l_dd_screen(lua_State *L) { ov.screen = lua_toboolean(L, 1); return 0; }

// "file:line" of the Lua function calling us (full path, unlike luaL_where)
static void dd_where(lua_State *L, char *out, size_t cap) {
  lua_Debug ar;
  out[0] = 0;
  if (!lua_getstack(L, 1, &ar) || !lua_getinfo(L, "Sl", &ar) || ar.currentline < 0) return;
  const char *src = ar.source ? ar.source : "?";
  if (*src == '@' || *src == '=') src++;           // "@file" / "=name"
  SDL_snprintf(out, cap, "%s:%d", src, ar.currentline);
}

// Our own stack trace: one compact line per Lua frame, innermost first,
// "file:line name()" (file = basename; code leaves keep their node path).
// C frames and the engine's own frames (viewer boot code, ecs.lua) are left
// out. Pushes msg + "\n" + frames.
static void dd_traceback(lua_State *L, const char *msg) {
  luaL_Buffer b;
  lua_Debug ar;
  luaL_buffinit(L, &b);
  luaL_addstring(&b, msg);
  for (int level = 1, shown = 0; lua_getstack(L, level, &ar) && shown < 24; level++) {
    if (!lua_getinfo(L, "Sln", &ar)) break;
    if (ar.currentline < 0 || !strcmp(ar.what, "C")) continue;          // C functions
    const char *src = ar.source ? ar.source : "?";
    size_t sl = strlen(src);
    if (!strcmp(src, "=viewer") || (sl >= 7 && !strcmp(src + sl - 7, "ecs.lua"))) continue;  // engine
    const char *file = src;
    if (*src == '@') {                             // a file: its basename
      file = src + 1;
      for (const char *c = file; *c; c++) if ((*c == '/' || *c == '\\') && c[1]) file = c + 1;
    } else if (*src == '=') file = src + 1;        // a named chunk (code leaf: its node path)
    char line[300];
    if (ar.name) SDL_snprintf(line, sizeof line, "\n%s:%d %s()", file, ar.currentline, ar.name);
    else if (!strcmp(ar.what, "main")) SDL_snprintf(line, sizeof line, "\n%s:%d (main)", file, ar.currentline);
    else SDL_snprintf(line, sizeof line, "\n%s:%d function@%d()", file, ar.currentline, ar.linedefined);
    luaL_addstring(&b, line);
    shown++;
  }
  luaL_pushresult(&b);
}

// print-like: args joined by spaces. A message starting with "!" also logs
// the Lua stack trace (dd.log("!why am I here")).
static int dd_msg(lua_State *L, int level) {
  int n = lua_gettop(L);                           // before buffinit: it may push a box
  luaL_Buffer b;
  luaL_buffinit(L, &b);
  for (int i = 1; i <= n; i++) {
    if (i > 1) luaL_addchar(&b, ' ');
    luaL_tolstring(L, i, NULL);
    luaL_addvalue(&b);
  }
  luaL_pushresult(&b);
  char where[160];
  dd_where(L, where, sizeof where);
  // "!hello": the stack is appended to the message ("!hello\nball.lua:12
  // serve()\n..."), then logged as one text without the "!"
  const char *msg = lua_tostring(L, -1);
  if (msg[0] == '!') {
    dd_traceback(L, msg);
    msg = lua_tostring(L, -1);
  }
  ov_log_at(level, where, msg[0] == '!' ? msg + 1 : msg);
  return 0;
}
static int l_dd_log(lua_State *L) { return dd_msg(L, OV_INFO); }
static int l_dd_warn(lua_State *L) { return dd_msg(L, OV_WARN); }
static int l_dd_error(lua_State *L) { return dd_msg(L, OV_ERROR); }

// registers the global `dd`; call before the viewer's Lua boot code
static void ov_register(lua_State *L, bool enabled) {
  ov.enabled = enabled;
  static const luaL_Reg fns[] = {
    { "line", l_dd_line }, { "arrow", l_dd_arrow }, { "rect", l_dd_rect },
    { "circle", l_dd_circle }, { "tri", l_dd_tri }, { "cross", l_dd_cross },
    { "text", l_dd_text }, { "screen", l_dd_screen },
    { "log", l_dd_log }, { "warn", l_dd_warn }, { "error", l_dd_error },
    { NULL, NULL }
  };
  luaL_newlib(L, fns);
  lua_setglobal(L, "dd");
}

// ---------------------------------------------------------------------------
// rendering
// ---------------------------------------------------------------------------

static void ov_color(SDL_Renderer *r, const Uint8 c[4], float a) {
  SDL_SetRenderDrawColor(r, c[0], c[1], c[2], (Uint8)(c[3] * a));
}

static void ov_fill_poly(SDL_Renderer *r, const float *xy, int n, const Uint8 c[4]) {
  SDL_Vertex v[66];
  if (n > 64) n = 64;
  SDL_FColor fc = { c[0] / 255.f, c[1] / 255.f, c[2] / 255.f, c[3] / 255.f };
  int k = 0;
  int idx[64 * 3], ni = 0;
  for (int i = 0; i < n; i++) {
    v[k].position.x = xy[i * 2]; v[k].position.y = xy[i * 2 + 1];
    v[k].color = fc; v[k].tex_coord.x = v[k].tex_coord.y = 0; k++;
  }
  for (int i = 1; i + 1 < n; i++) { idx[ni++] = 0; idx[ni++] = i; idx[ni++] = i + 1; }
  SDL_RenderGeometry(r, NULL, v, k, idx, ni);
}

// text with a dark backing box so it reads over anything
static void ov_text(SDL_Renderer *r, float x, float y, const char *s, const Uint8 c[4], float a) {
  float w = 8.f * (float)strlen(s);
  SDL_FRect bg = { x - 3, y - 2, w + 6, 12 };
  SDL_SetRenderDrawColor(r, 0, 0, 0, (Uint8)(150 * a));
  SDL_RenderFillRect(r, &bg);
  ov_color(r, c, a);
  SDL_RenderDebugText(r, x, y, s);
}

static SDL_FRect ov_world;                         // the world's view inside the overlay (players: the host's), w 0: all of it, < 0: none
static void ov_draw_cmds(SDL_Renderer *r, int w, int h, float zoom, float camx, float camy) {
  if (ov_world.w < 0) return;
  float cx = ov_world.w > 0 ? ov_world.x + ov_world.w / 2 : w / 2.f, cy = ov_world.w > 0 ? ov_world.y + ov_world.h / 2 : h / 2.f;
  float ox = cx - camx * zoom, oy = cy - camy * zoom;
  if (ov_world.w > 0) { SDL_Rect c = { (int)ov_world.x, (int)ov_world.y, (int)ov_world.w, (int)ov_world.h }; SDL_SetRenderClipRect(r, &c); }
  for (int i = 0; i < ov.ncmds; i++) {
    const DDCmd *c = &ov.cmds[i];
    float k = c->screen ? 1 : zoom, tx = c->screen ? 0 : ox, ty = c->screen ? 0 : oy;
    float p[6];
    for (int j = 0; j < 6; j += 2) { p[j] = c->v[j] * k + tx; p[j + 1] = c->v[j + 1] * k + ty; }
    ov_color(r, c->col, 1);
    switch (c->type) {
    case DD_LINE: SDL_RenderLine(r, p[0], p[1], p[2], p[3]); break;
    case DD_ARROW: {
      SDL_RenderLine(r, p[0], p[1], p[2], p[3]);
      float dx = p[2] - p[0], dy = p[3] - p[1], len = SDL_sqrtf(dx * dx + dy * dy);
      if (len < 1) break;
      dx /= len; dy /= len;
      float hs = len < 24 ? len / 3 : 8;           // head size in pixels
      float t[6] = { p[2], p[3], p[2] - dx * hs - dy * hs * .5f, p[3] - dy * hs + dx * hs * .5f,
                     p[2] - dx * hs + dy * hs * .5f, p[3] - dy * hs - dx * hs * .5f };
      ov_fill_poly(r, t, 3, c->col);
      break;
    }
    case DD_RECT: case DD_RECTF: {
      SDL_FRect rc = { p[0], p[1], c->v[2] * k, c->v[3] * k };
      if (c->type == DD_RECTF) SDL_RenderFillRect(r, &rc); else SDL_RenderRect(r, &rc);
      break;
    }
    case DD_CIRCLE: case DD_CIRCLEF: {
      float rad = c->v[2] * k, xy[64];
      int n = rad < 8 ? 12 : 32;
      for (int j = 0; j < n; j++) {
        float a = j * 6.2831853f / n;
        xy[j * 2] = p[0] + SDL_cosf(a) * rad; xy[j * 2 + 1] = p[1] + SDL_sinf(a) * rad;
      }
      if (c->type == DD_CIRCLEF) ov_fill_poly(r, xy, n, c->col);
      else for (int j = 0; j < n; j++)
        SDL_RenderLine(r, xy[j * 2], xy[j * 2 + 1], xy[(j + 1) % n * 2], xy[(j + 1) % n * 2 + 1]);
      break;
    }
    case DD_TRI: ov_fill_poly(r, p, 3, c->col); break;
    case DD_CROSS: {
      float s = c->v[2];
      SDL_RenderLine(r, p[0] - s, p[1], p[0] + s, p[1]);
      SDL_RenderLine(r, p[0], p[1] - s, p[0], p[1] + s);
      break;
    }
    case DD_TEXT:
      if (c->text >= 0) SDL_RenderDebugText(r, p[0], p[1], ov.pool + c->text);
      break;
    }
  }
}

// end of a frame (drawn or not): presses are no longer "this frame"
static void ov_end_frame(void) {
  for (int i = 0; i < ov.nin; i++) ov.in[i].fresh = false;
}

// Render the overlay texture (w x h = the game area) and draw it at `dst`.
// stats: permanent lines, top-right. Bottom-right, bottom up: `foot`
// (time, speed, state), "frame N", then the keys being pressed.
static void ov_render(SDL_Renderer *r, const SDL_FRect *dst, float zoom, float camx, float camy,
                      const char *stats[], int nstats, int frame, const char *foot) {
  if (!ov.enabled) return;
  int w = (int)dst->w, h = (int)dst->h;
  if (w < 1 || h < 1) return;
  float rs = 1, rsy = 1;                          // (retina: the scale already set; the texture at the display's pixels)
  SDL_GetRenderScale(r, &rs, &rsy);
  if (rs < 1) rs = 1;
  if (!ov.tex || ov.tw != w || ov.th != h || ov.ts != rs) {
    if (ov.tex) SDL_DestroyTexture(ov.tex);
    ov.tex = SDL_CreateTexture(r, SDL_PIXELFORMAT_RGBA8888, SDL_TEXTUREACCESS_TARGET, (int)SDL_ceilf(w * rs), (int)SDL_ceilf(h * rs));
    ov.ts = rs;
    // drawing into a cleared (#00000000) target leaves premultiplied pixels:
    // compose them premultiplied, so untouched pixels are fully transparent
    // and faded text keeps its colour
    SDL_SetTextureBlendMode(ov.tex, SDL_BLENDMODE_BLEND_PREMULTIPLIED);
    ov.tw = w; ov.th = h;
  }
  SDL_Texture *prev = SDL_GetRenderTarget(r);
  SDL_SetRenderTarget(r, ov.tex);
  SDL_SetRenderScale(r, rs, rs);
  SDL_SetRenderDrawBlendMode(r, SDL_BLENDMODE_BLEND);
  SDL_SetRenderDrawColor(r, 0, 0, 0, 0);
  SDL_RenderClear(r);

  // 1. debugdraw
  ov_draw_cmds(r, w, h, zoom, camx, camy);
  SDL_SetRenderClipRect(r, NULL);

  Uint64 now = SDL_GetTicks();
  // 2. stats, top-right
  static const Uint8 STAT[4] = { 200, 205, 220, 255 };
  for (int i = 0; i < nstats; i++) {
    if (!stats[i] || !stats[i][0]) continue;
    float x = w - 8.f * (float)strlen(stats[i]) - 6;
    ov_text(r, x, 6 + i * 12.f, stats[i], STAT, 1);
  }
  if (ov.dropped) {
    char d[64];
    SDL_snprintf(d, sizeof d, "dd: %d dropped", ov.dropped);
    static const Uint8 WARN[4] = { 255, 200, 80, 255 };
    ov_text(r, w - 8.f * (float)strlen(d) - 6, 6 + nstats * 12.f, d, WARN, 1);
  }

  // 3. messages, top-left (oldest first); fade, then drop
  int keep = 0;
  float y = 6;
  for (int i = 0; i < ov.nlog; i++) {
    OvMsg *m = &ov.log[i];
    Uint64 age = now - m->t;
    if (age >= OV_MSG_HOLD_MS + OV_MSG_FADE_MS) continue;
    ov.log[keep++] = *m;
    float a = age <= OV_MSG_HOLD_MS ? 1.f : 1.f - (float)(age - OV_MSG_HOLD_MS) / OV_MSG_FADE_MS;
    static const Uint8 C[3][4] = { { 225, 228, 238, 255 }, { 255, 200, 80, 255 }, { 255, 95, 95, 255 } };
    char line[300];
    int maxc = (w - 12) / 8;
    if (m->count > 1) SDL_snprintf(line, sizeof line, "%s (x%d)", m->text, m->count);
    else SDL_snprintf(line, sizeof line, "%s", m->text);
    if ((int)strlen(line) > maxc && maxc > 3) { line[maxc - 2] = '.'; line[maxc - 1] = '.'; line[maxc] = 0; }
    ov_text(r, 6, y, line, C[m->level], a);
    y += 12;
  }
  ov.nlog = keep;

  // 3b. stopped at a breakpoint: a red frame round the game, a banner low, centred
  if (ov.banner[0][0]) {
    static const Uint8 RED[4] = { 224, 70, 78, 255 }, HINT[4] = { 235, 225, 225, 255 };
    ov_color(r, RED, 1);
    for (int t = 0; t < 3; t++) { SDL_FRect fr = { (float)t, (float)t, w - 2.f * t, h - 2.f * t }; SDL_RenderRect(r, &fr); }
    float s = w >= 480 ? 2.f : 1.f;               // (the first line twice as big, room permitting)
    float tw = 8.f * s * (float)strlen(ov.banner[0]);
    float bx = (w - tw) / 2, by = h - 90.f;       // (low: the messages, stats and a HUD sit at the top)
    SDL_FRect bg = { bx - 8, by - 6, tw + 16, 8 * s + 12 };
    SDL_SetRenderDrawColor(r, 120, 20, 28, 230);
    SDL_RenderFillRect(r, &bg);
    ov_color(r, RED, 1);
    SDL_RenderRect(r, &bg);
    float s0x = 1, s0y = 1;                       // (on top of the scale already set: retina)
    SDL_GetRenderScale(r, &s0x, &s0y);
    SDL_SetRenderScale(r, s * s0x, s * s0y);
    ov_color(r, HINT, 1);
    SDL_RenderDebugText(r, bx / s, by / s, ov.banner[0]);
    SDL_SetRenderScale(r, s0x, s0y);
    if (ov.banner[1][0]) ov_text(r, (w - 8.f * (float)strlen(ov.banner[1])) / 2, by + 8 * s + 12, ov.banner[1], HINT, 1);
  }

  // 4. input, frame, time: bottom-right (newest key at the bottom)
  static const Uint8 INPUT[4] = { 150, 220, 255, 255 }, FRAME[4] = { 140, 145, 165, 255 };
  char fr[32];
  SDL_snprintf(fr, sizeof fr, "frame %d", frame);
  y = h - 16.f;
  if (foot && foot[0]) {
    ov_text(r, w - 8.f * (float)strlen(foot) - 6, y, foot, STAT, 1);
    y -= 12;
  }
  ov_text(r, w - 8.f * (float)strlen(fr) - 6, y, fr, FRAME, 1);
  keep = 0;
  for (int i = 0; i < ov.nin; i++) {
    OvInput *e = &ov.in[i];
    if (!e->down && now - e->t >= OV_IN_FADE_MS) continue;
    ov.in[keep++] = *e;
  }
  ov.nin = keep;
  for (int i = ov.nin - 1; i >= 0 && y > h / 2.f; i--) {
    OvInput *e = &ov.in[i];
    float a = e->down ? 1.f : 1.f - (float)(now - e->t) / OV_IN_FADE_MS;
    static const Uint8 FRESH[4] = { 255, 235, 60, 255 };   // first frame of a press
    y -= 12;
    ov_text(r, w - 8.f * (float)strlen(e->name) - 6, y, e->name, e->fresh ? FRESH : INPUT, a);
  }

  SDL_SetRenderTarget(r, prev);
  SDL_RenderTexture(r, ov.tex, NULL, dst);
}
