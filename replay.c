// replay.c - a very silly SDL3 viewer for the Lua tree world.
//
// It embeds Lua (LuaJIT or Lua 5.1-5.4), loads a world and draws whatever
// it can recognise. It knows nothing about the game: it only understands a
// handful of *render components* by convention. Everything else is shown
// by name in the tree panel.
//
//   xform  = { x=0, y=0, r=0, s=1 }   local transform (r in radians,
//                                     sx/sy override s), relative to parent
//   pos    = { x=, y= }               fallback transform when no xform
//   color  = { r, g, b, a }           0..255, also inherited by children
//   lines  = { x1,y1, x2,y2, ..., loop=true }         polyline
//   tris   = { x1,y1, x2,y2, x3,y3, ... }             filled triangles
//   rect   = { w=, h=, fill=true }                    centered
//   circle = { r=, fill=true, n=24 }
//   text   = "hello"  or  { "hello" }
//   sprite = { "..##..", ".#..#.", palette = { ["#"] = {r,g,b,a} }, px = 2 }
//   image  = "/assets/ship.png"  or  { "/assets/ship.png", w=, h=, color=, smooth=false,
//                                       src = { x, y, w, h } (a part of it) }
//            or { "/assets/ui.atlas.lua", frame = "ship" }  (a frame of an atlas: plugins/atlaspacker)
//                                     a picture from the game's assets/ folder,
//                                     centred, w x h (default: its pixels)
//   tilemap = { "/assets/level.tmap", layer = "ground" | n, size=, color= }
//                                     a tile map (plugins/tilemap) from its top
//                                     left at the node: a layer (or all), live
//                                     (reloaded when its file changes)
//   ref    = "/assets/ship"           draw that node (and its subtree) here
//   bounds = { w=, h= }  or { x=, y=, w=, h= }  or { r= }  (+ aabb = true)
//                                     picking shape in node space: an
//                                     oriented box (rotates with xform), a
//                                     screen-aligned box (aabb) or a circle.
//                                     Picked before anything else.
//   hidden = true                     skip this subtree (assets live here)
//   screen = { w=, h= }               (the root's; /config's window = { w=, h=,
//                                     title= } first) the game area's size when
//                                     the window opens (--game WxH wins)
//
// Usage:  edit [games/pong.lua | snapshot.lua | folder | asset] [--shot out.bmp] [--frames N]
//   No file: the project launcher (games/*, editor/picker.h). A renamed copy
//   (pong.exe) opens <exe name>/, <exe name>.lua or .hurdy next to it or in
//   games/ instead (with pong.png as its icon). Test hooks: --pick "m x,y@f
//   l x,y@f", --pick-shot f.bmp
//   A .lua / .hurdy file or a folder: a game, it runs. Any other file: an
//   asset, opened by the plugin whose files.lua lists its extension (the
//   game it's in loads, stopped; else no world); none: exit code -1.
//   No .c files next to the exe (a shipped package): runs --standalone
//   unless --editor is given. The window title is the world's name.
//   e.g.  play games\scene1.lua   (a script that builds the world)
//         play games\scene2\     (the same demo as a folder of data files)
//         play games\pong.lua     (pong in one file; games\pong\ is the folder version)
//         play games\snake\      (systems in hurdy: s/*/system.hurdy)
//         play games\asteroids\  (2 players, textures from its assets/)
//   Modules (ecs, disk, fs, net) are found in runtime/.
//   A .lua file that returns a world is run as a script (its systems tick);
//   so is a .hurdy file (compiled to Lua first: games\snake.hurdy).
//   A save() blob ("return { version = 1, ...") is loaded as a snapshot.
//   A folder is a world on disk (see disk.lua: node = folder, component =
//   <name>.lua); edits to its files show up live.
//   Files are reloaded automatically when they change on disk.
//
// The viewer also registers `hostfs` (list/isdir/mkdir/remove, via SDL3)
// so fs.lua doesn't need to shell out.
//
// The lite text editor (editor/editor.c) runs behind the game area. Two views for now:
// running (playing or paused) shows the game, stopped shows the editor (see
// view_rules). A short ESC while running stops (back to the editor); in the
// editor ESC does nothing. A long ESC (>= 0.5 s) goes to the game as a
// regular ESC (w.on_key(w, "escape", down)). ESC never quits (use the
// window's close button or lite's Ctrl+Q) and never reaches lite.
// The 2nd toolbar button picks the view: the game's opacity over the editor,
// 0% = the editor only, 100% = the game only, between = mixed (the editor
// with the game over it). Each state keeps its own (playing 100%, paused
// 75%, stopped 0% to begin with): a click cycles 0% (editor) -> 75% (mixed)
// -> 100% (game), the wheel up / down 5%. Mixed while playing: the mouse is the editor's, the keys the game's,
// unless the last click went to something you type in (code, a field in a
// graph); Ctrl+keys always go to the editor.
// Inspect: left-click a node in the tree panel, or right-click anything in
// the game (any mode): right-click = the instance under the mouse,
// Alt+right-click = the class/asset part it is drawn from. Its source opens
// in the editor (folder world: the node's
// component files; script/snapshot: the line that creates it). Saving
// reloads the world.
// Layout: tree tab on the left (216 px), game area to its right (640x480),
// status bar below both (full width, 28 px): the window client is
// 840x508. Resizing grows the game area. The game area never sees the bar.
// Status bar: play/pause, rewind to 0 s, speed x1..x4 (wheel: x0.01..x4.00), and a timeline of
// snapshots taken every 0.5 s of game time. Click/drag the timeline to seek
// (pauses; states between snapshots are blended); play resumes from there.
// Console (right part of the bar): click it, type Lua, Enter runs it on
// the live world: `w` = world, `sel` = selected node,
// ls('/scene') lists children, print() output shows in the field. Up/Down =
// history, Ctrl+V/C/U/L = paste/copy/clear line/clear output, ESC leaves.
// Overlay (dev UI only, see overlay.h): debugdraw from Lua (dd.line, dd.arrow,
// dd.rect, dd.circle, dd.text...), stats top-right, warnings/errors top-left
// (fading), pressed keys/buttons/gamepad + frame number bottom-right.
// While playing, every key also goes to the world: w.on_key(w, name, down)
// with SDL key names in lowercase ("f1", "`", "a", "left", "escape"...).
// Play / Stop work like a play-in-editor: the viewer starts stopped, showing
// the authored world; edits then (property panel, console) can be saved to
// disk with the save button (world folders and save() blobs; not scripts).
// Play runs a session from that world; edits while playing are live only,
// Stop drops them and restores the authored world (keeping file changes,
// e.g. a system edited meanwhile).
// The viewer has no keyboard shortcuts besides ESC and F1 (help: docs/HELP.md
// in the markdown viewer; the game never gets F1): everything else is a
// mouse action (bar buttons: play/pause, stop, rewind, speed | save, export |
// gizmos, picking debug, reset camera, game fade; drag = pan, wheel = zoom).
// Options: --game 640x480, --tab 216 (else tab_width in .preferences.lua:
//          drag the tab's right edge), --fps N (0 = unlimited; default =
//          the monitor's refresh rate), --no-editor, --shot out.bmp --frames N,
//          --events "r640,400@10 l20,40@30" (scripted clicks for tests),
//          --stopped (start stopped instead of playing),
//          --log / --no-log (lite's Log tab at start; beats log_window in
//          .preferences.lua next to the exe; default: hidden),
//          --standalone (just the game: no tab, timeline, editor, overlay,
//          gizmos or dev keys; every key goes to the game, ESC included),
//          --headless [--ticks N] (no window: the world played N ticks of
//          1/60 s, default 600; --key "space@30" / "w@10-90" (held), --type
//          "assert(...)@600" (Lua on the world at that tick); prints a summary;
//          exit code 0 ok, 1 an error: for scripts and CI),
//          --host [port] / --join addr[:port] (play online: host the game,
//          default port 7777, or join one; runtime/players.lua; with
//          --headless too, then at the real pace),
//          --type "lua code@frame" (console line, for tests; repeatable; a
//          drop-down open: it filters it, no Enter),
//          --key "F1@frame" (key press, for tests; repeatable; "ctrl+z@30"),
//          --lite "lua@frame" (run Lua inside lite, for tests; repeatable),
//          --export-dir DIR (Export goes there: no dialog, no message box;
//          for tests: see editor/export.h)
// Starts playing, in the game view (--stopped: stopped, in the mixed view).
// The timeline doubles as an fps "equalizer": a thin line at the target fps
// (the --fps limit or monitor Hz) that thickens where fps dropped. Hover it
// for time + fps; click/drag to jump.
//
// Build (Windows): make.bat  ->  cl editor/editor.c replay.c -I editor/3rd -I . SDL3.lib
// Build (Linux/macOS/MinGW): make  ->  cc replay.c editor/editor.c -I editor/3rd -I . -o play -lSDL3 -lm (see Makefile)

#include <SDL3/SDL.h>
#include <SDL3/SDL_main.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdarg.h>

#include "editor/editor.h"

#if 0
//#include "lua.h"
//#include "lauxlib.h"
//#include "lualib.h"
#else
#define LUA_IMPL
#include <minilua/minilua.h>

#if defined(_WIN32) && defined(_MSC_VER)
// A window program, not a console one: double-clicking play.exe (or a
// packaged game, its renamed copy) opens no terminal. Started from one
// (cmd, a .bat), main() attaches to it, so printf and errors still show there.
#pragma comment(linker, "/SUBSYSTEM:WINDOWS /ENTRY:mainCRTStartup")
__declspec(dllimport) int __stdcall AttachConsole(unsigned long pid);
#endif
#include "editor/overlay.h"                          // dev overlay + debugdraw (dd.*)
#endif

#if LUA_VERSION_NUM >= 502
#define objlen lua_rawlen
#else
#define objlen lua_objlen
#endif

#include "editor/boot.h"
#include "editor/types.h"
#include "editor/probe.h"                            // the editor's probe: lines run, values (node graph)
#include "editor/picking.h"
#include "editor/render.h"
#include "editor/players.h"                          // the Players button: peers over a simulated network
#include "editor/hostfs.h"
#include "editor/sound.h"                           // the game's sounds (host_sound: runtime/sound.lua)
#include "editor/world.h"
#include "editor/ui.h"
#include "editor/settings.h"                         // .preferences.lua (the main menu saves it)
#include "editor/tab.h"
#include "editor/bar.h"
#include "editor/menus.h"                            // the popup menus: lite draws them (main, Network, lobby, drop-downs, the tree's)
#include "editor/side.h"                             // the left tab: lite draws it (the tree, the properties), the viewer's data
// a folder world's root file: its shallowest .lua (alphabetical among equals),
// as a path relative to the folder; false if there is none. Dot entries skipped.
typedef struct { const char *base; char rel[1024]; int depth; char best[1024]; int best_depth; } RootFind;
static SDL_EnumerationResult root_find_cb(void *ud, const char *dir, const char *name) {
  RootFind *f = (RootFind *)ud;
  (void)dir;
  if (name[0] == '.') return SDL_ENUM_CONTINUE;
  char rel[1024], full[2048];
  SDL_snprintf(rel, sizeof rel, "%s%s%s", f->rel, f->rel[0] ? "/" : "", name);
  SDL_snprintf(full, sizeof full, "%s/%s", f->base, rel);
  SDL_PathInfo info;
  if (!SDL_GetPathInfo(full, &info)) return SDL_ENUM_CONTINUE;
  if (info.type == SDL_PATHTYPE_FILE) {
    size_t n = strlen(name);
    if (n > 4 && !SDL_strcasecmp(name + n - 4, ".lua") &&
        (f->depth < f->best_depth || (f->depth == f->best_depth && strcmp(rel, f->best) < 0))) {
      SDL_strlcpy(f->best, rel, sizeof f->best);
      f->best_depth = f->depth;
    }
  } else if (info.type == SDL_PATHTYPE_DIRECTORY && f->depth < 6 && f->depth + 1 <= f->best_depth) {
    char saved[1024];
    SDL_strlcpy(saved, f->rel, sizeof saved);
    SDL_strlcpy(f->rel, rel, sizeof f->rel);
    f->depth++;
    SDL_EnumerateDirectory(full, root_find_cb, f);
    f->depth--;
    SDL_strlcpy(f->rel, saved, sizeof f->rel);
  }
  return SDL_ENUM_CONTINUE;
}
static bool find_root_lua(const char *dir, char *out, size_t outsz) {
  RootFind f = { 0 };
  f.base = dir;
  f.best_depth = 1 << 30;
  SDL_EnumerateDirectory(dir, root_find_cb, &f);
  if (!f.best[0]) return false;
  SDL_strlcpy(out, f.best, outsz);
  return true;
}

static char g_icon_path[1024];                     // <exe name>.png next to the exe: every window's icon
static void apply_window_icon(SDL_Window *w) {
  SDL_Surface *ic = g_icon_path[0] && SDL_GetPathInfo(g_icon_path, NULL) ? SDL_LoadPNG(g_icon_path) : NULL;
  if (ic) { SDL_SetWindowIcon(w, ic); SDL_DestroySurface(ic); }
}
#include "editor/picker.h"                           // which project to open, at launch

// ---------------------------------------------------------------------------

// "scene1.lua" -> "C:\prj\replay\scene1.lua". lite chdir()s into its project,
// so everything the game loads later must not depend on the cwd.
static char *absolute(const char *p) {
  char *out = NULL;
  if (p[0] == '/' || p[0] == '\\' || (p[0] && p[1] == ':')) out = SDL_strdup(p);
  else {
    char *cwd = SDL_GetCurrentDirectory();         // ends with a separator
    SDL_asprintf(&out, "%s%s", cwd ? cwd : "", p);
    SDL_free(cwd);
  }
  // "scene2\" -> "...scene2": folder worlds get paths joined to them
  size_t n = out ? strlen(out) : 0;
  while (n > 1 && (out[n - 1] == '/' || out[n - 1] == '\\') && out[n - 2] != ':') out[--n] = 0;
  return out;
}

static bool exists(const char *path) { return SDL_GetPathInfo(path, NULL); }
static char *last_sep(const char *p) {            // the last / or \\ (NULL: none)
  char *a = SDL_strrchr(p, '/'), *b = SDL_strrchr(p, '\\');
  return a > b ? a : b;
}
static bool cut_last(char *p) { char *e = last_sep(p); if (!e) return false; *e = 0; return true; }   // a/b/c -> a/b
static const char *last_part(const char *p) { const char *e = last_sep(p); return e ? e + 1 : p; }  // a/b/c -> c

// the project's plugins/: next to the exe (like games/), else in the cwd
// Help (F1, the main menu's Help): docs/HELP.md next to the exe (else
// here), opened in the editor: its markdown viewer (plugins/markdown)
static char g_help[1100];
static void help_find(const char *base, const char *cwd) {
  SDL_snprintf(g_help, sizeof g_help, "%sdocs/HELP.md", base ? base : "");
  SDL_PathInfo pi;
  if (!SDL_GetPathInfo(g_help, &pi)) SDL_snprintf(g_help, sizeof g_help, "%sdocs/HELP.md", cwd ? cwd : "./");
}
static void plugins_dir(const char *base, const char *cwd, char *out, size_t size) {
  SDL_snprintf(out, size, "%splugins", base ? base : "");
  SDL_PathInfo pi;
  if (!SDL_GetPathInfo(out, &pi) || pi.type != SDL_PATHTYPE_DIRECTORY) SDL_snprintf(out, size, "%splugins", cwd ? cwd : "./");
}

// the plugin that opens this file: one whose files.lua (plain data, read in
// an empty sandbox) lists its extension -> its name in out; false: none
static bool asset_plugin(const char *pd, const char *file, char *out, size_t size) {
  const char *dot = SDL_strrchr(last_part(file), '.');
  if (!dot || !dot[1]) return false;
  bool found = false;
  int n = 0;
  char **names = SDL_GlobDirectory(pd, "*", 0, &n);
  lua_State *L = luaL_newstate();
  for (int i = 0; names && i < n && !found; i++) {
    char f[1400], ed[1400];
    SDL_snprintf(f, sizeof f, "%s/%s/files.lua", pd, names[i]);
    SDL_snprintf(ed, sizeof ed, "%s/%s/editor.lua", pd, names[i]);
    if (!exists(ed) || luaL_loadfilex(L, f, "t") != LUA_OK) { lua_settop(L, 0); continue; }
    lua_newtable(L);                               // (its _ENV: empty)
    lua_setupvalue(L, -2, 1);
    if (lua_pcall(L, 0, 1, 0) == LUA_OK && lua_istable(L, -1)) {
      for (lua_Integer k = 1; !found; k++) {
        lua_rawgeti(L, -1, k);
        const char *e = lua_tostring(L, -1);
        if (!e) { lua_pop(L, 1); break; }
        if (*e == '.') e++;
        size_t fl = SDL_strlen(file), el = SDL_strlen(e);   // (its name ends in .<e>: "ui.atlas.lua" is atlas.lua's)
        if (*e && el < fl && file[fl - el - 1] == '.' && !SDL_strcasecmp(file + fl - el, e)) { found = true; SDL_strlcpy(out, names[i], size); }
        lua_pop(L, 1);
      }
    }
    lua_settop(L, 0);
  }
  lua_close(L);
  SDL_free(names);
  return found;
}
static int l_abspath(lua_State *L) {               // viewer_abspath(p): absolute (relative: to the cwd)
  char *a = absolute(luaL_checkstring(L, 1));
  lua_pushstring(L, a ? a : lua_tostring(L, 1));
  SDL_free(a);
  return 1;
}

// Alt+click on play: this same exe, on this world, --standalone, in its own
// process. Our window waits minimized (paused) and comes back when it exits.
static SDL_Process *launched;
static bool launch_was_paused;
static bool ws_has_tabs(const char *ws, const char *ws_old) {   // a saved lite workspace with a tab in it
  const char *p = exists(ws) ? ws : exists(ws_old) ? ws_old : NULL;
  if (!p) return false;
  size_t n = 0;
  char *t = (char *)SDL_LoadFile(p, &n);
  bool tabs = t && (strstr(t, "\"filename\"") || strstr(t, "\"module\""));
  SDL_free(t);
  return tabs;
}
static char launch_exe[1024];                      // absolute: lite chdir()s, so argv[0] may not resolve
static char launch_cwd[1024];                      // the cwd we started in (lite changes ours)
#ifndef SDL_PROP_PROCESS_CREATE_WORKING_DIRECTORY_STRING
#define SDL_PROP_PROCESS_CREATE_WORKING_DIRECTORY_STRING "SDL.process.create.working_directory"
#endif

static void launch_standalone(Viewer *V, SDL_Window *win) {
  if (launched) return;
  const char *args[] = { launch_exe, V->path, "--standalone", NULL };
  SDL_PropertiesID pr = SDL_CreateProperties();    // inherits our console
  SDL_SetPointerProperty(pr, SDL_PROP_PROCESS_CREATE_ARGS_POINTER, (void *)args);
  if (launch_cwd[0]) SDL_SetStringProperty(pr, SDL_PROP_PROCESS_CREATE_WORKING_DIRECTORY_STRING, launch_cwd);
  launched = SDL_CreateProcessWithProperties(pr);
  SDL_DestroyProperties(pr);
  if (!launched) { SDL_snprintf(V->err, sizeof V->err, "launch failed: %s", SDL_GetError()); return; }
  V->launched = true;
  launch_was_paused = V->paused;
  V->paused = true;
  SDL_HideWindow(win);                             // out of the way: hidden, then minimized
  SDL_MinimizeWindow(win);
}

#include "editor/export.h"                           // Export: the game, ready to share (toolbar)

static void launch_poll(Viewer *V, SDL_Window *win) {
  int code = 0;
  if (!launched || !SDL_WaitProcess(launched, false, &code)) return;
  SDL_DestroyProcess(launched);
  launched = NULL;
  V->launched = false;
  V->paused = launch_was_paused;
  SDL_RestoreWindow(win);                          // back: restored, then shown
  SDL_ShowWindow(win);
  SDL_RaiseWindow(win);
  if (code) SDL_snprintf(V->info, sizeof V->info, "standalone game exited with code %d", code);
}

// Views: 0 game (editor hidden), 1 mixed (editor + the game over it at
// `fade`), 2 editor (no game). Which one follows the state (view_rules).

static void view_set(Viewer *V, bool *edfocus, int v) {
  if (v) V->edmode = v;
  if ((v != 0) != *edfocus) {
    *edfocus = v != 0;
    if (*edfocus) release_game_keys(V);           // (the keys are the editor's now: none left held in the game)
    editor_focus(*edfocus);
  }
}

// every frame: the view follows the opacity of the state (V->fades): 0 the
// editor, 1 the game, between: mixed (the editor with the game over it).
// Input: the game view (100%) gives the game everything; mixed and editor
// give the mouse and the keys to the editor. Gamepads always go to the game.
static void view_rules(Viewer *V, bool *edfocus, bool *was_stopped) {
  if (!editor_running()) return;
  V->fade = V->fades[V->stopped ? 2 : V->paused ? 1 : 0];
  int v = V->fade <= 0.001f ? 2 : V->fade >= 0.999f ? 0 : 1;
  *was_stopped = V->stopped;
  view_set(V, edfocus, v);
}
static float *fade_now(Viewer *V) { return &V->fades[V->stopped ? 2 : V->paused ? 1 : 0]; }
static void help_open(Viewer *V) {                 // F1 / Help: HELP.md in the editor (a plugin's tab: its own HELP.md if any; the game view: to the editor's, to read it)
  if (!editor_running() || V->standalone) return;
  SDL_PathInfo pi;
  if (!g_help[0] || !SDL_GetPathInfo(g_help, &pi)) { ov_log(OV_WARN, "help: no %s", g_help[0] ? g_help : "docs/HELP.md"); return; }
  float *f = fade_now(V);
  if (*f >= 0.999f) { *f = 0; V->fade = 0; }
  char code[1300];                                 // (in a plugin's tab: its own HELP.md, when it has one: lite_help, data/replay.lua)
  SDL_snprintf(code, sizeof code, "lite_help([==[%s]==])", g_help);
  editor_exec(code);
}

// --prof: where each frame's time goes, averaged over a second, in the
// window title (and on stderr): events, lite (its update + drawing, CPU),
// poll (folder worlds: the files re-read, twice a second), status (unsaved?
// the save button), the world's tick, drawing the game, blitting the
// layers, the overlay, the tab (tree, properties), the other panels (bar,
// menus), present, and wait (the frame limiter's sleep: idle time)
static bool g_prof;
enum { PF_EVENTS, PF_LITE, PF_POLL, PF_STATUS, PF_TICK, PF_GAME, PF_BLIT, PF_OVERLAY, PF_TAB, PF_PANELS, PF_PRESENT, PF_WAIT, PF_N };
static const char *PF_NAME[PF_N] = { "events", "lite", "poll", "status", "tick", "game", "blit", "overlay", "tab", "panels", "present", "wait" };
static double pf_sum[PF_N];
static Uint64 pf_t, pf_t0;
static int pf_frames;
static void pf_mark(int k) {                       // the time since the last mark goes to section k
  if (!g_prof) return;
  Uint64 t = SDL_GetTicksNS();
  pf_sum[k] += (t - pf_t) / 1e6;
  pf_t = t;
}
static void pf_frame(SDL_Window *win) {            // (after present) once a second: the averages
  if (!g_prof) return;
  pf_frames++;
  Uint64 t = SDL_GetTicksNS();
  if (!pf_t0) pf_t0 = t;
  if (t - pf_t0 >= 1000000000ull) {
    char s[400];
    double rms = 0, ums = 0; int rn = 0, nr = 0;
    if (editor_running()) editor_prof(&rms, &rn, &ums, &nr);
    int n = SDL_snprintf(s, sizeof s, "%d fps  ms/frame:", pf_frames);
    for (int k = 0; k < PF_N; k++) {
      n += SDL_snprintf(s + n, sizeof s - n, " %s %.1f", PF_NAME[k], pf_sum[k] / pf_frames);
      if (k == PF_LITE) n += SDL_snprintf(s + n, sizeof s - n, " (raster %.1f of which upload %.1f in %d rects, redrew %d/%d)",
                                          rms / pf_frames, ums / pf_frames, rn ? nr / rn : 0, rn, pf_frames);
      pf_sum[k] = 0;
    }
    SDL_SetWindowTitle(win, s);
    fprintf(stderr, "prof: %s\n", s);
    pf_frames = 0; pf_t0 = t;
  }
}

// Reset editor (the main menu): asked first; then .preferences.lua
// and lite's workspace of the project (.workspace.lua, .lite_workspace.lua)
// are deleted and the editor starts again, the same way (exe, arguments,
// folder). This process quits without writing them back: lite only saves its
// workspace when it quits itself, and the settings when the menu changes them.
// Unsaved changes in open files are lost (the question says so).
// what a tooltip under (x, y) is for: a bar / toolbar icon (its id), a
// main menu item (100 + i), the timeline (200), the console (201); -1:
// none of those. Moving within the same one keeps a tooltip shown
static int tip_zone(Viewer *V, int w, int h, float x, float y) {
  Bar b = bar_layout(w, h);
  int i = bar_button_at(&b, x, y);
  if (i >= 0) return i;
  if (y >= b.track.y - 3 && y < b.track.y + b.track.h + 3 && x >= b.track.x && x < b.track.x + b.track.w) return 200;
  if (in_rect(&b.con, x, y)) return 201;
  (void)V;
  return -1;
}

// quitting with the world's edits unsaved (the save icon yellow): with the
// menu's "Confirm close" on, an SDL dialog: Save / Don't save / Cancel.
// -> false: Cancel (keep running)
static bool quit_world_ok(Viewer *V, SDL_Window *win) {
  if (!settings_confirm_close() || !button_enabled(V, BTN_SAVE)) return true;
  const SDL_MessageBoxButtonData buttons[] = {
    { SDL_MESSAGEBOX_BUTTON_RETURNKEY_DEFAULT, 1, "Save" },
    { 0, 2, "Don't save" },
    { SDL_MESSAGEBOX_BUTTON_ESCAPEKEY_DEFAULT, 3, "Cancel" } };
  char msg[1200];
  SDL_snprintf(msg, sizeof msg, "The world has unsaved edits (%s).", V->script ? V->opath : V->path);
  const SDL_MessageBoxData box = { SDL_MESSAGEBOX_WARNING, win, "Unsaved changes", msg, 3, buttons, NULL };
  int which = 3;
  if (!SDL_ShowMessageBox(&box, &which)) return true;
  if (which == 1) { world_save(V); return !button_enabled(V, BTN_SAVE); }   // (the save failed: stay)
  return which == 2;
}

static char g_project_dir[1024];
static int g_argc; static char **g_argv;
static bool g_from_picker;                         // opened from the project launcher: quitting goes back to it

// start us again, in the folder we started in (it outlives us): with the same
// command line, or none (the project launcher)
static void relaunch(bool same_args) {
  const char *args[64];
  int n = 0;
  args[n++] = launch_exe;
  if (same_args) for (int i = 1; i < g_argc && n < 63; i++) args[n++] = g_argv[i];
  args[n] = NULL;
  SDL_PropertiesID pr = SDL_CreateProperties();
  SDL_SetPointerProperty(pr, SDL_PROP_PROCESS_CREATE_ARGS_POINTER, (void *)args);
  SDL_SetBooleanProperty(pr, SDL_PROP_PROCESS_CREATE_BACKGROUND_BOOLEAN, true);   // (outlives us)
  if (launch_cwd[0]) SDL_SetStringProperty(pr, SDL_PROP_PROCESS_CREATE_WORKING_DIRECTORY_STRING, launch_cwd);
  SDL_Process *np = SDL_CreateProcessWithProperties(pr);
  SDL_DestroyProperties(pr);
  if (np) SDL_DestroyProcess(np);                  // (forgets it; it keeps running)
}
static bool reset_defaults(SDL_Window *win) {
  const SDL_MessageBoxButtonData buttons[] = {
    { SDL_MESSAGEBOX_BUTTON_ESCAPEKEY_DEFAULT, 0, "Cancel" },
    { SDL_MESSAGEBOX_BUTTON_RETURNKEY_DEFAULT, 1, "Reset" } };
  const SDL_MessageBoxData box = { SDL_MESSAGEBOX_WARNING, win, "Reset editor",
    "Unsaved changes in open files will be lost.\n"
    "Editor preferences and workspace will be restored.\n"
    "\nContinue?", 2, buttons, NULL };
  int which = 0;
  if (!SDL_ShowMessageBox(&box, &which) || which != 1) return false;
  remove(g_settings_path);
  if (g_project_dir[0]) {
    char p[1200];
    SDL_snprintf(p, sizeof p, "%s/.workspace.lua", g_project_dir); remove(p);
    SDL_snprintf(p, sizeof p, "%s/.lite_workspace.lua", g_project_dir); remove(p);
  }
  relaunch(true);                                  // the same command line
  return true;                                     // quit now, saving nothing
}

// moving a node in the game view (stopped or paused, the game view): LMB
// drag on it moves it, Alt+drag turns it around its middle, the wheel while
// dragging scales it; one undo level per drag (boot.lua: viewer_move_*)
static struct { bool on, moved; char path[256]; float cx, cy; } nmove;
static bool move_call(Viewer *V, const char *fn, int nargs, double a, double b, double c, double d) {
  lua_State *L = V->L;
  int base = lua_gettop(L);
  lua_getglobal(L, fn);
  lua_rawgeti(L, LUA_REGISTRYINDEX, V->world);
  if (nargs == 1) lua_pushstring(L, nmove.path);
  if (nargs == 4) { lua_pushnumber(L, a); lua_pushnumber(L, b); lua_pushnumber(L, c); lua_pushnumber(L, d); }
  bool ok = false;
  if (lua_pcall(L, nargs + 1, 1, 0) != 0) ov_log(OV_ERROR, "move: %s", lua_tostring(L, -1));
  else ok = lua_toboolean(L, -1);
  lua_settop(L, base);
  return ok;
}
static bool move_start(Viewer *V, float gx, float gy, float ox, float oy) {   // (gx, gy: in the game area; ox, oy: its corner)
  if (!(V->stopped || V->paused) || V->standalone || V->world == LUA_NOREF) return false;
  const Pick *k = pick_at(gx, gy);
  if (!k) return false;
  SDL_strlcpy(nmove.path, k->via[0] ? k->via : k->path, sizeof nmove.path);
  if (!move_call(V, "viewer_move_begin", 1, 0, 0, 0, 0)) return false;
  nmove.on = true; nmove.moved = false;
  nmove.cx = ox + k->r.x + k->r.w / 2; nmove.cy = oy + k->r.y + k->r.h / 2;
  return true;
}
static void move_drag(Viewer *V, float x, float y, float dx, float dy, float z) {
  if ((SDL_GetModState() & SDL_KMOD_ALT) != 0) {   // turn: the angle the mouse went round its middle
    double a0 = atan2(y - dy - nmove.cy, x - dx - nmove.cx), a1 = atan2(y - nmove.cy, x - nmove.cx);
    double da = a1 - a0;
    if (da > SDL_PI_D) da -= 2 * SDL_PI_D; else if (da < -SDL_PI_D) da += 2 * SDL_PI_D;
    move_call(V, "viewer_move_by", 4, 0, 0, da, 1);
  } else {
    move_call(V, "viewer_move_by", 4, dx / z, dy / z, 0, 1);
    nmove.cx += dx; nmove.cy += dy;
  }
  nmove.moved = true;
}
static void move_finish(Viewer *V) {
  nmove.on = false;
  if (move_call(V, "viewer_move_end", 0, 0, 0, 0, 0)) {   // moved: it's the selection now
    SDL_strlcpy(V->selected, nmove.path, sizeof V->selected);
    V->via[0] = 0; nsel_more = 0; V->reveal = true;
    world_status(V);
  }
}

// --help, -h, -?: every flag (docs/CMDLINE.md: the same, in more words)
static const char *HELP_TEXT =
  "replay [FILE] [FLAGS]\n"
  "\nRunning:\n"
  "  (no file)                    the project launcher: the games in games/ (arrows / enter, a gamepad, a click)\n"
  "  FILE                         a game: a .lua / .hurdy script, a world folder or a snapshot; any other file: an asset, opened in its plugin\n"
  "  --stopped                    start stopped, on the authored world (in the editor)\n"
  "  --standalone                 just the game: no editor, no tree\n"
  "  --editor                     the editor even in a shipped package (no .c files beside the exe)\n"
  "  --no-editor                  the viewer without Lite (the tree and the game only)\n"
  "  --game WxH                   the game area's size when the window opens (else the game's config/window.lua)\n"
  "  --tab PX                     the left tab's width\n"
  "  --fps N                      the frame limit while focused (0: none); also --fps-target\n"
  "  --prof                       where each frame's time goes, in the window title (and on stderr)\n"
  "  --log                        write .log.txt beside the game (the default: the setting)\n"
  "  --no-log                     don't write .log.txt\n"
  "  -h, --help, -?               this list\n"
  "\nOnline:\n"
  "  --host [PORT]                host the game online (UDP; no port: the game's own, by its name)\n"
  "  --join ADDR[:PORT]           join the game that computer hosts (no port: the game's)\n"
  "  --join ROOM@INTRO[:PORT]     join through routers: the room an introducer knows\n"
  "  --via ROOM@INTRO[:PORT]      host through routers: known to that introducer as ROOM\n"
  "  --introducer [PORT]          introduce players behind routers (UDP; no port: its own, by name)\n"
  "\nHeadless and tests:\n"
  "  --headless                   no window: the world played, a summary printed, exit code 0 / 1 (for CI)\n"
  "  --ticks N                    with --headless: play N ticks (600 by default: 10 s)\n"
  "  --key \"KEY@F[-G]\"          hold KEY from frame / tick F (to G); up to 16\n"
  "  --type \"LUA@F\"             run a console line (the live world: w) at frame / tick F; up to 16\n"
  "  --lite \"LUA@F\"             run Lua inside Lite at frame F; up to 16\n"
  "  --events \"l X,Y@F ...\"     scripted mouse: l / r / m clicks, x / X press / release, m moves, w / W wheel\n"
  "  --frames N                   quit after N frames\n"
  "  --shot FILE.bmp              save a screenshot when quitting (60 frames when --frames isn't given)\n"
  "  --pick \"EVENTS\"            scripted clicks in the project launcher\n"
  "  --pick-shot FILE.bmp         a screenshot of the project launcher\n"
  "  --export-dir DIR             Export writes there without asking\n"
  "\nMore: docs/CMDLINE.md, docs/HELP.md\n";

static bool a_ok(int axis) { return axis >= 0 && axis < 6; }
// retina: the renderer's scale (points -> the display's pixels); sizes are in points
static float g_retina = 1;
// the game's mouse and analog pads (w.mouse, w.pads: viewer_input in boot.lua).
// A world that asks for the mouse (/config window = { mouse = true }) gets the
// buttons pressed on the game area while it plays (no camera drag then);
// window.cursor = false hides the pointer over it.
static bool g_game_mouse, g_game_nocursor, g_cursor_hidden;
static Uint32 g_game_buttons;                      // the buttons the game holds (SDL_BUTTON_MASK)
static float g_pad_axis[4][6];                     // pads 1..4: left x, y, right x, y, triggers (-1..1, 0..1)
static void game_input(Viewer *V, float mx, float my, SDL_FRect gv, bool edfocus, SDL_Window *win) {
  lua_State *L = V->L;
  if (V->world == LUA_NOREF) return;
  if (V->stopped || V->paused) g_game_buttons = 0;  // (not playing: nothing held)
  float gx = mx - gv.x, gy = my - gv.y;
  bool inside = gx >= 0 && gy >= 0 && gx < gv.w && gy < gv.h && (V->standalone || !edfocus);
  int vi = vp_at(gx, gy);                          // (its view: the one under it, else the first)
  if (vi < 0 || vi >= g_nvp) vi = 0;
  SDL_FRect vr = g_vp[vi];
  float z = V->zoom * g_vp_fit;
  if (z <= 0) z = 1;
  float wx = (gx - (vr.x + vr.w / 2.f)) / z + V->camx, wy = (gy - (vr.y + vr.h / 2.f)) / z + V->camy;
  lua_getglobal(L, "viewer_input");
  if (!lua_isfunction(L, -1)) { lua_pop(L, 1); return; }
  lua_rawgeti(L, LUA_REGISTRYINDEX, V->world);
  lua_pushnumber(L, wx); lua_pushnumber(L, wy); lua_pushboolean(L, inside);
  lua_pushboolean(L, (g_game_buttons & SDL_BUTTON_LMASK) != 0);
  lua_pushboolean(L, (g_game_buttons & SDL_BUTTON_MMASK) != 0);
  lua_pushboolean(L, (g_game_buttons & SDL_BUTTON_RMASK) != 0);
  int npads = 0;
  SDL_JoystickID *ids = SDL_GetGamepads(&npads);
  SDL_free(ids);
  lua_createtable(L, npads, 0);
  for (int i = 0; i < npads && i < 4; i++) {
    lua_createtable(L, 0, 6);
    static const char *K[6] = { "lx", "ly", "rx", "ry", "lt", "rt" };
    for (int k = 0; k < 6; k++) {
      float v = g_pad_axis[i][k];
      if (k < 4 && v > -0.12f && v < 0.12f) v = 0;   // (a dead zone: a resting stick reads 0)
      lua_pushnumber(L, v); lua_setfield(L, -2, K[k]);
    }
    lua_rawseti(L, -2, i + 1);
  }
  if (lua_pcall(L, 8, 2, 0) != 0) { lua_pop(L, 1); return; }
  g_game_mouse = lua_toboolean(L, -2);
  g_game_nocursor = lua_toboolean(L, -1);
  lua_pop(L, 2);
  bool hide = g_game_nocursor && inside && !V->stopped && !V->paused && (SDL_GetWindowFlags(win) & SDL_WINDOW_MOUSE_FOCUS);
  if (hide != g_cursor_hidden) { g_cursor_hidden = hide; if (hide) SDL_HideCursor(); else SDL_ShowCursor(); }
}
static void out_size(SDL_Renderer *r, int *w, int *h) {
  SDL_GetRenderOutputSize(r, w, h);
  *w = (int)(*w / g_retina); *h = (int)(*h / g_retina);
}
int main(int argc, char **argv) {
#if defined(_WIN32) && defined(_MSC_VER)
  if (AttachConsole((unsigned long)-1)) {          // (ATTACH_PARENT_PROCESS: started from a terminal: print there)
    FILE *f;
    freopen_s(&f, "CONOUT$", "w", stdout);
    freopen_s(&f, "CONOUT$", "w", stderr);
  }
#endif
  g_argc = argc; g_argv = argv;
  Viewer V = { 0 };
  V.world = LUA_NOREF;
  V.panel = true;
  V.zoom = 1;
  V.tab_w = 216;                                   // tree tab, left
  V.speed = 1;
  V.fades[0] = 1; V.fades[1] = 0.75f; V.fades[2] = 0;   // playing: the game, paused: mixed, stopped: the editor
  V.fade = 0;
  V.edmode = 1;                                    // mixed
  int game_w = 640, game_h = 480;                  // game area, right of the tab
  bool game_arg = false;                           // (--game given: it wins over the world's screen)
  const char *path = NULL;                         // world to open (default: see below)
  bool want_standalone = false, want_editor = false, want_stopped = false, tab_arg = false;
  const char *shot = NULL;
  int frames = 0;
  bool use_editor = true;
  const char *events = NULL;                       // scripted clicks, for tests
  const char *keys[16]; int nkeys = 0;             // --key "F1@frame": key press, for tests
  const char *typed[16]; int ntyped = 0;           // --type "text@frame": console lines, for tests
  const char *pick_events = NULL, *pick_shot = NULL;   // --pick / --pick-shot: the picker, for tests
  const char *lites[16]; int nlites = 0;           // --lite "lua@frame": run in lite, for tests
  int headless = 0;                                // --headless [--ticks N]: no window, the world played N ticks (viewer_headless)
  const char *online_host = NULL, *online_join = NULL;   // --host [port] / --join addr[:port]: played online (players.lua)
  const char *online_via = NULL, *introducer = NULL;     // --via room@intro[:port] (a host through routers), --introducer [port] (nat.lua)
  int log_arg = -1;                                // --log 1, --no-log 0
  for (int i = 1; i < argc; i++) {
    if (!strcmp(argv[i], "--help") || !strcmp(argv[i], "-h") || !strcmp(argv[i], "-?") || !strcmp(argv[i], "/?")) {
      fputs(HELP_TEXT, stdout); fflush(stdout); return 0;
    }
    else if (!strcmp(argv[i], "--shot") && i + 1 < argc) shot = argv[++i];
    else if (!strcmp(argv[i], "--events") && i + 1 < argc) events = argv[++i];
    else if (!strcmp(argv[i], "--frames") && i + 1 < argc) frames = atoi(argv[++i]);
    else if (!strcmp(argv[i], "--type") && i + 1 < argc && ntyped < 16) typed[ntyped++] = argv[++i];
    else if (!strcmp(argv[i], "--key") && i + 1 < argc && nkeys < 16) keys[nkeys++] = argv[++i];
    else if (!strcmp(argv[i], "--headless")) { if (!headless) headless = 600; }
    else if (!strcmp(argv[i], "--host")) online_host = (i + 1 < argc && atoi(argv[i + 1]) > 0) ? argv[++i] : "";   // ("": the game's own ports, by its name)
    else if (!strcmp(argv[i], "--join") && i + 1 < argc) online_join = argv[++i];
    else if (!strcmp(argv[i], "--via") && i + 1 < argc) { online_via = argv[++i]; if (!online_host) online_host = ""; }
    else if (!strcmp(argv[i], "--introducer")) introducer = (i + 1 < argc && atoi(argv[i + 1]) > 0) ? argv[++i] : "";
    else if (!strcmp(argv[i], "--ticks") && i + 1 < argc) { headless = atoi(argv[++i]); if (headless < 1) headless = 1; }
    else if (!strcmp(argv[i], "--pick") && i + 1 < argc) pick_events = argv[++i];
    else if (!strcmp(argv[i], "--lite") && i + 1 < argc && nlites < 16) lites[nlites++] = argv[++i];
    else if (!strcmp(argv[i], "--pick-shot") && i + 1 < argc) pick_shot = argv[++i];
    else if (!strcmp(argv[i], "--game") && i + 1 < argc) { sscanf(argv[++i], "%dx%d", &game_w, &game_h); game_arg = true; }
    else if (!strcmp(argv[i], "--tab") && i + 1 < argc) { V.tab_w = atoi(argv[++i]); tab_arg = true; }
    else if ((!strcmp(argv[i], "--fps") || !strcmp(argv[i], "--fps-target")) && i + 1 < argc)
      fps_limit_arg = (float)atof(argv[++i]);     // 0 = unlimited
    else if (!strcmp(argv[i], "--no-editor")) use_editor = false;
    else if (!strcmp(argv[i], "--standalone")) want_standalone = true;
    else if (!strcmp(argv[i], "--editor")) want_editor = true;
    else if (!strcmp(argv[i], "--stopped")) want_stopped = true;
    else if (!strcmp(argv[i], "--prof")) g_prof = true;
    else if (!strcmp(argv[i], "--log")) log_arg = 1;
    else if (!strcmp(argv[i], "--no-log")) log_arg = 0;
    else if (!strcmp(argv[i], "--export-dir") && i + 1 < argc) SDL_strlcpy(g_export_dir_arg, argv[++i], sizeof g_export_dir_arg);
    else path = argv[i];
  }
  if (shot && frames <= 0) frames = 60;
  g_no_dialogs = events != NULL || nlites > 0;      // (scripted tests: no questions that would wait for a person)
  editor_set_scripted(events != NULL || nlites > 0 || ntyped > 0 || nkeys > 0);   // (and no workspace: each starts clean, leaves nothing)
  if (game_w < 64) game_w = 64;
  if (game_h < 64) game_h = 64;
  if (V.tab_w < 80) V.tab_w = 80;
  char *cwd = SDL_GetCurrentDirectory();
  const char *base = SDL_GetBasePath();
  {                                                // our own exe, absolute (Alt+click on play)
    const char *a0 = argc > 0 && argv[0] ? argv[0] : "play";
    const char *b = a0;
    for (const char *c = a0; *c; c++) if (*c == '/' || *c == '\\') b = c + 1;
    SDL_snprintf(launch_exe, sizeof launch_exe, "%s%s", base ? base : "", b);
    if (!exists(launch_exe)) {                     // (started as "play": the file is play.exe)
      char withexe[1100];
      SDL_snprintf(withexe, sizeof withexe, "%s.exe", launch_exe);
      if (exists(withexe)) SDL_strlcpy(launch_exe, withexe, sizeof launch_exe);
    }
    SDL_strlcpy(launch_cwd, cwd ? cwd : "", sizeof launch_cwd);
    char probe[1100];                              // Export: where runtime/ is (beside the exe, else the cwd)
    SDL_snprintf(probe, sizeof probe, "%sruntime/ecs.lua", base ? base : "");
    if (exists(probe) || !cwd) SDL_strlcpy(g_export_root, base ? base : "", sizeof g_export_root);
    else SDL_snprintf(g_export_root, sizeof g_export_root, "%s%s", cwd, cwd[0] && cwd[strlen(cwd) - 1] != '/' && cwd[strlen(cwd) - 1] != '\\' ? "/" : "");
  }

  // The exe's name picks the defaults, so a renamed copy is a game:
  // pong.exe opens pong/ (or pong.lua) next to it and uses pong.png as icon.
  char stem[256];
  {
    const char *a0 = argc > 0 && argv[0] ? argv[0] : "game";
    const char *b = a0;
    for (const char *c = a0; *c; c++) if (*c == '/' || *c == '\\') b = c + 1;
    SDL_strlcpy(stem, b, sizeof stem);
    char *dot = SDL_strrchr(stem, '.');
    if (dot && dot != stem) *dot = 0;               // pong.exe -> pong
  }
  SDL_snprintf(g_icon_path, sizeof g_icon_path, "%s%s.png", base ? base : "", stem);   // (the picker's window too)
  // The argument picks what opens:
  //   none                       the project launcher (games/*). (A renamed
  //                              copy, pong.exe, opens its game: shipping)
  //   a .lua, .hurdy or a folder a game: it runs
  //   any other file             an asset: the plugin that takes its
  //                              extension opens it (plugins/<name>/files.lua),
  //                              in front; the world is the game it's in
  //                              (games/<name>/..., stopped), else none. No
  //                              plugin takes it: exit -1
  static char asset[1024], asset_game[1024];
  bool asset_only = false;                         // (an asset, in no game: no world)
  if (path) {
    SDL_PathInfo pi;
    size_t n = strlen(path);
    bool code = (n > 4 && !SDL_strcasecmp(path + n - 4, ".lua")) || (n > 6 && !SDL_strcasecmp(path + n - 6, ".hurdy"));
    if (!code && SDL_GetPathInfo(path, &pi) && pi.type == SDL_PATHTYPE_FILE) {
      char pd[1100], plugin[256];
      plugins_dir(base, cwd, pd, sizeof pd);
      if (!asset_plugin(pd, path, plugin, sizeof plugin)) {
        fprintf(stderr, "%s: no plugin opens it (none of %s/*/files.lua lists its extension)\n", path, pd);
        return -1;
      }
      char *a = absolute(path);
      SDL_strlcpy(asset, a ? a : path, sizeof asset);
      SDL_free(a);
      path = NULL;
      want_stopped = true;                         // (editing an asset: its game doesn't run)
      SDL_strlcpy(asset_game, asset, sizeof asset_game);
      while (cut_last(asset_game)) {               // up one folder at a time: games/<name>?
        char parent[1024];
        SDL_strlcpy(parent, asset_game, sizeof parent);
        if (!cut_last(parent)) break;
        if (!SDL_strcasecmp(last_part(parent), "games")) { path = asset_game; break; }
      }
      asset_only = !path;
    }
  }
  char guess[1024];
  if (!path && !asset_only) {                      // <exe>/, <exe>.lua|.hurdy, games/<exe>/, games/<exe>.lua|.hurdy,
    static const char *where[] = { "", "games/" };  // else: the project picker (games/*)
    for (int i = 0; i < 2 && !path; i++) {
      SDL_snprintf(guess, sizeof guess, "%s%s%s", base ? base : "", where[i], stem);
      SDL_PathInfo pi;
      if (SDL_GetPathInfo(guess, &pi) && pi.type == SDL_PATHTYPE_DIRECTORY) path = guess;
      else for (int k = 0; k < 2 && !path; k++) {    // <exe>.lua, then <exe>.hurdy
        SDL_snprintf(guess, sizeof guess, "%s%s%s%s", base ? base : "", where[i], stem, k ? ".hurdy" : ".lua");
        if (exists(guess)) path = guess;
      }
    }
    if (!path) {                                   // games/: the launcher
      if (!pick_scan(base) && cwd && (!base || strcmp(cwd, base))) pick_scan(cwd);
      settings_path_init(base);                    // (its Theme: the picker light or dark)
      settings_load();
      path = pick_project(pick_events, pick_shot);   // (none in games/: the picker anyway, to make one)
      if (!path) return 0;                         // closed without choosing: quit
      g_from_picker = true;
    }
  }
  // Shipping: with no .c sources next to the exe this is a packaged game, so
  // it runs standalone (--editor / --standalone override it).
  if (want_standalone) V.standalone = true;
  else if (!want_editor && base) {
    int nsrc = 0;
    char **src = SDL_GlobDirectory(base, "*.c", 0, &nsrc);
    SDL_free(src);
    if (nsrc == 0) V.standalone = true;
  }
  V.stopped = !V.standalone;                       // dev UI: start stopped, press play
  if (V.standalone) { use_editor = false; V.tab_w = 0; BAR_H = 0; V.paused = false; }
  g_tab_w = V.tab_w;
  V.path = asset_only ? SDL_strdup("") : absolute(path);   // ("": no world)

  // Lua (game world VM)
  lua_State *L = V.L = luaL_newstate();
  luaL_openlibs(L);
  {
    lua_getglobal(L, "package");                   // find runtime/ecs.lua in cwd or next to the exe
    lua_pushfstring(L, "%sruntime/?.lua;%sruntime/?/init.lua;%sruntime/?.lua;%sruntime/?/init.lua;%s?.lua;%s?.lua;",
                    cwd ? cwd : "./", cwd ? cwd : "./", base ? base : "", base ? base : "",
                    cwd ? cwd : "./", base ? base : "");   // runtime/?/init.lua: hurdyl
    lua_getfield(L, -2, "path");
    lua_concat(L, 2);
    lua_setfield(L, -2, "path");
    lua_pop(L, 1);
  }
  register_hostfs(L);
  editor_udp_register(L);                          // `udp`: real sockets (net.udp: hosting / joining a game online)
  sound_register(L);                               // host_sound: the game's sounds (runtime/sound.lua)
  lua_register(L, "viewer_abspath", l_abspath);    // (boot.lua: unsaved editor files, by absolute path)
  ov_register(L, !V.standalone);                   // `dd`: no-ops when standalone
  {                                                // the viewer's Lua side (runtime/boot.lua)
    char err[2048];
    if (!boot_load(L, cwd, base, err, sizeof err)) {
      fprintf(stderr, "viewer boot failed: %s\n", err);
      return 1;
    }
  }
  {                                                // /plugins: the folders of plugins/ (next to the exe, like games/; else here)
    char pd[1100];
    plugins_dir(base, cwd, pd, sizeof pd);
    lua_pushstring(L, pd);
    lua_setglobal(L, "viewer_plugins_dir");
    editor_set_plugins_dir(pd);                    // (lite loads their editor.lua: the same folders)
    help_find(base, cwd);
  }
  probe_init(&V);
  players_init(&V);
  load_world(&V);
  if (V.err[0]) fprintf(stderr, "%s\n", V.err);
  if (headless) {                                  // no window: the world played, the result printed, its exit code
    int code = 1;
    if (V.world != LUA_NOREF) {
      lua_getglobal(L, "viewer_headless");
      lua_rawgeti(L, LUA_REGISTRYINDEX, V.world);
      lua_pushinteger(L, headless);
      lua_newtable(L);
      for (int i = 0; i < nkeys; i++) { lua_pushstring(L, keys[i]); lua_rawseti(L, -2, i + 1); }
      lua_newtable(L);
      for (int i = 0; i < ntyped; i++) { lua_pushstring(L, typed[i]); lua_rawseti(L, -2, i + 1); }
      lua_newtable(L);
      if (online_host) { lua_pushinteger(L, atoi(online_host)); lua_setfield(L, -2, "host"); }
      if (online_join) { lua_pushstring(L, online_join); lua_setfield(L, -2, "join"); }
      if (online_via) { lua_pushstring(L, online_via); lua_setfield(L, -2, "via"); }
      if (introducer) { lua_pushinteger(L, atoi(introducer)); lua_setfield(L, -2, "introducer"); }
      if (lua_pcall(L, 5, 1, 0) != 0) fprintf(stderr, "headless: %s\n", lua_tostring(L, -1));
      else code = (int)lua_tointeger(L, -1);
    } else fprintf(stderr, "headless: no world\n");
    fflush(stdout);
    lua_close(L);
    return code;
  }

  // SDL: windowed and centered; client = tab + game
  // a click on an unfocused window must not be eaten by window activation
  SDL_SetHint(SDL_HINT_MOUSE_FOCUS_CLICKTHROUGH, "1");
  if (!SDL_Init(SDL_INIT_VIDEO | SDL_INIT_GAMEPAD)) { fprintf(stderr, "%s\n", SDL_GetError()); return 1; }
  SDL_Window *win = NULL;
  char title[256];                                  // "pong/" or "scene1.lua" -> "Pong", "Scene1"
  {
    const char *b = V.path;
    for (const char *c = V.path; *c; c++) if ((*c == '/' || *c == '\\') && c[1]) b = c + 1;
    SDL_strlcpy(title, b, sizeof title);
    size_t n = strlen(title);
    while (n && (title[n - 1] == '/' || title[n - 1] == '\\')) title[--n] = 0;
    if (n > 4 && !strcmp(title + n - 4, ".lua")) title[n - 4] = 0;
    else if (n > 6 && !strcmp(title + n - 6, ".hurdy")) title[n - 6] = 0;
    title[0] = (char)SDL_toupper((unsigned char)title[0]);
    if (!title[0]) SDL_strlcpy(title, "Replay", sizeof title);
  }
  if (V.world != LUA_NOREF) {                      // the world's own size and title: /config's window
    lua_rawgeti(L, LUA_REGISTRYINDEX, V.world);      // = { w =, h =, title = } (config/window.lua), else
    int wt = lua_gettop(L);                          // the root's screen = { w =, h = } (screen.lua)
    lua_getfield(L, wt, "nodes");
    if (lua_istable(L, -1)) lua_getfield(L, -1, "/config"); else lua_pushnil(L);
    if (lua_istable(L, -1)) lua_getfield(L, -1, "c"); else lua_pushnil(L);
    if (lua_istable(L, -1)) lua_getfield(L, -1, "window"); else lua_pushnil(L);
    if (!lua_istable(L, -1)) {
      lua_pop(L, 1);
      lua_getfield(L, wt, "root");
      if (lua_istable(L, -1)) lua_getfield(L, -1, "c"); else lua_pushnil(L);
      if (lua_istable(L, -1)) lua_getfield(L, -1, "screen"); else lua_pushnil(L);
    }
    if (lua_istable(L, -1)) {
      int t = lua_gettop(L);
      int sw = (int)fnum(L, t, "w", game_w), sh = (int)fnum(L, t, "h", game_h);
      if (!game_arg && sw >= 64 && sh >= 64 && sw <= 8192 && sh <= 8192) { game_w = sw; game_h = sh; }
      lua_getfield(L, t, "title");
      if (lua_type(L, -1) == LUA_TSTRING && lua_tostring(L, -1)[0]) SDL_strlcpy(title, lua_tostring(L, -1), sizeof title);
      lua_pop(L, 1);
    }
    lua_settop(L, wt - 1);
  }
  if (shot) printf("window \"%s\"%s: %s\n", title, V.standalone ? " (standalone)" : "", V.path);
  bool retina = false;                             // the display's own pixels (Retina); .preferences.lua retina = false: off
  settings_path_init(base); settings_load(); retina = g_settings.retina != 0;   // (the game alone too: sharp on a Retina display)
  const char *force = SDL_getenv("REPLAY_SCALE");   // (test hook: a window of N times the pixels, as a Retina shows it)
  float fk = force ? (float)SDL_atof(force) : 1;
  if (fk < 1) fk = 1;
  if (!SDL_CreateWindowAndRenderer(title, (int)((V.tab_w + game_w) * fk), (int)((game_h + BAR_H) * fk),
                                   SDL_WINDOW_RESIZABLE | (retina ? SDL_WINDOW_HIGH_PIXEL_DENSITY : 0), &win, &V.ren)) {
    fprintf(stderr, "%s\n", SDL_GetError());
    return 1;
  }
  SDL_SetWindowMinimumSize(win, V.standalone ? 160 : V.tab_w + 360, 160 + BAR_H);
  SDL_SetWindowPosition(win, SDL_WINDOWPOS_CENTERED, SDL_WINDOWPOS_CENTERED);
  if (retina || force) {                            // drawn in points at the display's density; lite at its pixels
    float d = force ? fk : SDL_GetWindowPixelDensity(win);
    if (d > 1.01f) { SDL_SetRenderScale(V.ren, d, d); editor_set_scale(d); g_retina = d; }
  }
  SDL_RaiseWindow(win);                            // take focus from the launching terminal
  apply_window_icon(win);                          // window icon: <exe name>.png next to the exe
  SDL_SetRenderDrawBlendMode(V.ren, SDL_BLENDMODE_BLEND);
  SDL_SetRenderVSync(V.ren, 0);                    // no vsync lock: our own limiter below
  update_fps_limit(win);
  Uint64 frame_deadline = SDL_GetTicksNS();

  int w = 0, h = 0;                                // window, then the game area inside it
  out_size(V.ren, &w, &h);
  SDL_FRect gv = { (float)V.tab_w, 0, (float)(w - V.tab_w), (float)(h - BAR_H) };

  // lite editor, behind the game area. It opens the world folder, or the cwd.
  bool edfocus = false;
  g_edfocus_p = &edfocus;                          // (editor/side.h: opening a source from the tab shows the editor)
  if (use_editor) {
    char *datadir = NULL;
    SDL_asprintf(&datadir, "%seditor/3rd/lite", base ? base : "");
    char probe[1024];
    SDL_snprintf(probe, sizeof probe, "%s/data/core/init.lua", datadir);
    if (!exists(probe)) { SDL_free(datadir); SDL_asprintf(&datadir, "%seditor/3rd/lite", cwd ? cwd : ""); }
    char *project = SDL_strdup(V.isdir ? V.path : (cwd ? cwd : "."));
    SDL_strlcpy(g_project_dir, project, sizeof g_project_dir);   // (Reset editor: its workspace)
    size_t n = strlen(project);                   // stat() dislikes a trailing separator
    while (n > 1 && (project[n - 1] == '/' || project[n - 1] == '\\') && project[n - 2] != ':')
      project[--n] = 0;
    {                                              // .log.txt in the project: this run's messages
      char lp[1200];
      SDL_snprintf(lp, sizeof lp, "%s/.log.txt", project);
      ov_log_open(lp);
    }
    { int ow = 0, oh = 0; out_size(V.ren, &ow, &oh); editor_viewport((int)gv.x, (int)gv.y, (int)gv.w, (int)gv.h, ow, oh); }
    editor_set_host_call(host_call);               // (lite's menus answer here: menus.h)
    g_mv = &V; g_mwin = win;
    editor_set_probe(probe_get);
    editor_set_probe_eval(probe_eval);
    editor_set_breaks(probe_break_set, probe_break_where);   // (host_break_set / host_break_where in lite)
    editor_set_world_file(probe_world_file);       // (host_world_file: the main script; its breakpoints stop at Play)
    editor_set_break_step(probe_break_step);       // (host_break_step: F5 / F10 / F11 / shift+F11)                   // (host_probe in lite: the graph asks what ran)
    if (editor_init(win, V.ren, datadir, project)) {
      side_init();                                 // (the tab's host functions: editor/side.h)
      ov_replay(editor_log);                       // lite's log gets what came before it, then all the rest
      ov.forward = editor_log;
      edfocus = false;                             // view_rules picks the view (stopped: mixed)
      editor_focus(false);
      settings_path_init(base);                    // the command line, then .preferences.lua, else hidden
      settings_load();
      if (!tab_arg && g_settings.tab_width != SET_NONE) {   // the tab's width, as it was left (--tab wins)
        V.tab_w = g_tab_w = tab_width_fit(g_settings.tab_width, w);
        SDL_SetWindowMinimumSize(win, V.tab_w + 360, 160 + BAR_H);
      }
      editor_boot_log(log_arg >= 0 ? log_arg : g_settings.log_window);
      update_fps_limit(win);                       // (the menu's FPS)
      if (settings_confirm_close()) editor_exec("require('core.config').confirm_close_unsaved = true");
      if (g_settings.theme >= 0) settings_apply_theme();   // (unset: lite's own, as it started)
      if (g_settings.tab_font != SET_NONE) editor_ui_font(g_settings.tab_font);   // (the tab's font size, CTRL+wheel)
      // a project opened for the first time (no lite workspace saved there
      // yet): lite starts on its root file, the world script or the folder's
      // outermost .lua. Later sessions get the tabs lite saved.
      char ws[1200], ws_old[1200];                 // (.lite_workspace.lua: its old name, still read once)
      SDL_snprintf(ws, sizeof ws, "%s/.workspace.lua", project);
      SDL_snprintf(ws_old, sizeof ws_old, "%s/.lite_workspace.lua", project);
      // A file given on the command line always opens (in front of the
      // restored tabs); a folder world opens its root file when there's no
      // workspace yet, or one with no tabs in it, or the world didn't load.
      if (!V.isdir || !ws_has_tabs(ws, ws_old) || V.err[0]) {
        char root[1024];
        int eline = 0;                             // it didn't load: at the line the error names (else: where it was)
        const char *bn = V.path;                   // (by its name: Lua shortens long paths to ...tail)
        for (const char *c = V.path; *c; c++) if (*c == '/' || *c == '\\') bn = c + 1;
        const char *at = V.err[0] && !V.isdir && *bn ? strstr(V.err, bn) : NULL;
        if (at && at[strlen(bn)] == ':') eline = atoi(at + strlen(bn) + 1);
        if (!V.isdir) editor_open_later_at(V.path, eline);
        else if (find_root_lua(project, root, sizeof root)) editor_open_later(root);   // (relative: lite works in the folder)
      }
      if (asset[0]) editor_open_later(asset);      // (an asset given: in front)
    } else {
      SDL_snprintf(V.err, sizeof V.err, "%s", editor_error());
      fprintf(stderr, "%s\n", V.err);
    }
    SDL_free(project);
    SDL_free(datadir);
  }

  SDL_Texture *layer = NULL;                       // the game, drawn over the editor
  int layer_w = 0, layer_h = 0;

  Uint64 last = SDL_GetTicksNS(), fps_t = last;
  double reload_t = 0;
  int fps = 0, fps_n = 0;
  bool running = true, dragging = false;
  int lite_refresh[2] = { 0, 0 };                  // frames at which lite repaints whole again (a window change)
  int swallow_up = 0;                              // button whose release belongs to an inspect click
  Uint32 ed_held = 0;                              // buttons pressed into the editor: their release goes there too
  int alt_pending = 0;                             // --events "a..." = Alt+right-click
  int ctrl_pending = 0;                            // --events "c..." = Ctrl+left-click
  bool bar_drag = false;                           // dragging the timeline playhead
  bool edge_drag = false;                          // dragging the tab's right edge (its width)
  Uint64 esc_t0 = 0;                               // ESC held since (0 = not held)
  bool esc_long = false;                           // this press already went to the game
  float mx = 0, my = 0;                            // last mouse position, render pixels
  Uint64 mouse_still = 0;                          // when the mouse last moved or clicked

  // start playing, in the game view (--stopped: start on the authored world)
  if (!V.standalone && !want_stopped && V.world != LUA_NOREF) session_start(&V);
  if (online_host || online_join) {               // --host / --join: the power button on (online), playing now: online now
    int top = lua_gettop(L);
    lua_getglobal(L, "viewer_online_set");
    lua_pushboolean(L, 1);
    lua_pushstring(L, online_host ? "host" : "join");
    lua_pushstring(L, online_host ? online_host : online_join);
    if (online_via) lua_pushstring(L, online_via); else lua_pushnil(L);
    if (lua_pcall(L, 4, 0, 0) != 0) ov_log(OV_ERROR, "online: %s", lua_tostring(L, -1));
    lua_settop(L, top);
    if (!V.stopped) { online_begin(&V); if (V.err[0]) ov_log(OV_ERROR, "%s", V.err); }
  }
  if (introducer) {                               // --introducer: players behind routers meet here (nat.lua)
    int top = lua_gettop(L);
    lua_getglobal(L, "viewer_introducer");
    lua_pushinteger(L, atoi(introducer));
    if (lua_pcall(L, 1, 2, 0) != 0) ov_log(OV_ERROR, "introducer: %s", lua_tostring(L, -1));
    else if (!lua_toboolean(L, -2)) ov_log(OV_ERROR, "introducer: %s", lua_tostring(L, -1));
    lua_settop(L, top);
  }
  bool was_stopped = V.stopped;
  while (running) {
    ui_begin();                                    // lite's font and theme, for the tab, tooltips, the bar (ui.h)
    view_rules(&V, &edfocus, &was_stopped);        // which views are allowed now (see view_rules)
    launch_poll(&V, win);                          // the standalone copy has exited: come back
    if (g_want_join) {                             // the power menu's Join...: the console, join("|")
      g_want_join = false;
      con_focus(win, true, edfocus);
      le_set(&con.e, "join(\"\")");
      con.e.cur = con.e.len - 2;
      if (con_lite) editor_prompt("set", con.e.s, (float)con.e.cur, 0, 0);   // (lite types it: the caret between the quotes)
    }
    export_poll(&V, win);                          // Export: a folder picked? copy, then say how it went
    // --events "r640,400@10 l20,40@30 w520,240@5": right/left click, or
    // wheel up (w) / down (W), at x,y (window units, like real mouse
    // events) on frame N. Also: a = Alt+right-click, c = Ctrl+left-click,
    // d / m / u = left down / mouse move / left up (drags), e / E = ESC down / up,
    // k / K = a key down / up (x = its keycode; x,1: the function key Fx), x / X = right down / up
    for (const char *ev = events; ev && *ev; ) {
      char b; float x, y; int f, used = 0;
      if (sscanf(ev, " %c%f,%f@%d%n", &b, &x, &y, &f, &used) != 4) break;
      ev += used;
      if (f != V.frame) continue;
      SDL_Event c = { 0 };
      c.button.windowID = SDL_GetWindowID(win);    // like real events (needed for coord conversion)
      if (b == 'e' || b == 'E') {                  // ESC down / up (x,y ignored)
        c.type = b == 'e' ? SDL_EVENT_KEY_DOWN : SDL_EVENT_KEY_UP;
        c.key.key = SDLK_ESCAPE;
        c.key.down = b == 'e';
        SDL_PushEvent(&c);
        continue;
      }
      if (b == 'k' || b == 'K') {                  // a key down / up: x = its code (e.g. 119 = w)
        c.type = b == 'k' ? SDL_EVENT_KEY_DOWN : SDL_EVENT_KEY_UP;
        c.key.key = y > 0 ? (SDL_Keycode)(SDLK_F1 + (int)x - 1) : (SDL_Keycode)x;   // (y = 1: F<x>)
        c.key.down = b == 'k';
        SDL_PushEvent(&c);
        continue;
      }
      if (b == 'w' || b == 'W') {                  // wheel up / down at x,y
        c.type = SDL_EVENT_MOUSE_WHEEL;
        c.wheel.windowID = SDL_GetWindowID(win);
        c.wheel.y = b == 'w' ? 1.f : -1.f;
        c.wheel.mouse_x = x; c.wheel.mouse_y = y;
        SDL_PushEvent(&c);
        continue;
      }
      if (b == 'x' || b == 'X') {                  // right down / up, apart (x = down, X = up)
        c.type = b == 'x' ? SDL_EVENT_MOUSE_BUTTON_DOWN : SDL_EVENT_MOUSE_BUTTON_UP;
        c.button.button = SDL_BUTTON_RIGHT; c.button.down = b == 'x';
        c.button.x = x; c.button.y = y; c.button.clicks = 1;
        SDL_PushEvent(&c);
        continue;
      }
      if (b == 'd' || b == 'u' || b == 'm') {      // left down / up / mouse move, apart
        if (b == 'm') {
          c.type = SDL_EVENT_MOUSE_MOTION;
          c.motion.windowID = SDL_GetWindowID(win);
          static float lmx, lmy;                   // relative motion too, like a real mouse
          c.motion.x = x; c.motion.y = y;
          c.motion.xrel = x - lmx; c.motion.yrel = y - lmy;
          lmx = x; lmy = y;
        } else {
          c.type = b == 'd' ? SDL_EVENT_MOUSE_BUTTON_DOWN : SDL_EVENT_MOUSE_BUTTON_UP;
          c.button.button = SDL_BUTTON_LEFT; c.button.down = b == 'd';
          c.button.x = x; c.button.y = y; c.button.clicks = 1;
        }
        SDL_PushEvent(&c);
        continue;
      }
      if (b == 'c') { ctrl_pending++; b = 'l'; }     // Ctrl+left-click
      if (b == 'a') alt_pending++;                  // Alt+right-click
      c.button.button = (b == 'r' || b == 'a') ? SDL_BUTTON_RIGHT : SDL_BUTTON_LEFT;
      c.button.x = x; c.button.y = y; c.button.clicks = 1; c.button.down = true;
      c.type = SDL_EVENT_MOUSE_BUTTON_DOWN; SDL_PushEvent(&c);
      c.button.down = false;
      c.type = SDL_EVENT_MOUSE_BUTTON_UP; SDL_PushEvent(&c);
    }

    // --type "w:node('/scene/box').c.spin = 5@40": at frame N, type the text
    // into the console (focusing it) and press Enter
    for (int i = 0; i < ntyped; i++) {
      const char *at = strrchr(typed[i], '@');
      if (!at || atoi(at + 1) != V.frame) continue;
      static char tbuf[16][512];
      SDL_snprintf(tbuf[i], sizeof tbuf[i], "%.*s", (int)(at - typed[i]), typed[i]);
      if (!g_side_focus && !g_menu_open) con_focus(win, true, edfocus);   // else: it types the value (or a menu's search, the tree filter's)
      SDL_Event c = { 0 };
      c.type = SDL_EVENT_TEXT_INPUT; c.text.windowID = SDL_GetWindowID(win); c.text.text = tbuf[i];
      SDL_PushEvent(&c);
      if (g_menu_open) continue;                   // (a menu: it only filters; --key Return picks)
      SDL_Event k = { 0 };
      k.type = SDL_EVENT_KEY_DOWN; k.key.windowID = c.text.windowID; k.key.key = SDLK_RETURN; k.key.down = true;
      SDL_PushEvent(&k);
    }

    for (int i = 0; i < nlites; i++) {             // --lite "core.log('hi')@30": Lua inside lite
      const char *at = strrchr(lites[i], '@');
      if (!at || atoi(at + 1) != V.frame) continue;
      char *code = SDL_strndup(lites[i], (size_t)(at - lites[i]));
      editor_exec(code);
      SDL_free(code);
    }

    for (int i = 0; i < nkeys; i++) {              // --key "F1@30": press + release
      const char *at = strrchr(keys[i], '@');
      if (!at || atoi(at + 1) != V.frame) continue;
      char kn[64];
      SDL_snprintf(kn, sizeof kn, "%.*s", (int)(at - keys[i]), keys[i]);
      SDL_Event k = { 0 };
      k.key.windowID = SDL_GetWindowID(win);
      SDL_Keycode held[2];                         // ("ctrl+z@30", "shift+home@30", "ctrl+shift+left@30": the modifiers pressed
      int nheld = 0;                               //  around it too, as a keyboard does: lite counts them by their keys)
      for (;;) {
        if (!SDL_strncasecmp(kn, "ctrl+", 5)) { k.key.mod |= SDL_KMOD_LCTRL; held[nheld++] = SDLK_LCTRL; SDL_memmove(kn, kn + 5, strlen(kn + 5) + 1); }
        else if (!SDL_strncasecmp(kn, "shift+", 6)) { k.key.mod |= SDL_KMOD_LSHIFT; held[nheld++] = SDLK_LSHIFT; SDL_memmove(kn, kn + 6, strlen(kn + 6) + 1); }
        else break;
        if (nheld == 2) break;
      }
      SDL_Event mk = k;
      for (int m = 0; m < nheld; m++) { mk.type = SDL_EVENT_KEY_DOWN; mk.key.down = true; mk.key.key = held[m]; SDL_PushEvent(&mk); }
      k.key.key = SDL_GetKeyFromName(kn);
      k.type = SDL_EVENT_KEY_DOWN; k.key.down = true; SDL_PushEvent(&k);
      k.type = SDL_EVENT_KEY_UP; k.key.down = false; SDL_PushEvent(&k);
      for (int m = nheld - 1; m >= 0; m--) { mk.type = SDL_EVENT_KEY_UP; mk.key.down = false; mk.key.key = held[m]; mk.key.mod = 0; SDL_PushEvent(&mk); }
    }

    SDL_Event e;
    for (int k = 0; k < 2; k++)                    // (a window change's later repaints: see below)
      if (lite_refresh[k] && V.frame >= lite_refresh[k]) { lite_refresh[k] = 0; editor_render_reset(false); }
    while (SDL_PollEvent(&e)) {
      if (e.type == SDL_EVENT_RENDER_TARGETS_RESET || e.type == SDL_EVENT_RENDER_DEVICE_RESET ||
          e.type == SDL_EVENT_WINDOW_EXPOSED) {    // the GPU lost what textures held: lite's image whole again (editor/editor.c)
        editor_render_reset(e.type == SDL_EVENT_RENDER_DEVICE_RESET);
        if (e.type == SDL_EVENT_RENDER_DEVICE_RESET) tex_reset();   // (the game's images: read again)
      }
      // the window maximized / restored / resized / shown, or moved to
      // another display: lite repaints whole and sends it all, now and
      // again a few frames and ~1/4 s later (Windows can drop a texture's
      // contents after the event: the text editor, the only part not
      // redrawn every frame, then kept old pixels)
      if (e.type == SDL_EVENT_WINDOW_MAXIMIZED || e.type == SDL_EVENT_WINDOW_RESTORED ||
          e.type == SDL_EVENT_WINDOW_RESIZED || e.type == SDL_EVENT_WINDOW_PIXEL_SIZE_CHANGED ||
          e.type == SDL_EVENT_WINDOW_SHOWN || e.type == SDL_EVENT_WINDOW_DISPLAY_CHANGED ||
          e.type == SDL_EVENT_WINDOW_ENTER_FULLSCREEN || e.type == SDL_EVENT_WINDOW_LEAVE_FULLSCREEN) {
        editor_render_reset(false);
        lite_refresh[0] = V.frame + 3;
        lite_refresh[1] = V.frame + 15;
      }
      SDL_Event raw = e;                           // before conversion, for the click log
      bool isbtn = e.type == SDL_EVENT_MOUSE_BUTTON_DOWN || e.type == SDL_EVENT_MOUSE_BUTTON_UP;
      // Mouse events arrive in window units; we draw and pick in render
      // pixels. They differ with Windows display scaling (e.g. 150%), so
      // convert first: everything below (picking, tab, lite) sees pixels.
      SDL_ConvertEventToRenderCoordinates(V.ren, &e);
      bool ed = editor_running();
      bool down = e.type == SDL_EVENT_MOUSE_BUTTON_DOWN;
      int zone0 = tip_zone(&V, w, h, mx, my);      // (what a tooltip shown is for, before this event)
      if (down || e.type == SDL_EVENT_MOUSE_BUTTON_UP) { mx = e.button.x; my = e.button.y; }
      else if (e.type == SDL_EVENT_MOUSE_MOTION) { mx = e.motion.x; my = e.motion.y; }
      else if (e.type == SDL_EVENT_MOUSE_WHEEL) { mx = e.wheel.mouse_x; my = e.wheel.mouse_y; }
      // a menu open (lite draws every popup: menus.h): it has the mouse and the
      // keys until it closes (a click outside it closes it, and goes no further)
      if (ed && g_menu_open && (e.type == SDL_EVENT_MOUSE_MOTION || down || e.type == SDL_EVENT_MOUSE_BUTTON_UP ||
                                e.type == SDL_EVENT_MOUSE_WHEEL || e.type == SDL_EVENT_KEY_DOWN || e.type == SDL_EVENT_KEY_UP ||
                                e.type == SDL_EVENT_TEXT_INPUT)) {
        if (down) ed_held |= SDL_BUTTON_MASK(e.button.button);
        if (e.type == SDL_EVENT_MOUSE_BUTTON_UP) ed_held &= ~SDL_BUTTON_MASK(e.button.button);
        if (e.type == SDL_EVENT_MOUSE_MOTION && SDL_GetCursor() != SDL_GetDefaultCursor()) SDL_SetCursor(SDL_GetDefaultCursor());
        editor_event(&e);
        mouse_still = SDL_GetTicks();
        continue;
      }
      // the Lua prompt pressed (typed in lite): the drag selects, wherever the mouse goes
      if (con_drag && e.type == SDL_EVENT_MOUSE_MOTION) { editor_prompt("mouse", "moved", mx, my, 0); continue; }
      if (con_drag && e.type == SDL_EVENT_MOUSE_BUTTON_UP && e.button.button == SDL_BUTTON_LEFT) {
        editor_prompt("mouse", "released", mx, my, 0);
        con_drag = false;
        continue;
      }
      // the left tab (lite draws it: editor/side.h, plugins/sidetab.lua): the
      // mouse there is lite's (a press there is released there, wherever the
      // mouse is then), and the keyboard while it types (a value, the filter)
      if (ed && !V.standalone) {
        bool in_side = mx >= 0 && mx < V.tab_w - 3 && my > TOOLS_H && my < h - BAR_H &&
                       !edge_drag && !tab_edge_at(h - BAR_H, mx, my, V.tab_w);   // (the tab's edge, or dragging it: ours)
        static Uint32 side_held;
        static bool side_in;
        bool mouse = e.type == SDL_EVENT_MOUSE_MOTION || down || e.type == SDL_EVENT_MOUSE_BUTTON_UP || e.type == SDL_EVENT_MOUSE_WHEEL;
        bool held_up = e.type == SDL_EVENT_MOUSE_BUTTON_UP && (side_held & SDL_BUTTON_MASK(e.button.button));
        if (down && !in_side && g_side_focus) editor_side_blur();   // (a click elsewhere: the value typed is kept)
        if (mouse && ((in_side && e.type != SDL_EVENT_MOUSE_BUTTON_UP) || held_up || (side_held && e.type == SDL_EVENT_MOUSE_MOTION))) {
          if (down) {
            side_held |= SDL_BUTTON_MASK(e.button.button);
            if (con.focus) con_focus(win, false, edfocus);
            if (e.button.button == SDL_BUTTON_LEFT && ctrl_pending > 0) { ctrl_pending--; g_ctrl_pending++; }   // (--events "c...")
          }
          if (held_up) side_held &= ~SDL_BUTTON_MASK(e.button.button);
          editor_mods(SDL_GetModState());
          editor_event(&e);
          side_in = in_side;
          if (e.type == SDL_EVENT_MOUSE_MOTION) {
            g_edge_hot = false;
            if (SDL_GetTicks() - mouse_still > 0) mouse_still = SDL_GetTicks();
          }
          continue;
        }
        if (e.type == SDL_EVENT_MOUSE_MOTION && side_in) {   // out of it: its hovers end
          side_in = false;
          SDL_Event away = e;
          away.motion.x = away.motion.y = -100000.f;
          editor_event(&away);
        }
        if (g_side_focus && (e.type == SDL_EVENT_KEY_DOWN || e.type == SDL_EVENT_KEY_UP ||
                             e.type == SDL_EVENT_TEXT_INPUT || e.type == SDL_EVENT_TEXT_EDITING)) {
          editor_event(&e);
          continue;
        }
      }
      if (e.type == SDL_EVENT_MOUSE_MOTION) {      // the view under the mouse gets the keyboard (Players)
        int vp = vp_at(mx - gv.x, my - gv.y);
        if (vp > 0) g_key_player = vp;
      }
      if (e.type == SDL_EVENT_MOUSE_MOTION && ed) {   // the mouse left lite's area (the tab, the bar): it hears so once,
        static bool ed_in = false;                     // and its hovers end (a tab's tooltip, a highlighted button)
        bool in = mx >= gv.x && mx < gv.x + gv.w && my >= gv.y && my < gv.y + gv.h;
        if (ed_in && !in && !ed_held) {
          SDL_Event away = e;
          away.motion.x = away.motion.y = -100000.f;
          editor_event(&away);
        }
        ed_in = in;
      }
      bool in_tab = mx < V.tab_w;
      bool tip_on = SDL_GetTicks() - mouse_still >= TIP_DELAY_MS;   // a tooltip shown: moving within what it's for keeps it
      bool same_zone = e.type == SDL_EVENT_MOUSE_MOTION && tip_on && zone0 >= 0 && tip_zone(&V, w, h, mx, my) == zone0;
      if ((e.type == SDL_EVENT_MOUSE_MOTION && !same_zone) || down || e.type == SDL_EVENT_MOUSE_BUTTON_UP)
        mouse_still = SDL_GetTicks();                // moving away or clicking hides tooltips (the wheel doesn't: a tooltip stays while hovering)
      ov_input_event(&e);                          // overlay: shows what is pressed
      // gamepads are always the game's (any view, wherever the mouse is):
      // buttons reach it like keys, "pad a", "pad dpup"... (as the overlay
      // names them); the left stick as keys too, "pad left" / "right" / "up" /
      // "down" (past half way), and the triggers, "pad lt" / "pad rt".
      // (Analog values: no game API for them yet.)
      if (e.type == SDL_EVENT_GAMEPAD_BUTTON_DOWN || e.type == SDL_EVENT_GAMEPAD_BUTTON_UP ||
          e.type == SDL_EVENT_GAMEPAD_AXIS_MOTION) {
        SDL_JoystickID which = e.type == SDL_EVENT_GAMEPAD_AXIS_MOTION ? e.gaxis.which : e.gbutton.which;
        int pads = 0, pad = 0;                     // pad N is player N (one player: every pad is theirs)
        SDL_JoystickID *ids = SDL_GetGamepads(&pads);
        for (int i = 0; ids && i < pads; i++) if (ids[i] == which) pad = i;
        SDL_free(ids);
        int pl = players_now(&V) == 1 ? 1 : pad + 1;   // (out of the game: nobody's)
        if (e.type != SDL_EVENT_GAMEPAD_AXIS_MOTION) {
          char pn[64];
          SDL_snprintf(pn, sizeof pn, "pad %s", SDL_GetGamepadStringForButton((SDL_GamepadButton)e.gbutton.button));
          if (!V.stopped) game_key_to(&V, pl, pn, e.type == SDL_EVENT_GAMEPAD_BUTTON_DOWN);
          continue;
        }
        if (a_ok(e.gaxis.axis) && (pad & 7) < 4) {   // (the analog value too: w.pads)
          float f = e.gaxis.value / 32767.f;
          g_pad_axis[pad & 3][e.gaxis.axis] = f < -1 ? -1 : f > 1 ? 1 : f;
        }
        static unsigned char held[8];              // per pad: bits left, right, up, down, lt, rt
        static const char *names[6] = { "pad left", "pad right", "pad up", "pad down", "pad lt", "pad rt" };
        int a = e.gaxis.axis, v = e.gaxis.value, p8 = pad & 7, lo = -1, hi = -1;
        if (a == SDL_GAMEPAD_AXIS_LEFTX) lo = 0, hi = 1;
        else if (a == SDL_GAMEPAD_AXIS_LEFTY) lo = 2, hi = 3;
        else if (a == SDL_GAMEPAD_AXIS_LEFT_TRIGGER) hi = 4;
        else if (a == SDL_GAMEPAD_AXIS_RIGHT_TRIGGER) hi = 5;
        for (int k = 0; k < 2; k++) {
          int bit = k ? hi : lo;
          if (bit < 0) continue;
          bool was = held[p8] >> bit & 1, on = k ? v > (was ? 12000 : 16000) : v < -(was ? 12000 : 16000);   // (a little hysteresis)
          if (on == was) continue;
          held[p8] ^= (unsigned char)(1 << bit);
          if (!V.stopped) game_key_to(&V, pl, names[bit], on);
        }
        continue;
      }
      // a release goes where its press went: a button pressed into the editor
      // is released there, wherever the mouse is now and whatever the view
      // (else lite keeps it held: e.g. a graph panning with no button down).
      // Any release ends a camera drag (its press may have gone to the game
      // in another view).
      if (e.type == SDL_EVENT_MOUSE_BUTTON_UP && (g_game_buttons & SDL_BUTTON_MASK(e.button.button))) {
        g_game_buttons &= ~SDL_BUTTON_MASK(e.button.button);   // (the game had it: its release is the game's)
        dragging = false;
        continue;
      }
      if (e.type == SDL_EVENT_MOUSE_BUTTON_UP) {
        dragging = false;
        Uint32 bit = SDL_BUTTON_MASK(e.button.button);
        if (ed && (ed_held & bit)) {
          ed_held &= ~bit;
          if (e.button.button == swallow_up) swallow_up = 0;
          editor_event(&e);
          continue;
        }
      }

      // standalone: no dev UI at all. Every key goes to the game (ESC too);
      // the window's close button quits.
      if (V.standalone) {
        if (e.type == SDL_EVENT_QUIT) running = false;
        else if (e.type == SDL_EVENT_WINDOW_DISPLAY_CHANGED) update_fps_limit(win);
        else if (down && g_game_mouse) g_game_buttons |= SDL_BUTTON_MASK(e.button.button);
        else if ((e.type == SDL_EVENT_KEY_DOWN || e.type == SDL_EVENT_KEY_UP) && !e.key.repeat)
          send_key(&V, e.key.key, e.type == SDL_EVENT_KEY_DOWN);
        continue;
      }
      Bar cb_ = bar_layout(w, h);
      (void)cb_;
      if (down && con.focus && !in_rect(&cb_.con, mx, my))
        con_focus(win, false, edfocus);              // click elsewhere: leave the console

      // the tab's right edge: drag it sideways (the tab wider / narrower; its
      // width is saved in .preferences.lua: tab_width)
      if (edge_drag && e.type == SDL_EVENT_MOUSE_MOTION) {
        V.tab_w = g_tab_w = tab_width_fit((int)SDL_lroundf(mx), w);
        continue;
      }
      if (edge_drag && e.type == SDL_EVENT_MOUSE_BUTTON_UP && e.button.button == SDL_BUTTON_LEFT) {
        edge_drag = false;
        g_edge_hot = tab_edge_at(h - BAR_H, mx, my, V.tab_w);
        SDL_SetWindowMinimumSize(win, V.tab_w + 360, 160 + BAR_H);
        g_settings.tab_width = V.tab_w;
        if (editor_running()) settings_save();
        continue;
      }
      if (down && e.button.button == SDL_BUTTON_LEFT && e.button.clicks == 2 && tab_edge_at(h - BAR_H, mx, my, V.tab_w)) {
        V.tab_w = g_tab_w = tab_width_fit(216, w);   // a double-click: its default width again
        SDL_SetWindowMinimumSize(win, V.tab_w + 360, 160 + BAR_H);
        g_settings.tab_width = SET_NONE;
        if (editor_running()) settings_save();
        continue;
      }
      if (down && e.button.button == SDL_BUTTON_LEFT && tab_edge_at(h - BAR_H, mx, my, V.tab_w)) {
        edge_drag = g_edge_hot = true;
        continue;
      }
      // an inspect click moves focus to the editor: keep its release from
      // reaching lite (a stray right-release would open lite's context menu)
      if (e.type == SDL_EVENT_MOUSE_BUTTON_UP && e.button.button == swallow_up) {
        clicklog_add(&raw, &e, "swallowed (release of an inspect click)");
        swallow_up = 0;
        dragging = false;
        bar_drag = false;
        continue;
      }

      // status bar (bottom, full width): ours in any mode
      if (bar_drag && e.type == SDL_EVENT_MOUSE_MOTION) {
        seek(&V, bar_time_at(&V, w, h, mx));
        continue;
      }
      if (e.type == SDL_EVENT_MOUSE_MOTION) {       // hand over clickable bar parts
        static SDL_Cursor *hand, *arrow;
        Bar b = bar_layout(w, h);
        static SDL_Cursor *ibeam, *ew, *ns;
        static int over = 0;                       // 0 arrow, 1 hand, 2 text, 5 the tab's right edge
        int now_over = 0;
        // a hand only over things a click would do something on
        int bh = bar_button_at(&b, mx, my);
        g_edge_hot = tab_edge_at(h - BAR_H, mx, my, V.tab_w);
        if (g_edge_hot) now_over = 5;
        else if (bh >= 0) now_over = button_enabled(&V, bh) ? 1 : 0;
        else if (my >= h - BAR_H)
          now_over = in_rect(&b.con, mx, my) ? 2 :
            (!V.stopped && mx >= b.track.x && mx < b.track.x + b.track.w) ? 1 : 0;
        if (!(mx < V.tab_w && my > TOOLS_H)) g_tree_hover[0] = 0;   // (the tree's row hovered: lite says, editor/side.h)
        if (!hand) { hand = SDL_CreateSystemCursor(SDL_SYSTEM_CURSOR_POINTER);
                     arrow = SDL_CreateSystemCursor(SDL_SYSTEM_CURSOR_DEFAULT);
                     ibeam = SDL_CreateSystemCursor(SDL_SYSTEM_CURSOR_TEXT);
                     ew = SDL_CreateSystemCursor(SDL_SYSTEM_CURSOR_EW_RESIZE);
                     ns = SDL_CreateSystemCursor(SDL_SYSTEM_CURSOR_NS_RESIZE); }
        // Over our own UI (tab, toolbar, bar) the cursor is ours, every time
        // (lite sets its own on its mouse moves; it never sees these). Over
        // the game area lite (or the game) decides; set ours only on change.
        bool our_ui = my >= h - BAR_H || (mx < V.tab_w && my <= TOOLS_H) || g_edge_hot;   // (the tab below the toolbar: lite's)
        if (our_ui || now_over != over) {
          SDL_Cursor *want = now_over == 4 ? ns : now_over == 3 || now_over == 5 ? ew : now_over == 2 ? ibeam : now_over ? hand : arrow;
          if (SDL_GetCursor() != want) SDL_SetCursor(want);
          over = now_over;
        }
        if (our_ui) continue;                      // lite only hovers inside its own area
      }
      Bar bb_ = bar_layout(w, h);
      if ((my >= h - BAR_H || bar_button_at(&bb_, mx, my) >= 0) && (down || e.type == SDL_EVENT_MOUSE_WHEEL)) {
        bool rmb = down && e.button.button == SDL_BUTTON_RIGHT;
        if (rmb && bar_button_at(&bb_, mx, my) < 0) rmb = false;   // (RMB: on the icons only)
        if ((down && e.button.button == SDL_BUTTON_LEFT) || rmb) {   // the icons take LMB and RMB alike
          Bar b = bar_layout(w, h);
          int btn = bar_button_at(&b, mx, my);
          if (btn >= 0 && button_enabled(&V, btn)) {     // disabled buttons ignore clicks
            switch (btn) {
            case BTN_PLAY:                                      // play (stopped), pause (playing), resume (paused)
              if (V.stopped) {
                if (rmb) launch_standalone(&V, win);            // play + RMB: the game alone (standalone)
                else play_start(&V);                            // play + LMB: plays
              } else V.paused = !V.paused;                      // pause / resume: LMB or RMB
              break;
            case BTN_STOP: session_stop(&V); break;
            case BTN_REW:                                       // from the start: t=0, x1, playing
              V.speed = 1;
              if (V.stopped) play_start(&V);
              else { seek(&V, 0); viewer_call(&V, "viewer_rebuild_systems", 0); V.paused = false; }
              break;
            case BTN_POWER: power_click(&V); break;             // (stopped only) on / off
            case BTN_PLAYERS: {                                 // LMB or RMB: the quarter's player in / out (the cross: nothing)
              int q = players_quarter(&b.btn[BTN_PLAYERS], mx, my);
              if (q > 1 && rmb && V.stopped && power_mode(&V, NULL, NULL, 0))   // (the switch on, stopped: hosts nearby, an address)
                lobby_menu_open(&V, q, b.btn[BTN_PLAYERS].x, b.btn[BTN_PLAYERS].y + b.btn[BTN_PLAYERS].h, b.btn[BTN_PLAYERS].y - 4);
              else if (q && power_mode(&V, NULL, NULL, 0)) players_online_click(&V, q, rmb);   // (the switch on: seats, see players.lua)
              else if (q) V.pmask ^= 1 << (q - 1);
              break;
            }                                            // (playing: they join / part now; stopped: on play)
            case BTN_NET:                                       // LMB: the next preset down (awful: local again); RMB: its menu
              if (rmb) net_menu_open(&V, b.btn[BTN_NET].x, b.btn[BTN_NET].y + b.btn[BTN_NET].h, b.btn[BTN_NET].y - 4);   // (lite draws it: menus.h)
              else players_net(&V, net_click(&V));
              break;
            case BTN_SPEED: V.speed = speed_next(&V); break;
            case BTN_SAVE: world_save(&V); break;
            case BTN_EXPORT: export_start(&V, win); break;
            case BTN_GIZMO: V.gizmos = !V.gizmos; break;
            case BTN_PICK: V.pickdbg = !V.pickdbg; break;
            case BTN_CAM: V.camx = V.camy = 0; V.zoom = 1; break;
            case BTN_MENU:                                      // the main menu (menus.h: lite draws it)
              main_menu_open(&V, b.btn[BTN_MENU].x + b.btn[BTN_MENU].w, b.btn[BTN_MENU].y + b.btn[BTN_MENU].h + 2);
              break;
            case BTN_FADE: {                                    // the game's opacity over the editor, this state:
              float *f = fade_now(&V);                          // 0% editor -> 75% mixed -> 100% game -> 0% (from
              *f = *f < 0.749f ? 0.75f : *f < 0.999f ? 1.f : 0.f;   //  anything else: the next one up)
              V.fade = *f;
            }
              dragging = false;
              break;
            }
          }
          else if (in_rect(&b.con, mx, my)) {      // console: focus, caret under the mouse (lite: a drag selects)
            con_focus(win, true, edfocus);
            if (con_lite) {
              editor_prompt("mouse", "pressed", mx, my, (float)e.button.clicks);
              con_drag = true;
            } else {
              int c = con.e.view + (int)((mx - (b.con.x + 18) + 4) / 8);
              con.e.cur = c < 0 ? 0 : c > con.e.len ? con.e.len : c;
              while (con.e.cur > 0 && utf8_cont(con.e.s[con.e.cur])) con.e.cur--;
            }
          }
          else if (!V.stopped && mx >= b.track.x - 4 && mx < b.track.x + b.track.w + 4) {
            V.paused = true;                       // scrubbing: look at the blended state
            bar_drag = true;
            seek(&V, bar_time_at(&V, w, h, mx));
          }
          clicklog_add(&raw, &e, "status bar");
        }
        if (e.type == SDL_EVENT_MOUSE_WHEEL) {     // wheel over the fade button: finer steps
          Bar b = bar_layout(w, h);
          int wb = bar_button_at(&b, mx, my);
          if (wb == BTN_FADE && e.wheel.y != 0) {   // 5% a notch, 0% .. 100%
            float *f = fade_now(&V);
            *f = SDL_roundf(*f * 20 + (e.wheel.y > 0 ? 1 : -1)) / 20;
            *f = *f < 0 ? 0 : *f > 1 ? 1 : *f;
            V.fade = *f;
          } else if (wb == BTN_NET && e.wheel.y != 0) {
            players_net(&V, net_wheel(&V, e.wheel.y));   // 1% a notch, 0% (awful) .. 100% (local: no network)
          } else if (wb == BTN_SPEED && e.wheel.y != 0) {
            V.speed = speed_wheel(&V, e.wheel.y);  // fine speed: x0.01 .. x4.00
          }
          if ((wb == BTN_FADE || wb == BTN_NET || wb == BTN_SPEED) && e.wheel.y != 0)
            mouse_still = SDL_GetTicks() - TIP_DELAY_MS;   // the tooltip shows at once while wheeling: the value changing
        }
        if (down) swallow_up = e.button.button;
        dragging = false;
        continue;
      }

      // the tab (its toolbar's gaps; below it: lite's, above): nothing else's
      if (in_tab && (down || e.type == SDL_EVENT_MOUSE_WHEEL)) {
        if (down) clicklog_add(&raw, &e, "tree tab");
        dragging = false;
        continue;
      }
      // right-click in the game area is ours in the game view: RMB = the
      // instance under the mouse, Alt+RMB = the class/asset part it is drawn
      // from, a miss deselects. Mixed and editor views: the mouse is the
      // editor's (lite's menus, panning).
      bool rmb_lite = ed && edfocus;
      if (!rmb_lite && e.type == SDL_EVENT_MOUSE_BUTTON_UP && e.button.button == SDL_BUTTON_RIGHT) continue;
      if (!rmb_lite && down && e.button.button == SDL_BUTTON_RIGHT) {
        bool alt = (SDL_GetModState() & SDL_KMOD_ALT) != 0 || alt_pending > 0;
        if (alt_pending > 0) alt_pending--;
        const Pick *k = pick_at(mx - gv.x, my - gv.y);
        const char *target = !k ? NULL : (!alt && k->via[0]) ? k->via : k->path;
        char note[300] = { 0 };
        if (k && k->via[0])
          SDL_snprintf(note, sizeof note, alt ? " (class part, via %s)" : " (instance of %s)",
                       alt ? k->via : k->cls);
        char why[400];
        SDL_snprintf(why, sizeof why, "%s%s %s (%d picks)", alt ? "ALT " : "",
                     k ? "PICK" : "miss", target ? target : "-> deselect", npicks);
        clicklog_add(&raw, &e, why);
        if (k) inspect(&V, target, note, &edfocus);
        else { sel_clear(&V); V.info[0] = 0; }
        swallow_up = SDL_BUTTON_RIGHT;
        dragging = false;
        continue;
      }

      // console (opened by clicking it): while it has focus it gets the
      // whole keyboard; ESC or a click elsewhere leaves it
      bool iskey = e.type == SDL_EVENT_KEY_DOWN || e.type == SDL_EVENT_KEY_UP;
      if (con.focus && (iskey || e.type == SDL_EVENT_TEXT_INPUT || e.type == SDL_EVENT_TEXT_EDITING)) {
        con_event(&V, win, &e, edfocus);
        continue;
      }

      // ESC, in any mode: short press = stop playing (nothing in the editor), long
      // press (>= 0.5 s) = a regular ESC for the game (sent when the 0.5 s
      // is reached, see below). ESC never quits and never reaches lite.
      if ((e.type == SDL_EVENT_KEY_DOWN || e.type == SDL_EVENT_KEY_UP) && e.key.key == SDLK_ESCAPE) {
        if (e.type == SDL_EVENT_KEY_DOWN && !e.key.repeat) { esc_t0 = SDL_GetTicksNS(); esc_long = false; }
        if (e.type == SDL_EVENT_KEY_UP && esc_t0) {
          if (esc_long) game_key(&V, "escape", false);
          else if (ed && !V.stopped) { session_stop(&V); dragging = false; }   // running: stop (the editor shows)
          esc_t0 = 0;
        }
        continue;
      }

      if (e.type == SDL_EVENT_WINDOW_DISPLAY_CHANGED) update_fps_limit(win);
      // window events always reach the editor (expose, focus...; size is ours)
      if (ed && ((e.type >= SDL_EVENT_WINDOW_FIRST && e.type <= SDL_EVENT_WINDOW_LAST) ||
                 e.type == SDL_EVENT_DROP_FILE)) {
        editor_event(&e);
        continue;
      }
      // closing: the world's unsaved edits first (the save icon yellow), then
      // lite asks about its unsaved files (it calls back when done). Both ask
      // only with the menu's "Confirm close" on
      if (e.type == SDL_EVENT_QUIT) {
        if (!quit_world_ok(&V, win)) continue;     // (Cancel: still running)
        if (ed) editor_event(&e); else running = false;
        continue;
      }
      if (g_broken && iskey && e.type == SDL_EVENT_KEY_DOWN && !e.key.repeat &&   // stopped at a breakpoint:
          (e.key.key == SDLK_F5 || e.key.key == SDLK_F10 || e.key.key == SDLK_F11)) {   // F5 / F10 / F11 in any view
        bool sh = (SDL_GetModState() & SDL_KMOD_SHIFT) != 0;
        probe_break_step(e.key.key == SDLK_F5 ? "continue" : e.key.key == SDLK_F10 ? "over" : sh ? "out" : "in");
        continue;                                  // (not the game's, not lite's: the same step once)
      }
      if ((e.type == SDL_EVENT_KEY_DOWN || e.type == SDL_EVENT_KEY_UP) && e.key.key == SDLK_F1 && !V.standalone && editor_running()) {
        if (e.type == SDL_EVENT_KEY_DOWN && !e.key.repeat) help_open(&V);   // F1: how to use it (docs/HELP.md), in any view
        continue;                                  // (its release too: never the game's)
      }
      if (e.type == SDL_EVENT_KEY_DOWN && e.key.key == SDLK_Z && (e.key.mod & SDL_KMOD_CTRL) &&
          !V.standalone && !g_side_focus &&
          (mx < V.tab_w || (!(ed && edfocus) && (V.stopped || V.paused)))) {   // CTRL+Z over the tree / props, or the game view while not playing: the last change undone
        tree_undo(&V);
        continue;
      }
      if (ed && edfocus) {                         // mixed / editor view: mouse and keys are the editor's
        if (isbtn) clicklog_add(&raw, &e, "editor has focus");
        if (down) ed_held |= SDL_BUTTON_MASK(e.button.button);
        editor_event(&e);
        continue;
      }
      if (isbtn && !(down && e.button.button == SDL_BUTTON_RIGHT)) clicklog_add(&raw, &e, "game");

      if (iskey && !e.key.repeat && !V.stopped)    // every key goes to the game too (stopped: the authored world, no)
        send_key(&V, e.key.key, e.type == SDL_EVENT_KEY_DOWN);
      switch (e.type) {                            // game area mouse: pan / zoom the camera
      case SDL_EVENT_MOUSE_BUTTON_DOWN:
        if (g_game_mouse && !V.stopped && !V.paused && e.button.button != SDL_BUTTON_RIGHT &&
            mx >= gv.x && my >= gv.y && mx < gv.x + gv.w && my < gv.y + gv.h) {
          g_game_buttons |= SDL_BUTTON_MASK(e.button.button);   // (a game that wants the mouse: its button, no camera drag)
          break;
        }
        if (e.button.button == SDL_BUTTON_RIGHT) {  // no editor and nothing hit: deselect
          sel_clear(&V); V.info[0] = 0;
        } else if (e.button.button == SDL_BUTTON_LEFT && move_start(&V, mx - gv.x, my - gv.y, gv.x, gv.y)) {
          dragging = false;                        // (on a node, not playing: moving it)
        } else {
          dragging = true;
        }
        break;
      case SDL_EVENT_MOUSE_BUTTON_UP:
        if (nmove.on && e.button.button == SDL_BUTTON_LEFT) move_finish(&V);
        dragging = false;
        break;
      case SDL_EVENT_MOUSE_MOTION:
        if (nmove.on) { move_drag(&V, e.motion.x, e.motion.y, e.motion.xrel, e.motion.yrel, V.zoom * g_vp_fit); break; }
        if (dragging && !(e.motion.state & ~SDL_BUTTON_RMASK)) dragging = false;   // (no button held after all)
        if (dragging) { V.camx -= e.motion.xrel / (V.zoom * g_vp_fit); V.camy -= e.motion.yrel / (V.zoom * g_vp_fit); }
        break;
      case SDL_EVENT_MOUSE_WHEEL:
        if (nmove.on) { if (e.wheel.y != 0) { move_call(&V, "viewer_move_by", 4, 0, 0, 0, e.wheel.y > 0 ? 1.1 : 1 / 1.1); nmove.moved = true; } break; }   // (dragging a node: its scale)
        V.zoom *= e.wheel.y > 0 ? 1.1f : 1 / 1.1f;
        break;
      }
    }

    // layout: tab on the left, game area = the rest of the window
    out_size(V.ren, &w, &h);
    SDL_FRect nv = { (float)V.tab_w, 0, (float)(w - V.tab_w), (float)(h - BAR_H) };
    if (nv.w < 1) nv.w = 1;
    editor_viewport((int)nv.x, (int)nv.y, (int)nv.w, (int)nv.h, w, h);   // (lite: views in the game area, popups anywhere in the window)
    editor_pane_shown(edfocus);                    // (playing: the game covers lite's views; its menus show alone)
    if (!V.standalone) editor_side(0, TOOLS_H + 1, (float)V.tab_w - 3, (float)(h - BAR_H) - TOOLS_H - 1);   // (the tab: lite's, under the toolbar)
    gv = nv;
    int vw = (int)gv.w, vh = (int)gv.h;

    // ESC held long enough: it's the game's ESC now
    if (esc_t0 && !esc_long && SDL_GetTicksNS() - esc_t0 >= 500000000ull) {
      esc_long = true;
      game_key(&V, "escape", true);
    }

    // P overlay: watch the right button at the OS level too. A change the
    // OS sees with no matching SDL event above means SDL dropped the click
    // (e.g. it believes the button is still held down).
    if (V.pickdbg) {
      static bool os_r = false;
      float gx, gy;
      bool now_r = (SDL_GetGlobalMouseState(&gx, &gy) & SDL_BUTTON_RMASK) != 0;
      if (now_r != os_r) {
        char l[160];
        SDL_snprintf(l, sizeof l, "OS: R %s   sdl thinks R %s   window focus %s",
                     now_r ? "dn" : "up",
                     (SDL_GetMouseState(NULL, NULL) & SDL_BUTTON_RMASK) ? "held" : "free",
                     (SDL_GetWindowFlags(win) & SDL_WINDOW_INPUT_FOCUS) ? "yes" : "NO");
        clicklog_text(l);
        os_r = now_r;
      }
    }

    pf_mark(PF_EVENTS);
    editor_frame();
    lobby_menu_poll(&V);                           // (the lobby menu: shown again when its scan is done)
    if (edge_drag || g_edge_hot) {                 // the tab's edge: its cursor (lite may have set its own this frame)
      static SDL_Cursor *ew_c;
      if (!ew_c) ew_c = SDL_CreateSystemCursor(SDL_SYSTEM_CURSOR_EW_RESIZE);
      if (ew_c && SDL_GetCursor() != ew_c) SDL_SetCursor(ew_c);
    }
    if (g_side_focus && !SDL_TextInputActive(win)) SDL_StartTextInput(win);   // (typing into the tab: text events on, whatever turned them off)
    {
      SDL_FRect ovr[16];
      g_menu_open = editor_overlays(ovr, 16) > 0 && editor_menu_modal();  // (lite's popups: they take the mouse and keys, above)
    }
    {                                              // lite failed in a frame (a view's draw...): to the log and .log.txt, once each
      static int seen;
      if (editor_error_seq() != seen) { seen = editor_error_seq(); ov_log_at(OV_ERROR, NULL, editor_error()); }   // (whole: its traceback too)
    }
    pf_mark(PF_LITE);
    if (editor_wants_quit()) running = false;
    if (g_want_help) { g_want_help = false; help_open(&V); }   // the main menu's Help
    if (g_want_reset) {                            // the main menu's Reset editor: asked, done, gone
      g_want_reset = false;
      if (reset_defaults(win)) { running = false; g_from_picker = false; }   // (it starts us again itself)
    }

    Uint64 now = SDL_GetTicksNS();
    double dt = (now - last) / 1e9, real_dt = dt;
    {                                              // an introducer (nat.lua) answers in real time, playing or not
      int top = lua_gettop(L);
      lua_getglobal(L, "viewer_introducer_tick");
      if (lua_isfunction(L, -1)) { lua_pushnumber(L, real_dt); if (lua_pcall(L, 1, 0, 0) != 0) ov_log(OV_ERROR, "introducer: %s", lua_tostring(L, -1)); }
      lua_settop(L, top);
    }
    if (shot) dt = 1.0 / 60;                       // deterministic screenshots
    if (dt > 0.1) dt = 0.1;
    last = now;
    reload_t += dt;
    pf_mark(PF_EVENTS);
    if (reload_t > 0.5) { reload_t = 0; check_reload(&V); }
    pf_mark(PF_POLL);
    {                                              // unsaved edits? (save button turns yellow)
      static Uint64 dirty_t;
      static char sel_sig[300];                    // selection changed: check it now
      char sig[300];
      SDL_snprintf(sig, sizeof sig, "%s|%d|%s", V.selected, nsel_more, nsel_more ? sel_more[nsel_more - 1] : "");
      bool sel_changed = strcmp(sig, sel_sig) != 0;
      if (sel_changed) SDL_strlcpy(sel_sig, sig, sizeof sel_sig);
      if ((V.stopped ? V.savable : !V.standalone) && (sel_changed || SDL_GetTicks() - dirty_t >= 150)) {
        dirty_t = SDL_GetTicks();
        world_status(&V);
      }
    }
    pf_mark(PF_STATUS);
    game_input(&V, mx, my, gv, edfocus, win);
    tick_world(&V, dt, real_dt);
    if (g_probe_step) {                            // paused, a graph opened on a file this frame didn't record:
      g_probe_step = false;                        // run one frame more (not after a seek: that would cut the timeline)
      if (V.paused && !V.stopped && !V.seeked && !g_broken) { V.paused = false; tick_world(&V, 1.0 / 60, 1.0 / 60); V.paused = true; }
    }

    pf_mark(PF_TICK);
    // lite is only visible while editing; while playing the game area is
    // exactly what the game draws, on its own opaque background
    SDL_Texture *bg = edfocus ? editor_texture() : NULL;

    // game layer (game-area sized): transparent where nothing is drawn
    if (!layer || layer_w != vw || layer_h != vh) {
      if (layer) SDL_DestroyTexture(layer);
      layer = SDL_CreateTexture(V.ren, SDL_PIXELFORMAT_RGBA8888, SDL_TEXTUREACCESS_TARGET,   // (at the display's pixels: retina)
                                (int)SDL_ceilf(vw * g_retina), (int)SDL_ceilf(vh * g_retina));
      SDL_SetTextureBlendMode(layer, SDL_BLENDMODE_BLEND);
      layer_w = vw, layer_h = vh;
    }
    SDL_SetRenderTarget(V.ren, layer);
    SDL_SetRenderScale(V.ren, g_retina, g_retina);  // (a target has its own scale: drawn in points, at the display's pixels)
    if (bg) SDL_SetRenderDrawColor(V.ren, 0, 0, 0, 0);
    else SDL_SetRenderDrawColor(V.ren, 18, 20, 28, 255);
    SDL_RenderClear(V.ren);

    V.drawn = 0;
    npicks = 0;
    nsegs = 0;
    nppts = 0;                                     // bounds shapes are rebuilt every frame
    npolys = 0;
    players_sync(&V);                              // the Players button: join / part now
    g_nvp = vp_layout(players_now(&V), (float)vw, (float)vh, g_vp, g_vp_who);
    g_vp_fit = SDL_min(g_vp[0].w / vw, g_vp[0].h / vh);   // every view shows what the whole area would, smaller
    int hostv = -1;                                // the host's view (player 1's, or the server's): none when player 1 is out
    for (int i = 0; i < g_nvp; i++) if (g_vp_who[i] == 0 || g_vp_who[i] == 1) hostv = i;
    if (V.world != LUA_NOREF) {
      float z = V.zoom * g_vp_fit;
      for (int j = 0; j < g_nvp; j++) {            // the host's view last: its picks stay
        int i = hostv < 0 ? j : (j + hostv + 1) % g_nvp;
        if (g_vp_who[i] < 0) continue;
        SDL_FRect *vr = &g_vp[i];
        Mat cam = { z, 0, 0, z, vr->x + vr->w / 2.f - V.camx * z, vr->y + vr->h / 2.f - V.camy * z };
        if (g_nvp > 1) { SDL_Rect clip = { (int)vr->x, (int)vr->y, (int)vr->w, (int)vr->h }; SDL_SetRenderClipRect(V.ren, &clip); }
        if (i != hostv) { draw_peer(&V, g_vp_who[i], cam); draw_ghost(&V, g_vp_who[i], cam); continue; }
        Col white = { 220, 220, 220, 255 };
        lua_rawgeti(L, LUA_REGISTRYINDEX, V.world);
        lua_getfield(L, -1, "root");
        draw_layers(&V, -1, cam, white);
        lua_pop(L, 2);
        draw_ghost(&V, g_vp_who[i], cam);           // (faint: what the owners sent last of what it predicts)
        draw_selection(&V);
        draw_tree_hover(&V);                         // (a tree item hovered: what it draws, teal)
        if (V.pickdbg) draw_pick_debug(&V, mx - gv.x, my - gv.y);
      }
      SDL_SetRenderClipRect(V.ren, NULL);
      draw_views(&V, !edfocus);
    }
    ov_world = hostv < 0 ? (SDL_FRect){ 0, 0, -1, -1 } : g_nvp > 1 ? g_vp[hostv] : (SDL_FRect){ 0, 0, 0, 0 };   // debugdraw: the host's view

    pf_mark(PF_GAME);
    view_rules(&V, &edfocus, &was_stopped);        // events may have played / stopped / opened a file
    // compose: the game (and its overlay: selection, gizmos) behind, lite on
    // top. lite's backgrounds take their alpha from the fade (mixed: 1 - fade,
    // editor: opaque, no game); its text and selection stay opaque
    SDL_SetRenderTarget(V.ren, NULL);
    SDL_SetRenderDrawColor(V.ren, 18, 20, 28, 255);
    SDL_RenderClear(V.ren);
    if (!bg || V.edmode != 2) {
      SDL_SetTextureAlphaModFloat(layer, 1.f);
      SDL_RenderTexture(V.ren, layer, NULL, &gv);
    }
    if (bg) {
      static float bg_alpha = -1;
      float a = V.edmode == 2 ? 1.f : 1.f - V.fade;
      a = (int)(a * 100 + 0.5f) / 100.f;             // (steps of 1%: lite redraws on a change)
      if (a != bg_alpha) {
        char code[64];
        SDL_snprintf(code, sizeof code, "lite_set_bg_alpha(%.2f)", a);
        editor_exec(code);
        bg_alpha = a;
      }
      SDL_FRect src = { gv.x * g_retina, gv.y * g_retina, gv.w * g_retina, gv.h * g_retina };   // (lite's surface is the whole window: its pane)
      SDL_RenderTexture(V.ren, bg, &src, &gv);
    }

    pf_mark(PF_BLIT);
    fps_n++;
    if (now - fps_t >= 1000000000ull) { fps = fps_n; fps_n = 0; fps_t = now; }

    // overlay (dev UI only): debugdraw, then stats / messages / input text.
    // Messages: info is an event (consumed); err and code_err are states,
    // logged when they change, so a lasting problem fades instead of nagging.
    V.editing = edfocus;                           // for the toolbar (fade button state)
    if (!V.standalone) {
      // every message also goes to lite's log (its Log tab, opened now or
      // later, has them all; the status bar shows the last) and to .log.txt
      ov.forward = editor_running() ? editor_log : NULL;
      static char last_err[512], last_code[512];
      lua_getglobal(V.L, "viewer_select");        // ... or a node to select (a new class)
      if (lua_isstring(V.L, -1)) {
        sel_clear(&V);
        SDL_strlcpy(V.selected, lua_tostring(V.L, -1), sizeof V.selected);
        V.reveal = true;
        lua_pushnil(V.L); lua_setglobal(V.L, "viewer_select");
      }
      lua_pop(V.L, 1);
      lua_getglobal(V.L, "viewer_open");          // ... or a file to open in the editor (a new asset: its plugin's tab)
      if (lua_isstring(V.L, -1)) {
        if (editor_running()) editor_open(lua_tostring(V.L, -1), 1);
        lua_pushnil(V.L); lua_setglobal(V.L, "viewer_open");
      }
      lua_pop(V.L, 1);
      lua_getglobal(V.L, "viewer_note");          // the viewer's Lua has something to say (a class upgraded its nodes)
      if (lua_isstring(V.L, -1)) {
        SDL_strlcpy(V.info, lua_tostring(V.L, -1), sizeof V.info);
        lua_pushnil(V.L); lua_setglobal(V.L, "viewer_note");
      }
      lua_pop(V.L, 1);
      if (V.info[0]) { ov_log(OV_INFO, "%s", V.info); V.info[0] = 0; }
      if (strcmp(V.err, last_err)) {
        if (V.err[0]) ov_log(OV_ERROR, "%s", V.err);
        SDL_strlcpy(last_err, V.err, sizeof last_err);
      }
      if (strcmp(V.code_err, last_code)) {
        if (V.code_err[0]) ov_log(OV_ERROR, "%s", V.code_err);
        SDL_strlcpy(last_code, V.code_err, sizeof last_code);
      }
      char s1[64], s2[64], s3[64], s4[64];
      if (fps_limit > 0) SDL_snprintf(s1, sizeof s1, "%d/%.0f fps  %d drawn", fps, fps_limit, V.drawn);
      else SDL_snprintf(s1, sizeof s1, "%d fps (no limit)  %d drawn", fps, V.drawn);
      if (V.pickdbg) SDL_snprintf(s2, sizeof s2, "mouse %d,%d px", (int)mx, (int)my);
      else SDL_snprintf(s2, sizeof s2, "zoom %.2f  fade %.2f", V.zoom, V.fade);
      SDL_snprintf(s3, sizeof s3, "%s  dpi %d%%", !editor_running() ? "no editor" : !edfocus ? "playing" : V.edmode == 2 ? "editor" : "mixed",
                   (int)(SDL_GetWindowDisplayScale(win) * 100 + 0.5f));
      if (V.stopped) SDL_snprintf(s4, sizeof s4, "stopped%s", V.dirty ? "  (unsaved)" : "");
      else SDL_snprintf(s4, sizeof s4, "%.1fs  x%.2f%s", V.gtime, V.speed, V.paused ? "  paused" : "");
      const char *stats[3] = { s1, s2, s3 };      // top-right; s4 goes under "frame N"
      ov.banner[0][0] = ov.banner[1][0] = 0;       // stopped at a breakpoint: said over the game too (game view)
      if (g_broken && !V.stopped) {
        const char *bw = probe_break_where();
        char file[1024] = "?"; int line = 0;
        if (bw) sscanf(bw, "%1023[^\n]\n%d", file, &line);
        const char *base = SDL_strrchr(file, '/');
        SDL_snprintf(ov.banner[0], sizeof ov.banner[0], "BREAKPOINT  %s:%d", base ? base + 1 : file, line);
        SDL_snprintf(ov.banner[1], sizeof ov.banner[1], "F5 / play: continue   F10: over   F11: into   SHIFT+F11: out");
      }
      if (!bg) ov_render(V.ren, &gv, V.zoom * g_vp_fit, V.camx, V.camy, stats, 3, V.gframe, s4);   // (frame N: the game's, it pauses and rewinds)
      pf_mark(PF_OVERLAY);

      if (editor_running()) V.logwin = editor_log_shown();   // (closing the tab in lite unchecks it)
      g_edge_drag = edge_drag;                     // (its line: drawn as dragged)
      pf_mark(PF_PANELS);
      draw_tab(&V, h - BAR_H, mx, my, !g_menu_open && SDL_GetTicks() - mouse_still >= TIP_DELAY_MS, w);   // (a menu open: no tooltips under it)
      pf_mark(PF_TAB);
      draw_bar(&V, w, h, mx, my, !g_menu_open && SDL_GetTicks() - mouse_still >= TIP_DELAY_MS);   // (a menu open: no tooltips under it)
      draw_tooltips(V.ren);                        // the tooltip asked for this frame
      {                                            // lite's popups (menus.h): their part of its surface, over all of it
        SDL_FRect ovr[16];
        int no = editor_overlays(ovr, 16);
        SDL_Texture *lt = editor_texture();
        for (int i = 0; lt && i < no; i++) {         // (lite shown: the part over its pane is there already, with the
          SDL_FRect part[4], o = ovr[i];             //  fade's alpha: only what's outside it; hidden: all of it)
          int np = 0;
          SDL_FRect in;
          if (bg && SDL_GetRectIntersectionFloat(&o, &gv, &in)) {
            if (in.y > o.y) part[np++] = (SDL_FRect){ o.x, o.y, o.w, in.y - o.y };
            if (in.y + in.h < o.y + o.h) part[np++] = (SDL_FRect){ o.x, in.y + in.h, o.w, o.y + o.h - in.y - in.h };
            if (in.x > o.x) part[np++] = (SDL_FRect){ o.x, in.y, in.x - o.x, in.h };
            if (in.x + in.w < o.x + o.w) part[np++] = (SDL_FRect){ in.x + in.w, in.y, o.x + o.w - in.x - in.w, in.h };
          } else part[np++] = o;
          for (int k = 0; k < np; k++) {
            SDL_FRect src = { part[k].x * g_retina, part[k].y * g_retina, part[k].w * g_retina, part[k].h * g_retina };
            SDL_RenderTexture(V.ren, lt, &src, &part[k]);
          }
        }
      }
    } else if (V.err[0] || V.code_err[0]) {        // standalone: report problems on stderr once
      static char last[1024];
      char cur[1024];
      SDL_snprintf(cur, sizeof cur, "%s%s%s", V.err, V.err[0] && V.code_err[0] ? " | " : "", V.code_err);
      if (strcmp(cur, last)) { fprintf(stderr, "%s\n", cur); SDL_strlcpy(last, cur, sizeof last); }
    }

    ov_end_frame();
    V.frame++;
    if (frames > 0 && V.frame >= frames) { if (shot) save_shot(&V, shot); running = false; }   // (--frames alone quits too)
    pf_mark(PF_PANELS);
    SDL_RenderPresent(V.ren);
    pf_mark(PF_PRESENT);
    pf_frame(win);

    // frame limiter: sleep precisely until the next frame is due. The
    // deadline advances by whole frame periods, so the average rate is exact;
    // if we fell behind (a slow frame), it restarts from now instead of racing.
    float lim = fps_limit_now(win, !V.standalone && !shot);   // (unfocused, minimized: the menu's)
    if (lim > 0) {
      Uint64 period = (Uint64)(1e9 / lim), t = SDL_GetTicksNS();
      frame_deadline += period;
      if (frame_deadline > t) SDL_DelayPrecise(frame_deadline - t);
      else frame_deadline = t;
    }
    pf_mark(PF_WAIT);
  }

  {                                                // leaving: online off, our ports on the router closed (portmap.lua; up to 1 s)
    static const char *bye[] = { "viewer_online_drop", "viewer_release_ports" };
    for (int i = 0; i < 2; i++) {
      lua_getglobal(L, bye[i]);
      if (lua_isfunction(L, -1)) { if (lua_pcall(L, 0, 0, 0) != LUA_OK) lua_pop(L, 1); } else lua_pop(L, 1);
    }
  }
  lua_getglobal(L, "viewer_history_forget");         // a clean quit: the tree's undo stack forgotten (a crash keeps it)
  if (lua_isfunction(L, -1)) { if (lua_pcall(L, 0, 0, 0) != LUA_OK) lua_pop(L, 1); } else lua_pop(L, 1);
  editor_shutdown();
  if (layer) SDL_DestroyTexture(layer);
  SDL_DestroyRenderer(V.ren);
  SDL_DestroyWindow(win);
  SDL_Quit();
  lua_close(L);
  SDL_free(cwd);
  if (g_from_picker && !shot && !V.standalone) relaunch(false);   // opened from the launcher: back to it
  return 0;
}
