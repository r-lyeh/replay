// lite editor, platform details for SDL3
// Replaces lite_sys.h (FWK/GLFW) with plain SDL3. Include before lite.h:
//
//   #include <minilua/minilua.h>        (Lua API, no LUA_IMPL here)
//   #include "stb_truetype.h"
//   #include "lite_sys_sdl3.h"
//   #include "lite.h"
//
// Embedding model: the host owns the window, renderer and event loop.
// It forwards SDL events with lt_sdl3_push_event() and draws the texture
// that lite renders into (lt_sdl3_texture()) wherever it likes.
//
// Ported from rxi/lite's SDL2 backend (src/api/system.c, renderer.c).

#pragma once
#include <SDL3/SDL.h>
#include <ctype.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifdef _WIN32
#include <windows.h>     // WinExec, used by lite's system.exec
#include <direct.h>      // chdir
#define chdir _chdir
#else
#include <unistd.h>      // chdir
#endif

#define LT_DATAPATH          "/lite"

// small helpers lite.h expects from its original host (FWK)
static inline int maxi(int a, int b) { return a > b ? a : b; }
static inline int mini(int a, int b) { return a < b ? a : b; }
#ifndef max
#define max(a, b) ((a) > (b) ? (a) : (b))
#endif

#define lt_assert(x)         SDL_assert(x)

#define lt_malloc(n)         malloc(n)
#define lt_calloc(n,m)       calloc(n,m)
#define lt_free(p)           free(p)
#define lt_memcpy(d,s,c)     memcpy(d,s,c)
#define lt_memset(p,ch,c)    memset(p,ch,c)

#define lt_time_ms()         ((unsigned)SDL_GetTicks())
#define lt_sleep_ms(ms)      SDL_Delay((Uint32)(ms))

// ---------------------------------------------------------------------------
// window, owned by the host

static SDL_Window   *lt_sdl3_win;
static int           lt_sdl3_offx, lt_sdl3_offy;  // editor area origin inside the window
static float         lt_sdl3_scale = 1;          //< Replay: retina, lite's pixels per host point
static SDL_Renderer *lt_sdl3_ren;
static int           lt_sdl3_wants_quit;

#define lt_window()          ((void *)lt_sdl3_win)
#define lt_setwindowtitle(t) ((void)(t))       // the host owns the title
#define lt_haswindowfocus()  ((SDL_GetWindowFlags(lt_sdl3_win) & SDL_WINDOW_INPUT_FOCUS) != 0)

static void lt_displaysize(int *w, int *h) {    // the monitor the window is on, in pixels (else the window)
  const SDL_DisplayMode *m = SDL_GetCurrentDisplayMode(SDL_GetDisplayForWindow(lt_sdl3_win));
  if (m && m->w > 0 && m->h > 0) {
    float d = m->pixel_density > 0 ? m->pixel_density : 1;
    *w = (int)(m->w * d + 0.5f); *h = (int)(m->h * d + 0.5f);
  } else SDL_GetWindowSizeInPixels(lt_sdl3_win, w, h);
}

static void lt_setwindowmode(int m) {           // 0:normal, 1:maximized, 2:fullscreen
  SDL_SetWindowFullscreen(lt_sdl3_win, m == 2);
  if (m == 1) SDL_MaximizeWindow(lt_sdl3_win);
  else if (m == 0) SDL_RestoreWindow(lt_sdl3_win);
}

static void lt_setcursor(int shape) {           // 0:arrow 1:ibeam 2:sizeh 3:sizev 4:hand
  static SDL_Cursor *cache[5];
  static const SDL_SystemCursor ids[5] = {
    SDL_SYSTEM_CURSOR_DEFAULT, SDL_SYSTEM_CURSOR_TEXT, SDL_SYSTEM_CURSOR_EW_RESIZE,
    SDL_SYSTEM_CURSOR_NS_RESIZE, SDL_SYSTEM_CURSOR_POINTER,
  };
  if (shape < 0 || shape > 4) shape = 0;
  if (!cache[shape]) cache[shape] = SDL_CreateSystemCursor(ids[shape]);
  if (cache[shape]) SDL_SetCursor(cache[shape]);
}

static int lt_prompt(const char *msg, const char *title) {
  const SDL_MessageBoxButtonData buttons[] = {
    { SDL_MESSAGEBOX_BUTTON_RETURNKEY_DEFAULT, 1, "Yes" },
    { SDL_MESSAGEBOX_BUTTON_ESCAPEKEY_DEFAULT, 0, "No" },
  };
  SDL_MessageBoxData data = { SDL_MESSAGEBOX_WARNING, lt_sdl3_win, title, msg,
                              SDL_arraysize(buttons), buttons, NULL };
  int id = 0;
  if (!SDL_ShowMessageBox(&data, &id)) return 0;
  return id == 1;
}

// a dialog with up to 4 buttons (left to right): -> the one picked, 1..n; 0:
// closed / failed. Enter: the first, ESC: the last  (Replay: unsaved changes)
static int lt_dialog(const char *title, const char *msg, const char **labels, int n) {
  SDL_MessageBoxButtonData buttons[4];
  if (n > 4) n = 4;
  for (int i = 0; i < n; i++) {
    buttons[i].flags = i == 0 ? SDL_MESSAGEBOX_BUTTON_RETURNKEY_DEFAULT : i == n - 1 ? SDL_MESSAGEBOX_BUTTON_ESCAPEKEY_DEFAULT : 0;
    buttons[i].buttonID = i + 1;
    buttons[i].text = labels[i];
  }
  SDL_MessageBoxData data = { SDL_MESSAGEBOX_WARNING, lt_sdl3_win, title, msg, n, buttons, NULL };
  int id = 0;
  if (!SDL_ShowMessageBox(&data, &id)) return 0;
  return id;
}

// clipboard: SDL3 returns memory we must free; lite doesn't, so keep one
static const char *lt_getclipboard(void *w) {
  static char *last = NULL;
  (void)w;
  SDL_free(last);
  last = SDL_GetClipboardText();
  return last;
}
#define lt_setclipboard(w, s) SDL_SetClipboardText(s)

// paths
#ifdef _WIN32
#define lt_realpath(p, q)    _fullpath(NULL, (p), 0)
#else
#define lt_realpath(p, q)    realpath((p), NULL)
#endif
#define lt_realpath_free(p)  free(p)

// ---------------------------------------------------------------------------
// surface: lite draws into CPU pixels (BGRA), we mirror them to a texture

typedef struct lt_surface {
  unsigned w, h;
  void *pixels;
  SDL_Texture *t;
} lt_surface;

typedef struct lt_rect {
  int x, y, width, height;
} lt_rect;

static lt_surface lt_sdl3_surface;

static lt_surface *lt_getsurface(void *window) {
  (void)window;
  return &lt_sdl3_surface;
}

static void lt_updatesurfacerects(lt_surface *s, lt_rect *rects, unsigned count) {
  if (!s->t) return;
  if (!rects) {                                  // whole surface
    SDL_UpdateTexture(s->t, NULL, s->pixels, (int)s->w * 4);
    return;
  }
  for (unsigned i = 0; i < count; i++) {
    lt_rect r = rects[i];
    if (r.width <= 0 || r.height <= 0) continue;
    SDL_Rect sr = { r.x, r.y, r.width, r.height };
    const Uint8 *p = (const Uint8 *)s->pixels + ((size_t)r.y * s->w + r.x) * 4;
    SDL_UpdateTexture(s->t, &sr, p, (int)s->w * 4);
  }
}

void ren_set_clip_rect(struct lt_rect rect);
void rencache_invalidate(void);

static int lt_resizesurface(lt_surface *s, int ww, int wh) {
  if (ww < 1) ww = 1;
  if (wh < 1) wh = 1;
  if (s->t && (int)s->w == ww && (int)s->h == wh) return 0;
  s->w = ww, s->h = wh;
  free(s->pixels);
  s->pixels = calloc((size_t)ww * wh, 4);
  if (s->t) SDL_DestroyTexture(s->t);
  // ARGB8888 is B,G,R,A in memory on little-endian: lite's RenColor layout
  s->t = SDL_CreateTexture(lt_sdl3_ren, SDL_PIXELFORMAT_ARGB8888,
                           SDL_TEXTUREACCESS_STREAMING, ww, wh);
  if (s->t) SDL_SetTextureBlendMode(s->t, SDL_BLENDMODE_BLEND_PREMULTIPLIED);
  ren_set_clip_rect((lt_rect){ 0, 0, ww, wh });
  rencache_invalidate();
  lt_updatesurfacerects(s, NULL, 0);
  return 1;
}

// ---------------------------------------------------------------------------
// files

static void *lt_load_file(const char *filename, int *size) {
  if (size) *size = 0;
  FILE *f = fopen(filename, "rb");
  if (!f) return NULL;
  fseek(f, 0, SEEK_END);
  long n = ftell(f);
  fseek(f, 0, SEEK_SET);
  char *data = (char *)malloc(n > 0 ? n + 1 : 1);
  if (!data) { fclose(f); return NULL; }
  size_t got = n > 0 ? fread(data, 1, (size_t)n, f) : 0;
  fclose(f);
  data[got] = 0;
  if (size) *size = (int)got;
  return data;
}

typedef struct { struct lua_State *L; int n; } lt_glob_ctx;

static SDL_EnumerationResult SDLCALL lt_glob_cb(void *ud, const char *dirname, const char *fname) {
  lt_glob_ctx *c = (lt_glob_ctx *)ud;
  (void)dirname;
  lua_pushstring(c->L, fname);
  lua_rawseti(c->L, -2, ++c->n);
  return SDL_ENUM_CONTINUE;
}

// push the names in `path` into the table on top of the stack
static void lt_globpath(struct lua_State *L, const char *path) {
  lt_glob_ctx c = { L, 0 };
  SDL_EnumerateDirectory(path, lt_glob_cb, &c);
}

// ---------------------------------------------------------------------------
// events: the host pushes SDL events, lite pops them in core.step()

#define LT_EVQ 256
static SDL_Event lt_evq[LT_EVQ];
static int lt_evq_head, lt_evq_tail;

static void lt_sdl3_push_event(const SDL_Event *e) {
  int next = (lt_evq_tail + 1) % LT_EVQ;
  if (next == lt_evq_head) return;               // full: drop
  lt_evq[lt_evq_tail] = *e;
  lt_evq_tail = next;
}

static const char *lt_button_name(int button) {
  switch (button) {
  case SDL_BUTTON_LEFT: return "left";
  case SDL_BUTTON_MIDDLE: return "middle";
  case SDL_BUTTON_RIGHT: return "right";
  default: return "?";
  }
}

// lite expects SDL2-style lowercase names: "left ctrl", "return", "a", ...
static const char *lt_key_name(char *dst, SDL_Keycode key) {
  SDL_strlcpy(dst, SDL_GetKeyName(key), 32);
  for (char *p = dst; *p; p++) *p = (char)tolower((unsigned char)*p);
  return dst;
}

static int lt_poll_event(lua_State *L) {
  char buf[32];
  while (lt_evq_head != lt_evq_tail) {
    SDL_Event e = lt_evq[lt_evq_head];
    lt_evq_head = (lt_evq_head + 1) % LT_EVQ;

    switch (e.type) {
    case SDL_EVENT_QUIT:
      lua_pushstring(L, "quit");
      return 1;

    case SDL_EVENT_WINDOW_PIXEL_SIZE_CHANGED:
      lt_resizesurface(&lt_sdl3_surface, e.window.data1, e.window.data2);
      lua_pushstring(L, "resized");
      lua_pushnumber(L, e.window.data1);
      lua_pushnumber(L, e.window.data2);
      return 3;

    case SDL_EVENT_WINDOW_EXPOSED:
      rencache_invalidate();
      lua_pushstring(L, "exposed");
      return 1;

    case SDL_EVENT_DROP_FILE: {
      float wx, wy, mx = 0, my = 0;                // window units -> render pixels
      SDL_GetMouseState(&wx, &wy);
      SDL_RenderCoordinatesFromWindow(lt_sdl3_ren, wx, wy, &mx, &my);
      lua_pushstring(L, "filedropped");
      lua_pushstring(L, e.drop.data);
      lua_pushnumber(L, (int)((mx - lt_sdl3_offx) * lt_sdl3_scale));
      lua_pushnumber(L, (int)((my - lt_sdl3_offy) * lt_sdl3_scale));
      return 4;
    }

    case SDL_EVENT_KEY_DOWN:
      lua_pushstring(L, "keypressed");
      lua_pushstring(L, lt_key_name(buf, e.key.key));
      return 2;

    case SDL_EVENT_KEY_UP:
      lua_pushstring(L, "keyreleased");
      lua_pushstring(L, lt_key_name(buf, e.key.key));
      return 2;

    case SDL_EVENT_TEXT_INPUT:
      lua_pushstring(L, "textinput");
      lua_pushstring(L, e.text.text);
      return 2;

    case SDL_EVENT_MOUSE_BUTTON_DOWN:
      lua_pushstring(L, "mousepressed");
      lua_pushstring(L, lt_button_name(e.button.button));
      lua_pushnumber(L, (int)e.button.x);
      lua_pushnumber(L, (int)e.button.y);
      lua_pushnumber(L, e.button.clicks);
      return 5;

    case SDL_EVENT_MOUSE_BUTTON_UP:
      lua_pushstring(L, "mousereleased");
      lua_pushstring(L, lt_button_name(e.button.button));
      lua_pushnumber(L, (int)e.button.x);
      lua_pushnumber(L, (int)e.button.y);
      return 4;

    case SDL_EVENT_MOUSE_MOTION:
      lua_pushstring(L, "mousemoved");
      lua_pushnumber(L, (int)e.motion.x);
      lua_pushnumber(L, (int)e.motion.y);
      lua_pushnumber(L, (int)e.motion.xrel);
      lua_pushnumber(L, (int)e.motion.yrel);
      return 5;

    case SDL_EVENT_MOUSE_WHEEL:
      lua_pushstring(L, "mousewheel");
      lua_pushnumber(L, e.wheel.y);
      lua_pushnumber(L, e.wheel.x);                // horizontal wheel / trackpad (lite's views ignore it)
      return 3;

    default:
      break;                                     // ignore, try the next one
    }
  }
  return 0;
}
