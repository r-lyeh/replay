// editor/world.h - loading/reloading, timeline seek, play/stop/save, keys to the game.
// Part of replay.c: included once, in order, from there (one compilation unit).

// ---------------------------------------------------------------------------
// loading / reloading
// ---------------------------------------------------------------------------

static bool hist_call(Viewer *V, const char *fn, int nres, bool with_time, double t);

static void code_status(Viewer *V, bool sync);
static void session_start(Viewer *V);
static void world_status(Viewer *V);
static void push_selection(lua_State *L, Viewer *V);
static int nsel_more;

static SDL_Time file_mtime(const char *path) {     // 0: no such file
  SDL_PathInfo info;
  return path[0] && SDL_GetPathInfo(path, &info) ? info.modify_time : 0;
}

static void load_world(Viewer *V) {
  lua_State *L = V->L;
  if (!V->path[0]) return;                         // (no world: an asset opened on its own)
  break_abort(V);                                  // (a tick stopped at a breakpoint: dropped)
  SDL_PathInfo info;
  if (SDL_GetPathInfo(V->path, &info)) {
    V->mtime = info.modify_time;
    V->isdir = info.type == SDL_PATHTYPE_DIRECTORY;
  }
  V->opath[0] = 0;                                 // a script's overrides file, watched too
  const char *dot = SDL_strrchr(V->path, '.');      // scene1.lua / snake.hurdy -> <stem>.overrides.lua
  if (!V->isdir && dot && (!strcmp(dot, ".lua") || !strcmp(dot, ".hurdy")))
    SDL_snprintf(V->opath, sizeof V->opath, "%.*s.overrides.lua", (int)(dot - V->path), V->path);
  V->omtime = file_mtime(V->opath);
  lua_getglobal(L, "viewer_load");
  lua_pushstring(L, V->path);
  if (lua_pcall(L, 1, 2, 0) != 0) {
    SDL_snprintf(V->err, sizeof V->err, "%s", lua_tostring(L, -1));
    lua_pop(L, 1);
    return;
  }
  if (lua_isnil(L, -2)) {                          // keep the old world
    SDL_snprintf(V->err, sizeof V->err, "%s", lua_tostring(L, -1));
    lua_pop(L, 2);
    return;
  }
  lua_pop(L, 1);
  if (V->world != LUA_NOREF) luaL_unref(L, LUA_REGISTRYINDEX, V->world);
  V->world = luaL_ref(L, LUA_REGISTRYINDEX);
  V->err[0] = 0;
  V->frame = 0;
  V->gtime = 0;                                    // a (re)loaded world starts a new timeline
  V->gframe = 0;
  V->seeked = false;
  hist_call(V, "viewer_hist_reset", 0, false, 0);
  code_status(V, true);
  world_status(V);
  if (!V->stopped) session_start(V);               // a reload while playing starts over
}

// timeline helpers (the snapshots themselves live in Lua, see runtime/boot.lua)
static bool hist_call(Viewer *V, const char *fn, int nres, bool with_time, double t) {
  lua_State *L = V->L;
  if (V->world == LUA_NOREF) return false;
  lua_getglobal(L, fn);
  lua_rawgeti(L, LUA_REGISTRYINDEX, V->world);
  if (with_time) lua_pushnumber(L, t);
  if (lua_pcall(L, with_time ? 2 : 1, nres, 0) != 0) {
    SDL_snprintf(V->err, sizeof V->err, "timeline: %s", lua_tostring(L, -1));
    lua_pop(L, 1);
    return false;
  }
  return true;
}

static void hist_info(Viewer *V, int *count, double *last) {
  lua_State *L = V->L;
  *count = 0; *last = 0;
  lua_getglobal(L, "viewer_hist_info");
  if (lua_pcall(L, 0, 2, 0) != 0) { lua_pop(L, 1); return; }
  *count = (int)lua_tointeger(L, -2);
  *last = lua_tonumber(L, -1);
  lua_pop(L, 2);
}

// jump to game time t (blending between the two nearest snapshots)
// call viewer_<fn>(world) ; returns false (and logs) on a Lua error
static bool viewer_call(Viewer *V, const char *fn, int nres) {
  lua_State *L = V->L;
  if (V->world == LUA_NOREF) return false;
  lua_getglobal(L, fn);
  lua_rawgeti(L, LUA_REGISTRYINDEX, V->world);
  if (lua_pcall(L, 1, nres, 0) != 0) {
    SDL_snprintf(V->err, sizeof V->err, "%s: %s", fn, lua_tostring(L, -1));
    lua_pop(L, 1);
    return false;
  }
  return true;
}

// can the world be saved, and does it differ from disk?
static void world_status(Viewer *V) {
  lua_State *L = V->L;
  lua_getglobal(L, "viewer_savable");
  V->savable = lua_pcall(L, 0, 1, 0) == 0 && lua_isstring(L, -1);
  V->script = V->savable && !strcmp(lua_tostring(L, -1), "overrides");
  lua_pop(L, 1);
  V->dirty = false;
  V->sel_dirty = false;
  if ((V->savable || !V->stopped) && V->selected[0] && V->world != LUA_NOREF) {
    lua_getglobal(L, "viewer_sel_dirty");
    lua_rawgeti(L, LUA_REGISTRYINDEX, V->world);
    push_selection(L, V);
    if (lua_pcall(L, 2, 1, 0) == 0) V->sel_dirty = lua_toboolean(L, -1);
    lua_pop(L, 1);
  }
  if (V->savable && V->stopped && viewer_call(V, "viewer_dirty", 1)) {
    V->dirty = lua_toboolean(L, -1);
    lua_pop(L, 1);
  }
}

// The power button on (runtime/players.lua viewer_online_begin): Play goes
// online, hosting or joining; off: nothing (local players). Again while
// online already (a reload): nothing.
static void online_begin(Viewer *V) {
  lua_State *L = V->L;
  if (V->world == LUA_NOREF) return;
  int top = lua_gettop(L);
  lua_getglobal(L, "viewer_online_begin");
  lua_rawgeti(L, LUA_REGISTRYINDEX, V->world);
  if (lua_pcall(L, 1, 2, 0) != 0) SDL_snprintf(V->err, sizeof V->err, "online: %s", lua_tostring(L, -1));
  else if (lua_isnil(L, -2)) SDL_snprintf(V->err, sizeof V->err, "online: %s", lua_tostring(L, -1));
  lua_settop(L, top);
}

// Play from stopped: remember the authored world, start a new timeline
static void session_start(Viewer *V) {
  viewer_call(V, "viewer_session_start", 0);
  online_begin(V);
  prof_reset(V);
  hist_call(V, "viewer_hist_reset", 0, false, 0);
  V->stopped = false;
  V->paused = false;
  V->gtime = 0;
  V->gframe = 0;
  V->seeked = false;
  V->fr_time = 0; V->fr_frames = 0;
}

// Play (from the edited world): the game as on disk, but the editor's unsaved
// files win over the disk (like UE): when they change what the game reads,
// the world is built again from them (viewer_play_prepare, runtime/boot.lua), the
// viewer's own edits on top; then the session starts as always
static void unsaved_one(const char *path, const char *text, size_t n, void *ud) {
  lua_State *L = (lua_State *)ud;                  // viewer_unsaved_new[key(path)] = text
  lua_getglobal(L, "viewer_unsaved_key");
  lua_pushstring(L, path);
  if (lua_pcall(L, 1, 1, 0) != 0) { lua_pop(L, 1); return; }
  lua_pushlstring(L, text, n);
  lua_settable(L, -3);
}
// Before playing: does every Lua file the game reads compile (viewer_check)?
// The first one that doesn't: logged, shown in the editor (its graph, if
// one is open, else its text, at that line), and Play doesn't start.
// why: "file:line: message" (or NULL). (Export checks too: export.h.)
static bool play_check(Viewer *V, char *why, size_t whyn) {
  lua_State *L = V->L;
  int top = lua_gettop(L);
  lua_getglobal(L, "viewer_check");
  lua_pushstring(L, V->path);
  if (lua_pcall(L, 1, 3, 0) != 0) { lua_settop(L, top); return true; }   // (the check itself failed: play anyway)
  if (lua_isnil(L, -3)) { lua_settop(L, top); return true; }
  char file[1024], msg[512], where[1100];
  SDL_strlcpy(file, lua_tostring(L, -3), sizeof file);
  int line = (int)lua_tointeger(L, -2);
  SDL_strlcpy(msg, lua_tostring(L, -1) ? lua_tostring(L, -1) : "?", sizeof msg);
  lua_settop(L, top);
  SDL_snprintf(where, sizeof where, "%s:%d", file, line);
  ov_log_at(OV_ERROR, where, msg);                 // (each press says it again: no lasting state)
  if (why) SDL_snprintf(why, whyn, "%s: %s", where, msg);
  if (editor_running()) editor_open_error(file, line, msg);
  return false;
}

static void play_start(Viewer *V) {
  lua_State *L = V->L;
  if (V->world != LUA_NOREF && editor_running()) {
    lua_newtable(L);
    editor_unsaved(unsaved_one, L);
    lua_setglobal(L, "viewer_unsaved_new");
  }
  if (!play_check(V, NULL, 0)) return;            // a file that doesn't compile: shown, not played
  if (V->world != LUA_NOREF && editor_running()) {
    lua_getglobal(L, "viewer_play_prepare");
    lua_rawgeti(L, LUA_REGISTRYINDEX, V->world);
    lua_pushstring(L, V->path);
    if (lua_pcall(L, 2, 2, 0) != 0) {
      SDL_snprintf(V->err, sizeof V->err, "play: %s", lua_tostring(L, -1));
      lua_pop(L, 1);
    } else if (lua_istable(L, -2)) {               // a new world: the unsaved files in it
      lua_pop(L, 1);
      luaL_unref(L, LUA_REGISTRYINDEX, V->world);
      V->world = luaL_ref(L, LUA_REGISTRYINDEX);
      V->frame = 0;
      code_status(V, true);
      world_status(V);
      SDL_snprintf(V->info, sizeof V->info, "play: with the editor's unsaved changes");
    } else {
      if (lua_isboolean(L, -2)) SDL_snprintf(V->err, sizeof V->err, "play (unsaved changes): %s", lua_tostring(L, -1));
      lua_pop(L, 2);
    }
  }
  session_start(V);
}

// Stop: back to the authored world (+ disk changes made while playing)
static void session_stop(Viewer *V) {
  if (V->stopped) return;
  break_abort(V);
  players_stop(V);                                 // everyone else leaves: one view again
  viewer_call(V, "viewer_session_stop", 0);
  prof_reset(V);
  V->stopped = true;
  V->paused = false;
  V->gtime = 0;
  V->gframe = 0;
  V->seeked = false;
  hist_call(V, "viewer_hist_reset", 0, false, 0);
  code_status(V, true);
  world_status(V);
  ov_clear_draws();
}

static void world_save(Viewer *V) {
  if (!V->stopped || !V->savable || V->world == LUA_NOREF) return;
  lua_State *L = V->L;
  lua_getglobal(L, "viewer_save");
  lua_rawgeti(L, LUA_REGISTRYINDEX, V->world);
  if (lua_pcall(L, 1, 2, 0) != 0) {
    ov_log(OV_ERROR, "save: %s", lua_tostring(L, -1));
    lua_pop(L, 1);
  } else {
    if (lua_toboolean(L, -2)) SDL_snprintf(V->info, sizeof V->info, "saved %s", V->script ? V->opath : V->path);
    else ov_log(OV_ERROR, "save: %s", lua_tostring(L, -1) ? lua_tostring(L, -1) : "failed");
    lua_pop(L, 2);
  }
  V->omtime = file_mtime(V->opath);                // our own write: no reload
  world_status(V);
}

// props panel Save / Undo: just the selected nodes (stopped, savable only)
static void sel_action(Viewer *V, const char *fn, const char *done) {
  bool undo = !strcmp(fn, "viewer_sel_undo");      // Undo also works while playing
  if (!V->selected[0] || V->world == LUA_NOREF) return;
  if (!undo && (!V->stopped || !V->savable)) return;
  if (undo && V->stopped && !V->savable) return;
  lua_State *L = V->L;
  lua_getglobal(L, fn);
  lua_rawgeti(L, LUA_REGISTRYINDEX, V->world);
  push_selection(L, V);
  if (lua_pcall(L, 2, 2, 0) != 0) {
    ov_log(OV_ERROR, "%s", lua_tostring(L, -1));
    lua_pop(L, 1);
  } else {
    if (lua_toboolean(L, -2)) SDL_snprintf(V->info, sizeof V->info, "%s %s%s", done, V->selected,
                                            nsel_more ? " (+ more)" : "");
    else ov_log(OV_ERROR, "%s", lua_tostring(L, -1) ? lua_tostring(L, -1) : "failed");
    lua_pop(L, 2);
  }
  V->omtime = file_mtime(V->opath);                // our own write: no reload
  world_status(V);
}

static void seek(Viewer *V, double t) {
  if (V->stopped) return;
  break_abort(V);
  if (!hist_call(V, "viewer_hist_seek", 2, true, t)) return;
  V->gtime = lua_tonumber(V->L, -2);
  V->gframe = (int)lua_tointeger(V->L, -1);        // (the frame of that time: between two snapshots, in step)
  lua_pop(V->L, 2);
  V->seeked = true;
}

// deliver a key to the game (world's on_key hook), as player 1..4: the
// host's world, or a peer's (the Players button)
static void game_key_to(Viewer *V, int player, const char *key, bool down) {
  lua_State *L = V->L;
  if (V->world == LUA_NOREF) return;
  if (!player_in(V, player)) return;               // (a player not in the game: nobody hears it)
  if (player > 1) { players_key(V, player, key, down); return; }
  lua_getglobal(L, "viewer_key");
  lua_rawgeti(L, LUA_REGISTRYINDEX, V->world);
  lua_pushstring(L, key);
  lua_pushboolean(L, down);
  lua_pushinteger(L, 1);
  if (lua_pcall(L, 4, 1, 0) != 0) {
    SDL_snprintf(V->err, sizeof V->err, "on_key: %s", lua_tostring(L, -1));
    lua_pop(L, 1);
    return;
  }
  if (down && !strcmp(key, "escape"))
    SDL_snprintf(V->info, sizeof V->info, "%s -> game%s", key,
                 lua_toboolean(L, -1) ? "" : " (the world has no on_key handler)");
  lua_pop(L, 1);
}
static void game_key(Viewer *V, const char *key, bool down) { game_key_to(V, g_key_player, key, down); }

// refresh V->code_err; sync = rebuild code systems now (after a reload,
// so a saved system swaps in even while paused)
static void code_status(Viewer *V, bool sync) {
  V->code_err[0] = 0;
  if (V->world == LUA_NOREF) return;
  lua_State *L = V->L;
  lua_getglobal(L, "viewer_code");
  lua_rawgeti(L, LUA_REGISTRYINDEX, V->world);
  lua_pushboolean(L, sync);
  if (lua_pcall(L, 2, 1, 0) != 0) {
    SDL_snprintf(V->code_err, sizeof V->code_err, "code: %s", lua_tostring(L, -1));
  } else if (lua_isstring(L, -1)) {
    SDL_snprintf(V->code_err, sizeof V->code_err, "code: %s", lua_tostring(L, -1));
  }
  lua_pop(L, 1);
}

// an SDL key to the game, named in lowercase ("f1", "`", "a", "left"...)
static SDL_Keycode keys_held[16];                 // keys the game has down (released when the editor takes the keys)
static int keys_player[16];                        // ... and whose: a release goes to the player it was pressed for
static int nkeys_held;
static void send_key(Viewer *V, SDL_Keycode k, bool down) {
  int at = -1, player = g_key_player;
  for (int i = 0; i < nkeys_held; i++) if (keys_held[i] == k) at = i;
  if (at >= 0) player = keys_player[at];
  if (down && at < 0 && nkeys_held < 16) { keys_held[nkeys_held] = k; keys_player[nkeys_held++] = player; }
  if (!down && at >= 0) { --nkeys_held; keys_held[at] = keys_held[nkeys_held]; keys_player[at] = keys_player[nkeys_held]; }
  char kn[64];
  SDL_strlcpy(kn, SDL_GetKeyName(k), sizeof kn);
  for (char *c = kn; *c; c++) *c = (char)SDL_tolower((unsigned char)*c);
  if (kn[0]) game_key_to(V, player, kn, down);
}

static void release_game_keys(Viewer *V) {        // (the view changed: no key stays down in the game)
  while (nkeys_held > 0) send_key(V, keys_held[nkeys_held - 1], false);
}

static void check_reload(Viewer *V) {
  if (V->isdir && V->world != LUA_NOREF) {         // folder: re-read and patch in place
    lua_State *L = V->L;
    lua_getglobal(L, "viewer_poll");
    lua_rawgeti(L, LUA_REGISTRYINDEX, V->world);
    if (lua_pcall(L, 1, 0, 0) != 0) {              // bad edit: keep the world, show why
      SDL_snprintf(V->err, sizeof V->err, "%s", lua_tostring(L, -1));
      lua_pop(L, 1);
    } else {
      V->err[0] = 0;
      code_status(V, true);
    }
    return;
  }
  SDL_PathInfo info;
  if ((SDL_GetPathInfo(V->path, &info) && info.modify_time != V->mtime) ||
      file_mtime(V->opath) != V->omtime) load_world(V);
}

// a tick's end: its time, what the probe recorded, the timeline
static void tick_after(Viewer *V, double sdt) {
  lua_State *L = V->L;
  V->gtime += sdt;
  V->gframe++;
  lua_pushinteger(L, V->gframe);
  lua_setglobal(L, "viewer_gframe");               // (kept with each snapshot: a seek finds it again)
  players_tick(V, sdt);                            // the other players: the network, their worlds
  probe_commit(V);                                 // what the editor's probe recorded in it
  code_status(V, false);
  lua_pushnumber(L, V->fr_time > 0 ? V->fr_frames / V->fr_time : 0);
  lua_setglobal(L, "viewer_fps");
  if (!V->standalone && hist_call(V, "viewer_hist_record", 1, true, V->gtime)) {   // every 0.5 s of game time
    if (lua_toboolean(L, -1)) { V->fr_time = 0; V->fr_frames = 0; }
    lua_pop(L, 1);
  }
}
// stopped at a breakpoint: pause there (the editor shows that frame so far)
static void tick_broke(Viewer *V, double sdt) {
  g_broken = true;
  g_break_dt = sdt;
  V->paused = true;
  const char *w = probe_break_where();
  char file[1024] = "?"; int line = 0;
  if (w) sscanf(w, "%1023[^\n]\n%d", file, &line);
  const char *base = SDL_strrchr(file, '/');
  SDL_snprintf(V->info, sizeof V->info, "stopped: %s:%d   F5 / play: continue   F10: over   F11: into   SHIFT+F11: out", base ? base + 1 : file, line);
}

static bool tick_once(Viewer *V, double sdt);
static void tick_world(Viewer *V, double dt, double real_dt) {
  if (V->world == LUA_NOREF || V->paused || V->stopped) return;  // paused = slomo 0
  lua_State *L = V->L;
  if (g_broken) {                                  // play after a breakpoint: the rest of that tick
    lua_getglobal(L, "viewer_tick_resume");
    if (lua_pcall(L, 0, 1, 0) != 0) {
      g_broken = false;
      SDL_snprintf(V->err, sizeof V->err, "tick: %s (paused)", lua_tostring(L, -1));
      lua_pop(L, 1);
      V->paused = true;
      return;
    }
    bool again = lua_toboolean(L, -1);
    lua_pop(L, 1);
    if (again) { tick_broke(V, g_break_dt); return; }
    g_broken = false;
    tick_after(V, g_break_dt);
    return;
  }
  double sdt = dt * V->speed;                     // x0.01 .. x4.00
  if (V->seeked) {                                 // resuming after a seek: drop the old future
    lua_pushinteger(L, V->gframe);
    lua_setglobal(L, "viewer_gframe");
    hist_call(V, "viewer_hist_truncate", 0, true, V->gtime);
    V->seeked = false;
    V->fr_time = 0; V->fr_frames = 0;
  }
  V->fr_time += real_dt;                           // fps is about real frames, not game time
  V->fr_frames++;
  double step = players_step(V);                   // a network session: fixed ticks, as many as the time
  if (step <= 0) { V->acc = 0; tick_once(V, sdt); return; }   // that passed (a slow or minimized window
  V->acc += sdt;                                   // still runs 60 a second), but never more than 25 ms of
  if (V->acc > step * 15) V->acc = step * 15;      // ticking a frame: past that the game slows down instead
  Uint64 t0 = SDL_GetTicksNS();                    // (else a slow tick makes slower frames, which want more
  while (V->acc >= step) {                         // ticks, and so on down to a few fps)
    V->acc -= step;
    if (!tick_once(V, step)) { V->acc = 0; break; }
    if (SDL_GetTicksNS() - t0 > 25000000ull) { if (V->acc > step) V->acc = step; break; }
  }
}
// one tick of the game: its systems, then the rest (tick_after); false: it
// broke (a breakpoint, an error: paused)
static bool tick_once(Viewer *V, double sdt) {
  lua_State *L = V->L;
  ov_clear_draws();                                // dd.* from this tick replace the last ones
  lua_getglobal(L, "viewer_tick");
  lua_rawgeti(L, LUA_REGISTRYINDEX, V->world);
  lua_pushnumber(L, sdt);
  lua_pushnumber(L, V->gtime + sdt);               // (the time of the frame it makes: a breakpoint's)
  if (lua_pcall(L, 3, 1, 0) != 0) {
    SDL_snprintf(V->err, sizeof V->err, "tick: %s (paused)", lua_tostring(L, -1));
    lua_pop(L, 1);
    V->paused = true;
    return false;
  }
  bool broke = lua_toboolean(L, -1);
  lua_pop(L, 1);
  if (broke) { tick_broke(V, sdt); return false; }
  tick_after(V, sdt);
  return !V->paused;
}
