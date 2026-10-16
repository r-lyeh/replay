// editor/editor.c - the lite text editor (r-lyeh/lite fork), embedded with SDL3.
//
// lite lives in this separate translation unit because lite.h, stb_truetype
// and the Lua implementation all define plenty of global names. It runs in
// its OWN Lua state, fully separate from the game world's VM.
//
// Build: compile alongside play.c, e.g.  cl editor/editor.c play.c -I 3rd ...

#define _DEFAULT_SOURCE                    // realpath() on POSIX
#ifdef _WIN32
#include <winsock2.h>                      // (before lite's <windows.h>: editor/udp.h, the world's UDP sockets)
#include <ws2tcpip.h>
#endif
#include <minilua/minilua.h>          // Lua 5.4 API (implementation is in play.c)

#define STB_TRUETYPE_IMPLEMENTATION
#define STBTT_STATIC
#include "lite/stb_truetype.h"

#define STB_IMAGE_IMPLEMENTATION                   // images for lite (renderer.image.load): PNG, JPG, BMP, TGA, GIF
#define STB_IMAGE_STATIC
#define STBI_NO_STDIO                              // (lite reads the file, stb decodes it from memory)
#define STBI_ONLY_PNG
#define STBI_ONLY_JPEG
#define STBI_ONLY_BMP
#define STBI_ONLY_TGA
#define STBI_ONLY_GIF
#include "lite/stb_image.h"

#define STB_IMAGE_WRITE_IMPLEMENTATION             // PNGs written by lite (renderer.image.write_atlas: plugins/atlaspacker)
#define STB_IMAGE_WRITE_STATIC
#define STBI_WRITE_NO_STDIO                        // (written through SDL: paths in UTF-8 everywhere)
#include "lite/stb_image_write.h"

#include "lite/lite_sys_sdl3.h"
#include "lite/lite.h"

#include "editor.h"
#include "editor/udp.h"                    // UDP sockets for the world's Lua (net.udp): here, with the system headers

// images for the game too (play.c: the `image` component): RGBA, 4 bytes a pixel
unsigned char *editor_image_decode(const void *data, int size, int *w, int *h) {
  int n = 0;
  return stbi_load_from_memory((const stbi_uc *)data, size, w, h, &n, 4);
}
void editor_image_free(unsigned char *pixels) { stbi_image_free(pixels); }

static lua_State *EL;
static SDL_Rect vp;                                // editor area in window pixels (w=0: whole window)
static char editor_err[8192];                       // (room for a traceback whole)
static int host_err_seq;                           // (editor_error_seq: bumps on a new error, the host logs it)
static char plugins_dir[1024];                     // the project's plugins/ (editor_set_plugins_dir): lite's host_plugins_dir
void editor_set_plugins_dir(const char *dir) { SDL_strlcpy(plugins_dir, dir ? dir : "", sizeof plugins_dir); }
static bool scripted;                              // a scripted run (tests): no workspace read or written (host_scripted)
void editor_set_scripted(bool on) { scripted = on; }

// Sound for lite's plugins (the sfxr editor): one mono stream, opened on the
// first call. host_audio_play(samples, rate): samples is a string of 16-bit
// little-endian PCM; whatever was playing stops. host_audio_stop().
// host_audio_queued() -> bytes still to play. -> true | nil, err
static SDL_AudioStream *audio_stream;
static int audio_rate;
static int l_audio_play(lua_State *L) {
  size_t n = 0;
  const char *pcm = luaL_checklstring(L, 1, &n);
  int rate = (int)luaL_optinteger(L, 2, 44100);
  if (!audio_stream || audio_rate != rate) {
    if (!SDL_WasInit(SDL_INIT_AUDIO) && !SDL_InitSubSystem(SDL_INIT_AUDIO)) { lua_pushnil(L); lua_pushstring(L, SDL_GetError()); return 2; }
    if (audio_stream) SDL_DestroyAudioStream(audio_stream);
    SDL_AudioSpec spec = { SDL_AUDIO_S16LE, 1, rate };
    audio_stream = SDL_OpenAudioDeviceStream(SDL_AUDIO_DEVICE_DEFAULT_PLAYBACK, &spec, NULL, NULL);
    if (!audio_stream) { lua_pushnil(L); lua_pushstring(L, SDL_GetError()); return 2; }
    audio_rate = rate;
    SDL_ResumeAudioStreamDevice(audio_stream);
  }
  SDL_ClearAudioStream(audio_stream);
  if (n && !SDL_PutAudioStreamData(audio_stream, pcm, (int)(n & ~(size_t)1))) { lua_pushnil(L); lua_pushstring(L, SDL_GetError()); return 2; }
  lua_pushboolean(L, 1);
  return 1;
}
static int l_audio_stop(lua_State *L) { (void)L; if (audio_stream) SDL_ClearAudioStream(audio_stream); return 0; }
static int l_audio_queued(lua_State *L) { lua_pushinteger(L, audio_stream ? SDL_GetAudioStreamQueued(audio_stream) : 0); return 1; }

// lite starts with data/replay.lua (in lite's folder, `datadir`): like
// lite.h's lt_init(), but errors are reported instead of exiting, and
// os.exit() inside lite (the quit command) becomes a request the host acts on.

static const char *STEP =
  "core.frame_start = system.get_time()\n"
  "core.run1()\n";

static const char *(*probe_fn)(const char *file);   // the viewer's (editor_set_probe)
void editor_set_probe(const char *(*fn)(const char *file)) { probe_fn = fn; }
static const char *(*probe_eval_fn)(const char *file, int line, const char *src);   // (editor_set_probe_eval)
void editor_set_probe_eval(const char *(*fn)(const char *file, int line, const char *src)) { probe_eval_fn = fn; }
static void (*break_set_fn)(const char *file, int line, bool on, int as, int fdef);
static const char *(*break_where_fn)(void);
void editor_set_breaks(void (*set)(const char *, int, bool, int, int), const char *(*where)(void)) { break_set_fn = set; break_where_fn = where; }
static int l_break_set(lua_State *L) {               // host_break_set(file, line, on [, as, fdef]): as: an alias (probe.h)
  if (break_set_fn) break_set_fn(luaL_checkstring(L, 1), (int)luaL_checkinteger(L, 2), lua_toboolean(L, 3),
                                 (int)luaL_optinteger(L, 4, 0), (int)luaL_optinteger(L, 5, 0));
  return 0;
}
static const char *(*world_file_fn)(void);
void editor_set_world_file(const char *(*fn)(void)) { world_file_fn = fn; }
static int l_world_file(lua_State *L) {              // host_world_file() -> the world's main file | nil
  const char *f = world_file_fn ? world_file_fn() : NULL;
  if (!f || !f[0]) return 0;
  lua_pushstring(L, f);
  return 1;
}
static void (*break_step_fn)(const char *mode);
void editor_set_break_step(void (*step)(const char *)) { break_step_fn = step; }
static int l_break_step(lua_State *L) {              // host_break_step("over" | "in" | "out" | "continue")
  if (break_step_fn) break_step_fn(luaL_checkstring(L, 1));
  return 0;
}
static int l_break_where(lua_State *L) {             // host_break_where() -> file, line, n | nil
  const char *w = break_where_fn ? break_where_fn() : NULL;
  if (!w) return 0;
  const char *a = strchr(w, '\n'), *b = a ? strchr(a + 1, '\n') : NULL;
  if (!a || !b) return 0;
  lua_pushlstring(L, w, (size_t)(a - w));
  lua_pushinteger(L, atoi(a + 1));
  lua_pushinteger(L, atoi(b + 1));
  return 3;
}
static int l_probe_eval(lua_State *L) {              // host_probe_eval(file, line, expr) -> "value" | nil
  const char *r = probe_eval_fn ? probe_eval_fn(luaL_checkstring(L, 1), (int)luaL_checkinteger(L, 2), luaL_checkstring(L, 3)) : NULL;
  if (r) lua_pushstring(L, r); else lua_pushnil(L);
  return 1;
}
static int l_probe(lua_State *L) {                   // host_probe(file) -> "return {...}" | nil
  const char *r = probe_fn ? probe_fn(luaL_checkstring(L, 1)) : NULL;
  if (r) lua_pushstring(L, r); else lua_pushnil(L);
  return 1;
}

static int l_host_error(lua_State *L) {              // host_error(text): a frame's update / draw failed (core.frame_try)
  SDL_snprintf(editor_err, sizeof editor_err, "lite: %s", luaL_checkstring(L, 1));
  host_err_seq++;
  return 0;
}
int editor_error_seq(void) { return host_err_seq; }
static int l_quit(lua_State *L) {
  (void)L;
  lt_sdl3_wants_quit = 1;
  return 0;
}

static bool run(const char *src, const char *name, int nargs) {
  int base = lua_gettop(EL) - nargs;
  if (luaL_loadbuffer(EL, src, strlen(src), name) != 0) goto fail;
  lua_insert(EL, base + 1);                          // chunk below its args
  if (lua_pcall(EL, nargs, 0, 0) != 0) goto fail;
  return true;
fail:
  if (strcmp(editor_err + (strncmp(editor_err, "lite: ", 6) ? 0 : 6), lua_tostring(EL, -1) ? lua_tostring(EL, -1) : "")) host_err_seq++;   // (new: the host logs it)
  SDL_snprintf(editor_err, sizeof editor_err, "lite: %s", lua_tostring(EL, -1));
  lua_settop(EL, base);
  return false;
}

bool editor_init(SDL_Window *win, SDL_Renderer *ren, const char *datadir, const char *project) {
  editor_err[0] = 0;
  lt_sdl3_win = win;
  lt_sdl3_ren = ren;

  char check[1024];
  SDL_snprintf(check, sizeof check, "%s/data/core/init.lua", datadir);
  if (!SDL_GetPathInfo(check, NULL)) {
    SDL_snprintf(editor_err, sizeof editor_err, "lite: data not found in %s/data", datadir);
    return false;
  }

  int w = 0, h = 0;
  if (vp.w > 0 && vp.h > 0) { w = vp.w; h = vp.h; }
  else SDL_GetWindowSizeInPixels(win, &w, &h);
  lt_resizesurface(&lt_sdl3_surface, w, h);
  if (!lt_sdl3_surface.t) {
    SDL_snprintf(editor_err, sizeof editor_err, "lite: %s", SDL_GetError());
    return false;
  }

  EL = luaL_newstate();
  luaL_openlibs(EL);
  ren_init(win);
  api_load_libs(EL);                                 // `system`, `renderer`

  lua_newtable(EL);                                  // ARGS = { exe, project }
  lua_pushstring(EL, "lite");
  lua_rawseti(EL, -2, 1);
  if (project) { lua_pushstring(EL, project); lua_rawseti(EL, -2, 2); }
  lua_setglobal(EL, "ARGS");
  lua_pushstring(EL, "1.11");
  lua_setglobal(EL, "VERSION");
  lua_pushstring(EL, SDL_GetPlatform());
  lua_setglobal(EL, "PLATFORM");
  lua_pushnumber(EL, 1.0);
  lua_setglobal(EL, "SCALE");
  lua_pushstring(EL, datadir);
  lua_setglobal(EL, "DATADIR");
  lua_pushstring(EL, "lite");
  lua_setglobal(EL, "EXEFILE");
  lua_pushcfunction(EL, l_quit);
  lua_setglobal(EL, "lite_quit");
  lua_pushcfunction(EL, l_probe);
  lua_setglobal(EL, "host_probe");
  lua_pushcfunction(EL, l_probe_eval);
  lua_setglobal(EL, "host_probe_eval");
  lua_pushcfunction(EL, l_break_set);
  lua_setglobal(EL, "host_break_set");
  lua_pushcfunction(EL, l_break_where);
  lua_setglobal(EL, "host_break_where");
  lua_pushcfunction(EL, l_break_step);
  lua_setglobal(EL, "host_break_step");
  lua_pushcfunction(EL, l_world_file);
  lua_setglobal(EL, "host_world_file");
  lua_pushcfunction(EL, l_host_error);
  lua_setglobal(EL, "host_error");
  if (plugins_dir[0]) lua_pushstring(EL, plugins_dir); else lua_pushboolean(EL, 0);
  lua_setglobal(EL, "host_plugins_dir");             // (data/plugins/projectplugins.lua loads its folders)
  lua_pushboolean(EL, scripted);
  lua_setglobal(EL, "host_scripted");                // (data/plugins/workspace.lua: a test starts clean, leaves nothing)
  lua_pushcfunction(EL, l_audio_play);
  lua_setglobal(EL, "host_audio_play");              // (plugins/sfxr: its sounds)
  lua_pushcfunction(EL, l_audio_stop);
  lua_setglobal(EL, "host_audio_stop");
  lua_pushcfunction(EL, l_audio_queued);
  lua_setglobal(EL, "host_audio_queued");

  char boot[1200];                                   // (lite's start: data/replay.lua)
  SDL_snprintf(boot, sizeof boot, "%s/data/replay.lua", datadir);
  if (luaL_loadfilex(EL, boot, "t") != LUA_OK) {
    SDL_snprintf(editor_err, sizeof editor_err, "lite: %s", lua_tostring(EL, -1));
    lua_close(EL);
    EL = NULL;
    return false;
  }
  lua_pushstring(EL, datadir);
  if (lua_pcall(EL, 1, 0, 0) != LUA_OK) {
    SDL_snprintf(editor_err, sizeof editor_err, "lite: %s", lua_tostring(EL, -1));
    lua_close(EL);
    EL = NULL;
    return false;
  }
  return true;
}

bool editor_open(const char *file, int line) {
  if (!EL) return false;
  lua_getglobal(EL, "lite_open");
  lua_pushstring(EL, file);
  lua_pushinteger(EL, line);
  if (lua_pcall(EL, 2, 0, 0) != 0) {
    SDL_snprintf(editor_err, sizeof editor_err, "lite: %s", lua_tostring(EL, -1));
    lua_pop(EL, 1);
    return false;
  }
  return true;
}

bool editor_open_error(const char *file, int line, const char *msg) {
  if (!EL) return false;
  lua_getglobal(EL, "lite_open_error");
  lua_pushstring(EL, file);
  lua_pushinteger(EL, line);
  lua_pushstring(EL, msg ? msg : "");
  if (lua_pcall(EL, 3, 0, 0) != 0) {
    SDL_snprintf(editor_err, sizeof editor_err, "lite: %s", lua_tostring(EL, -1));
    lua_pop(EL, 1);
    return false;
  }
  return true;
}

void editor_log(int level, const char *text, const char *at) {
  if (!EL) return;
  lua_getglobal(EL, "lite_log");
  lua_pushinteger(EL, level);
  lua_pushstring(EL, text);
  lua_pushstring(EL, at ? at : "");
  if (lua_pcall(EL, 3, 0, 0) != 0) lua_pop(EL, 1);
}

static int want_log;                               // after the next step: 1 show, 2 hide, 3 boot rule
static char open_later[1024];                      // a file to open after the next step (editor_open_later)
static int open_later_line = 1;
void editor_open_later_at(const char *file, int line) {
  SDL_strlcpy(open_later, file ? file : "", sizeof open_later);
  open_later_line = line > 0 ? line : 0;           // (0: keep its cursor)
}
void editor_open_later(const char *file) { editor_open_later_at(file, 1); }
static int boot_log_arg = -1;                      // --log 1, --no-log 0, neither -1

void editor_show_log(void) { want_log = 1; }
void editor_set_log(bool show) { want_log = show ? 1 : 2; }
void editor_boot_log(int arg) { want_log = 3; boot_log_arg = arg; }

bool editor_log_shown(void) {
  if (!EL) return false;
  if (want_log == 1 || want_log == 2) return want_log == 1;   // (asked, not applied yet)
  lua_getglobal(EL, "lite_log_shown");
  bool on = false;
  if (lua_pcall(EL, 0, 1, 0) == 0) on = lua_toboolean(EL, -1);
  lua_pop(EL, 1);
  return on;
}

// after lite's step: the workspace plugin restores the previous session's
// tabs on the first one, so the Log tab is shown / hidden after it
static void show_log_now(void) {
  if (!EL) return;
  int w = want_log;
  want_log = 0;
  lua_getglobal(EL, w == 1 ? "lite_show_log" : w == 2 ? "lite_hide_log" : "lite_boot_log");
  if (w == 3) lua_pushinteger(EL, boot_log_arg);
  if (lua_pcall(EL, w == 3 ? 1 : 0, 0, 0) != 0) {
    SDL_snprintf(editor_err, sizeof editor_err, "lite: %s", lua_tostring(EL, -1));
    lua_pop(EL, 1);
  }
}

void editor_viewport(int x, int y, int w, int h) {
  if (w < 1) w = 1;
  if (h < 1) h = 1;
  bool resized = vp.w != w || vp.h != h;
  vp.x = x; vp.y = y; vp.w = w; vp.h = h;
  lt_sdl3_offx = x; lt_sdl3_offy = y;
  if (EL && resized) {                             // lite resizes its surface on this event
    SDL_Event r = { 0 };
    r.type = SDL_EVENT_WINDOW_PIXEL_SIZE_CHANGED;
    r.window.data1 = w;
    r.window.data2 = h;
    lt_sdl3_push_event(&r);
  }
}

void editor_event(const SDL_Event *e) {
  if (!EL) return;
  // right button: play.c keeps it while the game is visible (picking) and
  // passes it on in the editor-only view (lite's context menu)
  SDL_Event c = *e;
  switch (c.type) {
  case SDL_EVENT_WINDOW_RESIZED:                   // the host sizes us via editor_viewport()
  case SDL_EVENT_WINDOW_PIXEL_SIZE_CHANGED:
    return;
  case SDL_EVENT_MOUSE_MOTION:
    c.motion.x -= vp.x; c.motion.y -= vp.y;
    break;
  case SDL_EVENT_MOUSE_BUTTON_DOWN:
  case SDL_EVENT_MOUSE_BUTTON_UP:
    c.button.x -= vp.x; c.button.y -= vp.y;
    break;
  }
  lt_sdl3_push_event(&c);
}

void editor_focus(bool on) {
  if (!lt_sdl3_win) return;
  if (on) SDL_StartTextInput(lt_sdl3_win);
  else SDL_StopTextInput(lt_sdl3_win);
}

void editor_frame(void) {
  if (!EL) return;
  bool ok = run(STEP, "=lite_step", 0);
  if (want_log && ok) show_log_now();
  if (open_later[0] && ok) {                       // (after the log: the file's tab ends up in front)
    char f[1024];
    SDL_strlcpy(f, open_later, sizeof f);
    open_later[0] = 0;
    editor_open(f, open_later_line);
  }
  if (!ok && !lt_sdl3_wants_quit) {
    // keep running: lite normally logs its own errors via core.try; an
    // error that escapes is shown by the host through editor_error()
  }
}

SDL_Texture *editor_texture(void) { return EL ? lt_sdl3_surface.t : NULL; }

// lite's look for the viewer's own panels: its UI font (style.font: the
// same glyphs lite bakes, each glyph set's bitmap uploaded once as a
// texture) and its theme's colours (style.<key>, style.syntax.<key>).
static RenFont *ui_font;                           // style.font as of editor_ui_begin
static struct { GlyphSet *set; SDL_Texture *tex; } ui_tex[32];
static int ui_ntex;
static void ui_tex_clear(void) {
  for (int i = 0; i < ui_ntex; i++) SDL_DestroyTexture(ui_tex[i].tex);
  ui_ntex = 0;
}
int editor_ui_begin(void) {
  RenFont *f = NULL;
  if (EL) {
    lua_getglobal(EL, "host_ui_font");             // (a size of its own: CTRL+wheel over the tab)
    RenFont **own = lua_isuserdata(EL, -1) ? lua_touserdata(EL, -1) : NULL;
    if (own) f = *own;
    lua_pop(EL, 1);
  }
  if (EL && !f) {
    lua_getglobal(EL, "package");
    lua_getfield(EL, -1, "loaded");
    lua_getfield(EL, -1, "core.style");
    if (lua_istable(EL, -1)) {
      lua_getfield(EL, -1, "font");
      RenFont **u = lua_touserdata(EL, -1);
      if (u) f = *u;
      lua_pop(EL, 1);
    }
    lua_pop(EL, 3);
  }
  if (f != ui_font) { ui_tex_clear(); ui_font = f; }   // (a new font: its glyphs again)
  return f ? f->height : 0;
}
static SDL_Texture *ui_glyphs(GlyphSet *set) {
  for (int i = 0; i < ui_ntex; i++) if (ui_tex[i].set == set) return ui_tex[i].tex;
  if (ui_ntex == (int)SDL_arraysize(ui_tex)) ui_tex_clear();
  SDL_Texture *t = SDL_CreateTexture(lt_sdl3_ren, SDL_PIXELFORMAT_ARGB8888, SDL_TEXTUREACCESS_STATIC,
                                     set->image->width, set->image->height);
  if (!t) return NULL;
  SDL_UpdateTexture(t, NULL, set->image->pixels, set->image->width * 4);
  SDL_SetTextureBlendMode(t, SDL_BLENDMODE_BLEND);
  SDL_SetTextureScaleMode(t, SDL_SCALEMODE_NEAREST);
  ui_tex[ui_ntex].set = set; ui_tex[ui_ntex].tex = t; ui_ntex++;
  return t;
}
float editor_ui_text(SDL_Renderer *r, float x, float y, const char *text, SDL_Color c) {
  if (!ui_font) return x;
  x = SDL_floorf(x); y = SDL_floorf(y);
  const char *p = text;
  unsigned cp;
  while (*p) {
    p = utf8_to_codepoint(p, &cp);
    GlyphSet *set = get_glyphset(ui_font, cp);
    stbtt_bakedchar *g = &set->glyphs[cp & 0xff];
    if (r && g->x1 > g->x0) {
      SDL_Texture *t = ui_glyphs(set);
      if (t) {
        SDL_SetTextureColorMod(t, c.r, c.g, c.b);
        SDL_SetTextureAlphaMod(t, c.a);
        SDL_FRect src = { g->x0, g->y0, (float)(g->x1 - g->x0), (float)(g->y1 - g->y0) };
        SDL_FRect dst = { x + g->xoff, y + g->yoff, src.w, src.h };
        SDL_RenderTexture(r, t, &src, &dst);
      }
    }
    x += g->xadvance;
  }
  return x;
}
// the GPU lost what textures held (SDL: the render targets or the device
// were reset; or just to be safe, the window exposed again): lite's image
// goes up whole again from its own pixels (it only sends what it redraws),
// its texture made again after a device reset; our glyphs too, as needed.
void editor_render_reset(bool device) {
  ui_tex_clear();
  lt_surface *s = &lt_sdl3_surface;
  if (!EL || !s->pixels) return;
  if (device) {
    if (s->t) SDL_DestroyTexture(s->t);
    s->t = SDL_CreateTexture(lt_sdl3_ren, SDL_PIXELFORMAT_ARGB8888, SDL_TEXTUREACCESS_STREAMING, (int)s->w, (int)s->h);
    if (s->t) SDL_SetTextureBlendMode(s->t, SDL_BLENDMODE_NONE);
  }
  lt_updatesurfacerects(s, NULL, 0);
  rencache_invalidate();
  run("core.redraw = true", "=render_reset", 0);
}
void editor_ui_font(int px) {
  if (!EL) return;
  char lua[200];
  if (px > 0) SDL_snprintf(lua, sizeof lua, "host_ui_font = renderer.font.load(DATADIR .. '/data/fonts/font.ttf', %d * SCALE)", px);
  else SDL_snprintf(lua, sizeof lua, "host_ui_font = false");
  run(lua, "=ui_font", 0);
}
bool editor_ui_color(const char *key, SDL_Color *out) {
  if (!EL) return false;
  bool ok = false;
  lua_getglobal(EL, "package");
  lua_getfield(EL, -1, "loaded");
  lua_getfield(EL, -1, "core.style");
  int n = 3;
  if (lua_istable(EL, -1) && !strncmp(key, "syntax.", 7)) { lua_getfield(EL, -1, "syntax"); n++; key += 7; }
  if (lua_istable(EL, -1)) {
    lua_getfield(EL, -1, key);
    n++;
    if (lua_istable(EL, -1)) {
      int v[4] = { 0, 0, 0, 255 };
      for (int i = 0; i < 4; i++) {
        lua_rawgeti(EL, -1, i + 1);
        if (lua_isnumber(EL, -1)) v[i] = (int)lua_tonumber(EL, -1);
        lua_pop(EL, 1);
      }
      *out = (SDL_Color){ (Uint8)SDL_clamp(v[0], 0, 255), (Uint8)SDL_clamp(v[1], 0, 255),
                          (Uint8)SDL_clamp(v[2], 0, 255), (Uint8)SDL_clamp(v[3], 0, 255) };
      ok = true;
    }
  }
  lua_pop(EL, n);
  return ok;
}
bool editor_running(void) { return EL != NULL; }

bool editor_exec(const char *lua) {
  if (!EL) return false;
  if (run(lua, "=lite_exec", 0)) return true;
  fprintf(stderr, "%s\n", editor_err);
  return false;
}
// the plugins that open a tab of their own: "name\ttitle\n"... (data/plugins/projectplugins.lua)
bool editor_plugin_tabs(char *out, size_t n) {
  if (n) out[0] = 0;
  if (!EL) return false;
  lua_getglobal(EL, "lite_plugin_tabs");
  bool ok = lua_pcall(EL, 0, 1, 0) == 0 && lua_isstring(EL, -1);
  if (ok) SDL_strlcpy(out, lua_tostring(EL, -1), n);
  lua_pop(EL, 1);
  return ok;
}
// a plugin's menu (the main menu's Plugins > <plugin> >): "i|-\ttext\tinfo\n"...
bool editor_plugin_menu(const char *name, char *out, size_t n) {
  if (n) out[0] = 0;
  if (!EL) return false;
  lua_getglobal(EL, "lite_plugin_menu");
  lua_pushstring(EL, name);
  bool ok = lua_pcall(EL, 1, 1, 0) == 0 && lua_isstring(EL, -1);
  if (ok) SDL_strlcpy(out, lua_tostring(EL, -1), n);
  lua_pop(EL, 1);
  return ok;
}
bool editor_wants_keys(void) {
  if (!EL) return false;
  lua_getglobal(EL, "lite_wants_keys");
  bool on = false;
  if (lua_pcall(EL, 0, 1, 0) == 0) on = lua_toboolean(EL, -1);
  lua_pop(EL, 1);
  return on;
}
bool editor_wants_quit(void) { return lt_sdl3_wants_quit != 0; }
// the editor's files with unsaved changes: fn(absolute path, text, length, ud) each; -> how many
int editor_unsaved(void (*fn)(const char *path, const char *text, size_t n, void *ud), void *ud) {
  if (!EL) return 0;
  static const char *Q =
    "local core = require 'core'\n"
    "local t = {}\n"
    "for _, d in ipairs(core.docs) do\n"
    "  if d.filename and d:is_dirty() then\n"
    "    t[#t + 1] = system.absolute_path(d.filename) or d.filename\n"
    "    t[#t + 1] = d:get_text(1, 1, math.huge, math.huge)\n"
    "  end\n"
    "end\n"
    "return t\n";
  int top = lua_gettop(EL), n = 0;
  if (luaL_loadbuffer(EL, Q, strlen(Q), "=unsaved") == 0 && lua_pcall(EL, 0, 1, 0) == 0 && lua_istable(EL, -1)) {
    for (int i = 1; ; i += 2) {
      lua_rawgeti(EL, -1, i); lua_rawgeti(EL, -2, i + 1);
      if (!lua_isstring(EL, -2)) { lua_pop(EL, 2); break; }
      size_t len = 0;
      const char *text = lua_tolstring(EL, -1, &len);
      fn(lua_tostring(EL, -2), text, len, ud);
      n++;
      lua_pop(EL, 2);
    }
  }
  lua_settop(EL, top);
  return n;
}
void editor_prof(double *raster_ms, int *redraws, double *upload_ms, int *rects) {   // (--prof) since the last call
  *raster_ms = lite_raster_ns / 1e6; *redraws = (int)lite_raster_n;
  *upload_ms = lite_upload_ns / 1e6; *rects = (int)lite_upload_rects;
  lite_raster_ns = lite_raster_n = lite_upload_ns = lite_upload_rects = 0;
}
const char *editor_error(void) { return editor_err; }

void editor_shutdown(void) {
  ui_tex_clear();
  ui_font = NULL;
  if (EL) lua_close(EL);
  EL = NULL;
  if (lt_sdl3_surface.t) SDL_DestroyTexture(lt_sdl3_surface.t);
  free(lt_sdl3_surface.pixels);
  memset(&lt_sdl3_surface, 0, sizeof lt_sdl3_surface);
}
