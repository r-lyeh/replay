// editor/boot.h - loads the viewer's Lua side from runtime/: boot.lua
// (loading, ticking, timeline, tree and props, save, plugins, assets), then
// probe.lua and players.lua (editor/probe.h, editor/players.h).
// Part of replay.c: included once, in order, from there (one compilation unit).
//
// It's found like the modules (ecs.lua, disk.lua...): runtime/ in the cwd,
// else next to the exe. Export ships it with them, so a packaged game has it.

static char runtime_roots[2][1100];                // where runtime/ is looked for: the cwd, then next to the exe

// run runtime/<name>.lua in L -> true; false: err says why
static bool runtime_run(lua_State *L, const char *name, char *err, size_t size) {
  char file[1200];
  file[0] = 0;
  for (int i = 0; i < 2 && !file[0]; i++) {
    SDL_snprintf(file, sizeof file, "%sruntime/%s.lua", runtime_roots[i], name);
    if (!SDL_GetPathInfo(file, NULL)) file[0] = 0;
  }
  if (!file[0]) {
    SDL_snprintf(err, size, "runtime/%s.lua not found (in %s or %s)", name, runtime_roots[0], runtime_roots[1]);
    return false;
  }
  if (luaL_loadfilex(L, file, "t") != LUA_OK || lua_pcall(L, 0, 0, 0) != LUA_OK) {
    SDL_snprintf(err, size, "%s", lua_tostring(L, -1));
    lua_pop(L, 1);
    return false;
  }
  return true;
}

// the viewer's Lua side: runtime/boot.lua (the probe and players come later: runtime_run)
static bool boot_load(lua_State *L, const char *cwd, const char *base, char *err, size_t size) {
  SDL_strlcpy(runtime_roots[0], cwd ? cwd : "./", sizeof runtime_roots[0]);
  SDL_strlcpy(runtime_roots[1], base ? base : "", sizeof runtime_roots[1]);
  return runtime_run(L, "boot", err, size);
}
