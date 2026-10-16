// settings.h - the user's settings: .preferences.lua next to the exe.
//
//   return {
//     log_window = true,       -- lite's Log tab at start
//     confirm_close = false,   -- closing a tab with unsaved changes asks first
//     fps = 0,                 -- the limit while focused: 0 the monitor's refresh, else 6, 12, 18 ... (x6)
//     fps_unfocused = 15,      -- ... while another window has the focus (0: as focused)
//     fps_minimized = 5,       -- ... while minimized (0: as focused)
//     tree_split = 50,         -- the left tab: % of its height for the tree (the rest: properties)
//     tab_width = 216,         -- the left tab's width, px (drag its right edge; --tab N wins)
//     theme = "light",         -- "dark" (lite's own, the default) or "light" (ours: themes/replay_light.lua)
//     tab_font = 15,           -- the left tab's font size, px (CTRL+wheel over it; default: lite's, 14)
//     thumbnails = 32,         -- the tree's /assets previews, px (0: off, a row each: the default)
//     retina = false,          -- a Retina / 200% display: the editor (Lite) drawn at the screen's
//                              -- own pixels, sharp (the rest as before). Default true; no effect
//                              -- where the display has no more pixels than points (Windows, most
//                              -- Linux). Read at start
//   }
//
// Loaded at start (the command line wins over it, and it wins over the
// defaults); written each time the main menu changes one, or the left
// tab's lines are dragged. Read in a Lua state of its own with no libraries:
// the file can only build a table.
//
// Later, maybe (they don't collide with multiples of 6): fps = -1 unlimited,
// 1 vsync, 2 adaptive vsync. Budgets: the most disk the log may take (MiB,
// .log.txt and its rolls), the most RAM the timeline's snapshots may take (MiB).
#pragma once

#define SET_NONE -999                              // (a setting not in the file: its default)
typedef struct {
  int log_window;                  // 1 / 0, or -1: not set
  int confirm_close;               // 1 / 0, or -1: not set (default: no)
  int fps, fps_unfocused, fps_minimized;   // SET_NONE: not set (defaults 0, 15, 5)
  int tree_split;                  // % (10..90), SET_NONE: not set (default 50)
  int tab_width;                   // px (120..4000), SET_NONE: not set (default 216)
  int theme;                       // 1 light, 0 dark, -1: not set (default dark)
  int tab_font;                    // px (8..32), SET_NONE: not set (lite's UI font as it is)
  int thumbs;                      // px (0 off, 16..96), SET_NONE: not set (default off)
  int retina;                      // 1 / 0, or -1: not set (default: yes)
} Settings;

static Settings g_settings = { -1, -1, SET_NONE, SET_NONE, SET_NONE, SET_NONE, SET_NONE, -1, SET_NONE, SET_NONE, -1 };
static char g_settings_path[1024];

static int settings_fps(void) { return g_settings.fps == SET_NONE ? 0 : g_settings.fps; }
static int settings_fps_unfocused(void) { return g_settings.fps_unfocused == SET_NONE ? 15 : g_settings.fps_unfocused; }
static int settings_fps_minimized(void) { return g_settings.fps_minimized == SET_NONE ? 5 : g_settings.fps_minimized; }
static bool settings_confirm_close(void) { return g_settings.confirm_close == 1; }
static bool settings_light(void) { return g_settings.theme == 1; }
static void settings_apply_theme(void) {           // (lite's colours: the tab and the bar follow them, ui.h)
  editor_exec(settings_light() ? "lite_theme('light')" : "lite_theme('dark')");
}
static int settings_thumbs(void) { return g_settings.thumbs == SET_NONE ? 0 : g_settings.thumbs; }
static int settings_tree_split(void) { return g_settings.tree_split == SET_NONE ? 50 : g_settings.tree_split; }

static void settings_path_init(const char *base) {
  SDL_snprintf(g_settings_path, sizeof g_settings_path, "%s.preferences.lua", base ? base : "");
}

static int settings_int(lua_State *L, const char *k, int lo, int hi) {
  int v = SET_NONE;
  lua_getfield(L, -1, k);
  if (lua_isnumber(L, -1)) {
    v = (int)lua_tointeger(L, -1);
    if (v < lo) v = lo;
    if (v > hi) v = hi;
  }
  lua_pop(L, 1);
  return v;
}

static void settings_load(void) {
  g_settings = (Settings){ -1, -1, SET_NONE, SET_NONE, SET_NONE, SET_NONE, SET_NONE, -1, SET_NONE, SET_NONE, -1 };
  lua_State *L = luaL_newstate();                  // (no libraries: data only)
  if (!L) return;
  if (luaL_loadfile(L, g_settings_path) == 0 && lua_pcall(L, 0, 1, 0) == 0 && lua_istable(L, -1)) {
    lua_getfield(L, -1, "log_window");
    if (lua_isboolean(L, -1)) g_settings.log_window = lua_toboolean(L, -1) ? 1 : 0;
    lua_pop(L, 1);
    lua_getfield(L, -1, "confirm_close");
    if (lua_isboolean(L, -1)) g_settings.confirm_close = lua_toboolean(L, -1) ? 1 : 0;
    lua_pop(L, 1);
    lua_getfield(L, -1, "retina");
    if (lua_isboolean(L, -1)) g_settings.retina = lua_toboolean(L, -1) ? 1 : 0;
    lua_pop(L, 1);
    g_settings.fps = settings_int(L, "fps", 0, 960);
    if (g_settings.fps != SET_NONE) g_settings.fps = (g_settings.fps + 3) / 6 * 6;   // (0, or a multiple of 6)
    g_settings.fps_unfocused = settings_int(L, "fps_unfocused", 0, 960);
    g_settings.fps_minimized = settings_int(L, "fps_minimized", 0, 960);
    g_settings.tree_split = settings_int(L, "tree_split", 10, 90);
    g_settings.tab_width = settings_int(L, "tab_width", 120, 4000);
    g_settings.tab_font = settings_int(L, "tab_font", 8, 32);
    g_settings.thumbs = settings_int(L, "thumbnails", 0, 96);
    lua_getfield(L, -1, "theme");
    if (lua_isstring(L, -1)) g_settings.theme = !strcmp(lua_tostring(L, -1), "light") ? 1 : 0;
    lua_pop(L, 1);
    g_ui_light = settings_light();                 // (before lite runs: the project picker's colours, ui.h)
  }
  lua_close(L);
}

static bool settings_save(void) {
  FILE *f = fopen(g_settings_path, "wb");
  if (!f) return false;
  fprintf(f, "-- .preferences.lua: play.exe's settings (saved by the main menu and the left tab's lines).\n"
             "-- The command line wins over these (--log / --no-log, --fps).\n"
             "return {\n");
  if (g_settings.log_window >= 0) fprintf(f, "  log_window = %s,\n", g_settings.log_window ? "true" : "false");
  if (g_settings.confirm_close >= 0) fprintf(f, "  confirm_close = %s,\n", g_settings.confirm_close ? "true" : "false");
  if (g_settings.fps != SET_NONE) fprintf(f, "  fps = %d,                 -- focused: 0 the monitor's, else x6\n", g_settings.fps);
  if (g_settings.fps_unfocused != SET_NONE) fprintf(f, "  fps_unfocused = %d,       -- 0: as focused\n", g_settings.fps_unfocused);
  if (g_settings.fps_minimized != SET_NONE) fprintf(f, "  fps_minimized = %d,       -- 0: as focused\n", g_settings.fps_minimized);
  if (g_settings.tree_split != SET_NONE) fprintf(f, "  tree_split = %d,          -- the left tab: %% of it for the tree (drag the line)\n", g_settings.tree_split);
  if (g_settings.tab_width != SET_NONE) fprintf(f, "  tab_width = %d,          -- the left tab's width, px (drag its right edge)\n", g_settings.tab_width);
  if (g_settings.tab_font != SET_NONE) fprintf(f, "  tab_font = %d,           -- the left tab's font size, px (CTRL+wheel over it)\n", g_settings.tab_font);
  if (g_settings.thumbs != SET_NONE) fprintf(f, "  thumbnails = %d,         -- the tree's /assets previews, px (0: off; the main menu)\n", g_settings.thumbs);
  if (g_settings.retina >= 0) fprintf(f, "  retina = %s,             -- the editor at the screen's own pixels (Retina); read at start\n", g_settings.retina ? "true" : "false");
  if (g_settings.theme >= 0) fprintf(f, "  theme = \"%s\",          -- \"dark\" or \"light\" (the main menu)\n", settings_light() ? "light" : "dark");
  fprintf(f, "}\n");
  return fclose(f) == 0;
}
