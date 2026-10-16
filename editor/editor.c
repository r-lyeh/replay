// editor/editor.c - the lite text editor (r-lyeh/lite fork), embedded with SDL3.
//
// lite lives in this separate translation unit because lite.h, stb_truetype
// and the Lua implementation all define plenty of global names. It runs in
// its OWN Lua state, fully separate from the game world's VM.
//
// Build: compile alongside replay.c, e.g.  cl editor/editor.c replay.c -I editor/3rd ...

#define _DEFAULT_SOURCE                    // realpath() on POSIX
#ifdef _WIN32
#include <winsock2.h>                      // (before lite's <windows.h>: editor/udp.h, the world's UDP sockets)
#include <ws2tcpip.h>
#include <iphlpapi.h>                     // (MIB_IPFORWARDROW: udp.gateway; the DLL is loaded when asked)
#endif
#include <minilua/minilua.h>          // Lua 5.4 API (implementation is in replay.c)

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

// images for the game too (replay.c: the `image` component): RGBA, 4 bytes a pixel
unsigned char *editor_image_decode(const void *data, int size, int *w, int *h) {
  int n = 0;
  return stbi_load_from_memory((const stbi_uc *)data, size, w, h, &n, 4);
}
void editor_image_free(unsigned char *pixels) { stbi_image_free(pixels); }

static lua_State *EL;
static float ed_scale = 1;                         // retina: lite's pixels per point (editor_set_scale)
static SDL_Rect vp;                                // editor area in window pixels (w=0: whole window)
static int win_w, win_h;                           // the whole window (host points): lite's surface covers it all,
                                                   // its views laid out in vp, its popups anywhere (overlays)
#define OVERLAYS_MAX 16
static SDL_FRect overlays[OVERLAYS_MAX];           // where lite drew popups last frame (host points): replay.c shows them over everything
static int noverlays;
static const char *(*host_call_fn)(const char *cmd);   // lite's host_call(cmd): menus asking replay.c (settings, the bar's menus)
static int l_pane(lua_State *L);
static int l_side(lua_State *L);
static int l_set_overlays(lua_State *L);
static int l_host_call(lua_State *L);
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
// host_open_dialog(dir) -> true: the system's file dialog is showing (its
// answer comes later, in editor_frame: the file opens, as Ctrl+O's); false:
// none here (lite's own prompt is used). SDL may answer from another thread.
static SDL_Window *dialog_win;
static SDL_AtomicInt dialog_state;                   // 0 idle, 1 open, 2 a file, 3 cancelled, 4 failed
static char dialog_file[1024];
static void SDLCALL dialog_done(void *ud, const char *const *files, int filter) {
  (void)ud; (void)filter;
  if (!files) { SDL_SetAtomicInt(&dialog_state, 4); return; }
  if (!files[0]) { SDL_SetAtomicInt(&dialog_state, 3); return; }
  SDL_strlcpy(dialog_file, files[0], sizeof dialog_file);
  SDL_SetAtomicInt(&dialog_state, 2);
}
static int l_open_dialog(lua_State *L) {
  const char *dir = luaL_optstring(L, 1, NULL);
  if (SDL_GetHintBoolean("REPLAY_NO_FILE_DIALOG", false) || SDL_GetAtomicInt(&dialog_state) == 1) {
    lua_pushboolean(L, SDL_GetAtomicInt(&dialog_state) == 1);   // (one at a time)
    return 1;
  }
  SDL_SetAtomicInt(&dialog_state, 1);
  SDL_ShowOpenFileDialog(dialog_done, NULL, dialog_win, NULL, 0, dir, false);
  lua_pushboolean(L, SDL_GetAtomicInt(&dialog_state) != 4);   // (failed at once: none on this system)
  if (SDL_GetAtomicInt(&dialog_state) == 4) SDL_SetAtomicInt(&dialog_state, 0);
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
  if (win_w > 0 && win_h > 0) { w = (int)SDL_ceilf(win_w * ed_scale); h = (int)SDL_ceilf(win_h * ed_scale); }
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
  lua_pushnumber(EL, ed_scale);                      // (retina: the display's density, e.g. 2: lite draws at its pixels)
  lua_setglobal(EL, "SCALE");
  lua_pushstring(EL, datadir);
  lua_setglobal(EL, "DATADIR");
  lua_pushstring(EL, "lite");
  lua_setglobal(EL, "EXEFILE");
  lua_pushcfunction(EL, l_quit);
  lua_setglobal(EL, "lite_quit");
  lua_pushcfunction(EL, l_pane);
  lua_setglobal(EL, "host_pane");
  lua_pushcfunction(EL, l_side);
  lua_setglobal(EL, "host_side");
  lua_pushcfunction(EL, l_set_overlays);
  lua_setglobal(EL, "host_set_overlays");
  lua_pushcfunction(EL, l_host_call);
  lua_setglobal(EL, "host_call");
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
  dialog_win = win;
  lua_pushcfunction(EL, l_open_dialog);
  lua_setglobal(EL, "host_open_dialog");             // (data/replay.lua: Ctrl+O)
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

// retina (settings: retina): the window has the display's own pixels and the
// host draws in points at that scale; lite gets a surface of real pixels and
// SCALE = the scale, so its text is sharp. Its mouse positions: times it.
void editor_set_scale(float s) { ed_scale = s > 0 ? s : 1; lt_sdl3_scale = ed_scale; }
void editor_viewport(int x, int y, int w, int h, int ww, int wh) {
  if (w < 1) w = 1;
  if (h < 1) h = 1;
  if (ww < x + w) ww = x + w;
  if (wh < y + h) wh = y + h;
  bool moved = vp.x != x || vp.y != y || vp.w != w || vp.h != h;
  bool resized = win_w != ww || win_h != wh;
  vp.x = x; vp.y = y; vp.w = w; vp.h = h;
  win_w = ww; win_h = wh;
  lt_sdl3_offx = 0; lt_sdl3_offy = 0;              // (lite's coordinates: the window's; its views sit in vp)
  if (EL && resized) {                             // lite resizes its surface on this event
    SDL_Event r = { 0 };
    r.type = SDL_EVENT_WINDOW_PIXEL_SIZE_CHANGED;
    r.window.data1 = (int)SDL_ceilf(ww * ed_scale);
    r.window.data2 = (int)SDL_ceilf(wh * ed_scale);
    lt_sdl3_push_event(&r);
  }
  if (EL && moved) rencache_invalidate();          // (the pane moved: every part of the surface drawn again, none left where it was)
  if (EL && moved && !resized) {                   // (only the pane moved: lite lays out again)
    SDL_Event r = { 0 };
    r.type = SDL_EVENT_WINDOW_EXPOSED;
    lt_sdl3_push_event(&r);
  }
}
// host_pane() -> x, y, w, h: lite's views' area in its surface (pixels)
static SDL_FRect side_rect;                        // the left tab (host points): lite draws the tree and the properties there
void editor_side(float x, float y, float w, float h) {
  if (x != side_rect.x || y != side_rect.y || w != side_rect.w || h != side_rect.h) {
    side_rect = (SDL_FRect){ x, y, w, h };
    if (EL) run("core.redraw = true", "=side", 0);
  }
}
static int l_side(lua_State *L) {                  // host_side() -> x, y, w, h (surface px; w 0: none)
  lua_pushnumber(L, SDL_floorf(side_rect.x * ed_scale)); lua_pushnumber(L, SDL_floorf(side_rect.y * ed_scale));
  lua_pushnumber(L, SDL_floorf(side_rect.w * ed_scale)); lua_pushnumber(L, SDL_floorf(side_rect.h * ed_scale));
  return 4;
}
void editor_mods(SDL_Keymod m) {                   // lite's modifier keys as SDL has them (a click routed to it: CTRL+click)
  if (!EL) return;
  int top = lua_gettop(EL);
  lua_getglobal(EL, "package");
  lua_getfield(EL, -1, "loaded");
  lua_getfield(EL, -1, "core.keymap");
  if (lua_istable(EL, -1)) {
    lua_getfield(EL, -1, "modkeys");
    if (lua_istable(EL, -1)) {
      lua_pushboolean(EL, (m & SDL_KMOD_CTRL) != 0); lua_setfield(EL, -2, "ctrl");
      lua_pushboolean(EL, (m & SDL_KMOD_SHIFT) != 0); lua_setfield(EL, -2, "shift");
      lua_pushboolean(EL, (m & SDL_KMOD_LALT) != 0); lua_setfield(EL, -2, "alt");
    }
  }
  lua_settop(EL, top);
}
void editor_side_blur(void) { if (EL) run("if lite_side_blur then lite_side_blur() end", "=side_blur", 0); }
lua_State *editor_lua(void) { return EL; }

// the bar's Lua prompt, typed in lite (plugins/textproxy.lua: lite_prompt):
// cmd "focus" (s: its text), "set" (s), "place" (a, b: line 1's text, c: its
// height; host points), "mouse" (s: pressed / moved / released, a, b: host
// points, c: clicks), "blur"
bool editor_prompt(const char *cmd, const char *s, float a, float b, float c) {
  if (!EL) return false;
  int top = lua_gettop(EL);
  lua_getglobal(EL, "lite_prompt");
  if (!lua_isfunction(EL, -1)) { lua_settop(EL, top); return false; }
  lua_pushstring(EL, cmd);
  int n = 1;
  if (!strcmp(cmd, "focus")) { lua_pushstring(EL, s ? s : ""); n++; }
  else if (!strcmp(cmd, "set")) { lua_pushstring(EL, s ? s : ""); lua_pushnumber(EL, a); n += 2; }   // (a >= 0: the caret there, a byte offset; else at the end)
  else if (!strcmp(cmd, "place")) { lua_pushnumber(EL, a * ed_scale); lua_pushnumber(EL, b * ed_scale); lua_pushnumber(EL, c * ed_scale); n += 3; }
  else if (!strcmp(cmd, "mouse")) { lua_pushstring(EL, s); lua_pushnumber(EL, a * ed_scale); lua_pushnumber(EL, b * ed_scale); lua_pushnumber(EL, c); n += 4; }
  bool ok = lua_pcall(EL, n, 1, 0) == 0 && lua_toboolean(EL, -1);
  lua_settop(EL, top);
  return ok;
}
// what the prompt holds -> false: not typing in lite. cur, s1, s2: byte
// offsets (0-based) of the caret and the selection; caret: shown (blink)
bool editor_prompt_get(char *buf, size_t n, int *cur, int *s1, int *s2, bool *caret) {
  if (!EL) return false;
  int top = lua_gettop(EL);
  lua_getglobal(EL, "lite_prompt");
  if (!lua_isfunction(EL, -1)) { lua_settop(EL, top); return false; }
  lua_pushstring(EL, "get");
  bool ok = lua_pcall(EL, 1, 5, 0) == 0 && lua_isstring(EL, -5);
  if (ok) {
    SDL_strlcpy(buf, lua_tostring(EL, -5), n);
    *cur = (int)lua_tointeger(EL, -4) - 1; *s1 = (int)lua_tointeger(EL, -3) - 1; *s2 = (int)lua_tointeger(EL, -2) - 1;
    *caret = lua_toboolean(EL, -1);
  }
  lua_settop(EL, top);
  return ok;
}
static bool pane_shown = true;                     // the host shows lite's views (editing); else the game covers the pane
void editor_pane_shown(bool on) {                  // (off: lite draws only its popups, so nothing of a view shows round them)
  if (on == pane_shown) return;
  pane_shown = on;
  if (EL) run("core.redraw = true", "=pane_shown", 0);
}
static int l_pane(lua_State *L) {
  lua_pushnumber(L, SDL_floorf(vp.x * ed_scale)); lua_pushnumber(L, SDL_floorf(vp.y * ed_scale));
  lua_pushnumber(L, SDL_ceilf(vp.w * ed_scale)); lua_pushnumber(L, SDL_ceilf(vp.h * ed_scale));
  lua_pushboolean(L, pane_shown);
  return 5;
}
// host_set_overlays({ x, y, w, h, x, y, w, h... }): where popups are (surface pixels)
static bool overlays_modal;                        // one of them is a menu (it has the mouse and keys), not just a tooltip
static int l_set_overlays(lua_State *L) {
  noverlays = 0;
  overlays_modal = lua_isnone(L, 2) ? true : lua_toboolean(L, 2);
  if (lua_istable(L, 1)) {
    int n = (int)lua_rawlen(L, 1) / 4;
    for (int i = 0; i < n && noverlays < OVERLAYS_MAX; i++) {
      float v[4];
      for (int k = 0; k < 4; k++) { lua_rawgeti(L, 1, i * 4 + k + 1); v[k] = (float)lua_tonumber(L, -1); lua_pop(L, 1); }
      overlays[noverlays++] = (SDL_FRect){ v[0] / ed_scale, v[1] / ed_scale, v[2] / ed_scale, v[3] / ed_scale };
    }
  }
  return 0;
}
bool editor_menu_modal(void) { return EL && noverlays > 0 && overlays_modal; }   // a menu is open (not just a tooltip)
int editor_overlays(SDL_FRect *out, int max) {     // -> how many popups lite shows (host points), each one's rect
  if (!EL) return 0;
  for (int i = 0; i < noverlays && i < max; i++) out[i] = overlays[i];
  return noverlays;
}
bool editor_overlay_at(float x, float y) {         // over a popup of lite's
  for (int i = 0; i < noverlays; i++)
    if (x >= overlays[i].x && x < overlays[i].x + overlays[i].w && y >= overlays[i].y && y < overlays[i].y + overlays[i].h) return true;
  return false;
}
void editor_set_host_call(const char *(*fn)(const char *cmd)) { host_call_fn = fn; }
// a host menu (plugins/hostmenu.lua): text as it says (depth \t kind \t text \t info \t flags)
bool editor_menu(const char *id, float x, float y, float above, const char *text, bool search) {
  if (!EL) return false;
  lua_getglobal(EL, "lite_host_menu");
  if (!lua_isfunction(EL, -1)) { lua_pop(EL, 1); return false; }
  lua_pushstring(EL, id);
  lua_pushnumber(EL, x);
  lua_pushnumber(EL, y);
  lua_pushstring(EL, text);
  lua_pushboolean(EL, search);
  lua_pushnumber(EL, above);
  bool ok = lua_pcall(EL, 6, 1, 0) == 0 && lua_toboolean(EL, -1);
  lua_pop(EL, 1);
  if (lt_sdl3_win) SDL_StartTextInput(lt_sdl3_win);  // (typing filters it)
  return ok;
}
void editor_menu_close(void) {
  if (!EL) return;
  lua_getglobal(EL, "lite_host_menu_close");
  if (lua_isfunction(EL, -1)) { if (lua_pcall(EL, 0, 0, 0) != 0) lua_pop(EL, 1); } else lua_pop(EL, 1);
}
static int l_host_call(lua_State *L) {             // host_call(cmd) -> a string (replay.c answers) | nil
  const char *r = host_call_fn ? host_call_fn(luaL_checkstring(L, 1)) : NULL;
  if (r) lua_pushstring(L, r); else lua_pushnil(L);
  return 1;
}

void editor_event(const SDL_Event *e) {
  if (!EL) return;
  // right button: replay.c keeps it while the game is visible (picking) and
  // passes it on in the editor-only view (lite's context menu)
  SDL_Event c = *e;
  switch (c.type) {
  case SDL_EVENT_WINDOW_RESIZED:                   // the host sizes us via editor_viewport()
  case SDL_EVENT_WINDOW_PIXEL_SIZE_CHANGED:
    return;
  case SDL_EVENT_MOUSE_MOTION:                     // (window coordinates: lite's surface is the whole window)
    if (c.motion.x > -10000) { c.motion.x *= ed_scale; c.motion.y *= ed_scale; }
    c.motion.xrel *= ed_scale; c.motion.yrel *= ed_scale;
    break;
  case SDL_EVENT_MOUSE_BUTTON_DOWN:
  case SDL_EVENT_MOUSE_BUTTON_UP:
    c.button.x *= ed_scale; c.button.y *= ed_scale;
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
  int ds = SDL_GetAtomicInt(&dialog_state);          // the file dialog answered
  if (ds >= 2 && ok) {
    SDL_SetAtomicInt(&dialog_state, 0);
    if (ds == 2) editor_open(dialog_file, 0);
    else if (ds == 4) editor_exec("replay_open_prompt()");   // (failed: lite's own prompt)
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
  return f ? (int)SDL_ceilf(f->height / ed_scale) : 0;   // (retina: its glyphs are at SCALE: points here)
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
  float k = 1 / ed_scale;                          // (retina: glyphs baked at SCALE, drawn at points: sharp)
  x = SDL_floorf(x * ed_scale) * k; y = SDL_floorf(y * ed_scale) * k;
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
        SDL_FRect dst = { x + g->xoff * k, y + g->yoff * k, src.w * k, src.h * k };
        SDL_RenderTexture(r, t, &src, &dst);
      }
    }
    x += g->xadvance * k;
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
    if (s->t) SDL_SetTextureBlendMode(s->t, SDL_BLENDMODE_BLEND_PREMULTIPLIED);   // (as lite_sys_sdl3.h makes it)
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
