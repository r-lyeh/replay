// probe.h - the editor's probe into the running world (part of replay.c).
//
// While a node graph of a file is shown, the editor asks (host_probe(file),
// a lite global, editor/editor.c) for what that file's code did in the frame shown:
// which lines ran, how many times, and the values of the locals there (as
// short strings). The world records it with a line hook, only while some
// file is watched (asked for in the last 5 minutes), only for the code of
// those files (systems cut from a script map back to its lines through
// ecs.chunk_origins; a folder world's leaves through viewer_leaf), a frame
// at a time, keyed by game time: the last 1500 frames, so the timeline can
// be scrubbed back over them; stopped: nothing (the flow is only shown
// while the game runs or is paused, with the editor visible: under 100%). The editor draws it: the flow wires
// that ran in orange, and values on wires.

// The line hook is C (cheap: most lines are the engine's, not watched): it
// asks Lua once per chunk whether its code is watched, and calls Lua only on
// the lines of watched code. It's on only while a system of a watched file
// runs (its fn is wrapped: probe_hook_on / probe_hook_off).
static const void *probe_src[256];               // chunk sources seen this tick, and whether watched
static unsigned char probe_hit[256];
static int probe_nsrc;
static void probe_hook(lua_State *L, lua_Debug *ar) {
  if (ar->event != LUA_HOOKLINE || !lua_getinfo(L, "S", ar) || !ar->source) return;
  const void *s = ar->source;
  int hit = -1;
  for (int i = 0; i < probe_nsrc; i++) if (probe_src[i] == s) { hit = probe_hit[i]; break; }
  if (hit < 0) {                                   // a new chunk: watched?
    lua_getglobal(L, "viewer_probe_watch");
    lua_pushstring(L, ar->source);
    hit = lua_pcall(L, 1, 1, 0) == 0 && lua_toboolean(L, -1);
    lua_pop(L, 1);
    if (probe_nsrc < 256) { probe_src[probe_nsrc] = s; probe_hit[probe_nsrc] = (unsigned char)hit; probe_nsrc++; }
  }
  if (!hit) return;
  lua_getglobal(L, "viewer_probe_line");
  lua_pushstring(L, ar->source);
  lua_pushinteger(L, ar->currentline);
  if (lua_pcall(L, 2, 1, 0) != 0) { lua_pop(L, 1); return; }
  int brk = lua_toboolean(L, -1);                  // a breakpoint on this line: the tick (a coroutine) stops here
  lua_pop(L, 1);
  if (brk && lua_isyieldable(L)) lua_yield(L, 0);  // (not yieldable, inside a C call: it runs on)
}
static int l_probe_on(lua_State *L) { lua_sethook(L, probe_hook, LUA_MASKLINE, 0); return 0; }
static int l_probe_off(lua_State *L) { lua_sethook(L, NULL, 0, 0); return 0; }
static int l_probe_reset(lua_State *L) { (void)L; probe_nsrc = 0; return 0; }
static int l_probe_now(lua_State *L) {             // a high-resolution clock, in seconds (the profiler's)
  lua_pushnumber(L, (double)SDL_GetPerformanceCounter() / (double)SDL_GetPerformanceFrequency());
  return 1;
}


static Viewer *g_probe_viewer;
static bool g_broken;                             // a tick stopped at a breakpoint (the game paused mid-frame)
static double g_break_dt;                         // (its dt: the rest of it runs on Continue)
static bool g_probe_step;                         // paused, and a graph asked for a file the frame shown didn't record
static char *g_probe_buf;
static size_t g_probe_cap;

// lite asks: the record of `file` at the game time shown (Lua source text: "return {...}")
static const char *probe_get(const char *file) {
  Viewer *V = g_probe_viewer;
  if (!V || !V->L) return NULL;
  lua_State *L = V->L;
  int top = lua_gettop(L);
  const char *res = NULL;
  lua_getglobal(L, "viewer_probe_get");
  lua_pushstring(L, file);
  lua_pushnumber(L, V->gtime);
  lua_pushboolean(L, V->stopped);                  // stopped: nothing
  lua_pushboolean(L, V->editing);                  // shown: running or paused, the editor visible (the game under 100%)
  if (lua_isfunction(L, -5) && lua_pcall(L, 4, 1, 0) == 0 && lua_isstring(L, -1)) {
    size_t n = 0;
    const char *s = lua_tolstring(L, -1, &n);
    if (n + 1 > g_probe_cap) {
      g_probe_cap = n + 1 + 4096;
      g_probe_buf = (char *)SDL_realloc(g_probe_buf, g_probe_cap);
    }
    if (g_probe_buf) { SDL_memcpy(g_probe_buf, s, n + 1); res = g_probe_buf; }
  }
  lua_getglobal(L, "viewer_probe_step");           // the frame shown has nothing for it: step one
  if (lua_toboolean(L, -1)) { g_probe_step = true; lua_pushnil(L); lua_setglobal(L, "viewer_probe_step"); }
  lua_settop(L, top);
  return res;
}

// lite asks: the value of an expression of `file` at `line` in the frame shown (or NULL)
static char g_eval_buf[512];
static const char *probe_eval(const char *file, int line, const char *src) {
  Viewer *V = g_probe_viewer;
  if (!V || !V->L || V->stopped || !V->editing) return NULL;
  lua_State *L = V->L;
  int top = lua_gettop(L);
  const char *res = NULL;
  lua_getglobal(L, "viewer_probe_eval");
  lua_pushstring(L, file);
  lua_pushnumber(L, V->gtime);
  lua_pushinteger(L, line);
  lua_pushstring(L, src);
  if (lua_isfunction(L, -5) && lua_pcall(L, 4, 1, 0) == 0 && lua_isstring(L, -1)) {
    SDL_strlcpy(g_eval_buf, lua_tostring(L, -1), sizeof g_eval_buf);
    res = g_eval_buf;
  }
  lua_settop(L, top);
  return res;
}

// breakpoints, from lite: host_break_set(file, line, on) / host_break_where()
static void probe_break_set(const char *file, int line, bool on, int as, int fdef) {
  Viewer *V = g_probe_viewer;
  if (!V || !V->L) return;
  lua_getglobal(V->L, "viewer_break_set");
  lua_pushstring(V->L, file);
  lua_pushinteger(V->L, line);
  lua_pushboolean(V->L, on);
  lua_pushinteger(V->L, as);
  lua_pushinteger(V->L, fdef);
  if (lua_pcall(V->L, 5, 0, 0) != 0) lua_pop(V->L, 1);
}
static const char *probe_world_file(void) {      // the world's main file (host_world_file in lite)
  Viewer *V = g_probe_viewer;
  return V ? V->path : NULL;
}
static char g_break_buf[1100];
static const char *probe_break_where(void) {      // "file\nline\nn" (n: which stop), or NULL
  Viewer *V = g_probe_viewer;
  if (!V || !V->L || !g_broken) return NULL;
  lua_State *L = V->L;
  const char *res = NULL;
  lua_getglobal(L, "viewer_break_where");
  if (lua_pcall(L, 0, 3, 0) == 0) {
    if (lua_isstring(L, -3)) {
      SDL_snprintf(g_break_buf, sizeof g_break_buf, "%s\n%d\n%d", lua_tostring(L, -3), (int)lua_tointeger(L, -2), (int)lua_tointeger(L, -1));
      res = g_break_buf;
    }
    lua_pop(L, 3);
  } else lua_pop(L, 1);
  return res;
}
// from lite (F5 / F10 / F11 / shift+F11): go on from a stop, stepping or not
static void probe_break_step(const char *mode) {
  Viewer *V = g_probe_viewer;
  if (!V || !V->L || !g_broken) return;
  lua_getglobal(V->L, "viewer_break_step");
  lua_pushstring(V->L, mode);
  if (lua_pcall(V->L, 1, 0, 0) != 0) lua_pop(V->L, 1);
  V->paused = false;                               // (the next frame continues the stopped tick)
}
// a tick stopped at a breakpoint is dropped (stop, seek, reload: the world is replaced anyway)
static void break_abort(Viewer *V) {
  if (!g_broken || !V->L) return;
  g_broken = false;
  lua_getglobal(V->L, "viewer_tick_abort");
  if (lua_pcall(V->L, 0, 0, 0) != 0) lua_pop(V->L, 1);
}

// the profiler: a node's time (ms a tick, smoothed, with its children's); 0: none
static double prof_ms(Viewer *V, const char *path) {
  lua_State *L = V->L;
  double ms = 0;
  lua_getglobal(L, "viewer_prof_ms");
  lua_pushstring(L, path);
  if (lua_pcall(L, 1, 1, 0) == 0) ms = lua_tonumber(L, -1);
  lua_pop(L, 1);
  return ms;
}
static void prof_select(Viewer *V) {             // once a frame, before the tree: live, or (paused) the frame shown
  lua_State *L = V->L;
  lua_getglobal(L, "viewer_prof_select");
  lua_pushnumber(L, V->gtime);
  lua_pushboolean(L, V->paused);
  if (lua_pcall(L, 2, 0, 0) != 0) lua_pop(L, 1);
}
static void prof_reset(Viewer *V) {
  lua_getglobal(V->L, "viewer_prof_reset");
  if (lua_pcall(V->L, 0, 0, 0) != 0) lua_pop(V->L, 1);
}

// after a tick: keep what it recorded, at its game time (and the profiler's)
static void probe_commit(Viewer *V) {
  lua_State *L = V->L;
  lua_getglobal(L, "viewer_prof_commit");
  lua_pushnumber(L, V->gtime);
  if (lua_pcall(L, 1, 0, 0) != 0) lua_pop(L, 1);
  lua_getglobal(L, "viewer_probe_commit");
  if (!lua_isfunction(L, -1)) { lua_pop(L, 1); return; }
  lua_pushnumber(L, V->gtime);
  if (lua_pcall(L, 1, 0, 0) != 0) lua_pop(L, 1);
}

// once the viewer's own Lua is in (after runtime/boot.lua: runtime/probe.lua)
static void probe_init(Viewer *V) {
  g_probe_viewer = V;
  lua_register(V->L, "probe_hook_on", l_probe_on);
  lua_register(V->L, "probe_hook_off", l_probe_off);
  lua_register(V->L, "probe_hook_reset", l_probe_reset);
  lua_register(V->L, "probe_now", l_probe_now);
  lua_pushboolean(V->L, V->standalone);            // (standalone: no profiler)
  lua_setglobal(V->L, "viewer_standalone");
  char err[2048];                                  // (its Lua: runtime/probe.lua)
  if (!runtime_run(V->L, "probe", err, sizeof err)) fprintf(stderr, "probe: %s\n", err);
}
