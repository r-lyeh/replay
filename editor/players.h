// editor/players.h - the Players and Network buttons: players 1..4 of the game, over a simulated network.
// Part of replay.c: included once, in order, from there (one compilation unit).
//
// The editor's world is the host: the timeline, the tree, the probe,
// breakpoints are all its, and it runs whether player 1 plays or not (with
// nobody in, it's a server alone). Player 1 plays in it; each other player
// is a peer: a copy of the host's world when it joins, its own view (the
// game view splits), its own keys (the view under the mouse gets the
// keyboard; gamepad N is player N), connected to the others over net.sim.
// What travels is what the game tagged (`replicate`, net.peer); for the game
// every player is local: on_key(w, key, down, player), w.players (a set).
// Peers exist only while playing; Stop drops them. Who's in (V->pmask) and
// the network's quality (V->net) last the session: never saved. At 100% (the
// default for now) there's no network at all: every player plays in the
// host's world, as local multiplayer (each view shows it, each player's keys
// go to it with its number), exactly as offline.
// The Network button's menu (RMB, bar.h): ghosts (draw_ghost: what the
// owners sent last of what a view predicts, faint), the send rate, and each
// player's own line (or cut). Its Lua: runtime/players.lua.


static void players_init(Viewer *V) {
  V->pmask = 1;                                    // the editor always starts with player 1 alone
  V->net = 1.f;                                    // 100%: no network (75%, a good one, later)
  char err[2048];                                  // (its Lua: runtime/players.lua)
  if (!runtime_run(V->L, "players", err, sizeof err)) fprintf(stderr, "players: %s\n", err);
}

static void players_call(Viewer *V, int nargs) {   // (the function and its args are pushed)
  if (lua_pcall(V->L, nargs, 0, 0) != 0) {
    SDL_snprintf(V->err, sizeof V->err, "players: %s", lua_tostring(V->L, -1));
    lua_pop(V->L, 1);
  }
}

static int pl_count(int mask) { int n = 0; for (int k = 0; k < 4; k++) n += (mask >> k) & 1; return n; }
// who's in now: the button's players while playing; stopped, the edited world (player 1)
static int players_now(const Viewer *V) { return V->stopped || V->standalone ? 1 : V->pmask; }
static bool player_in(const Viewer *V, int k) { return k >= 1 && k <= 4 && (players_now(V) >> (k - 1)) & 1; }

// every frame: join / part to the button's players (while playing)
static void players_sync(Viewer *V) {
  if (V->world == LUA_NOREF || V->stopped || V->standalone) return;
  lua_getglobal(V->L, "viewer_players_sync");
  lua_rawgeti(V->L, LUA_REGISTRYINDEX, V->world);
  lua_pushinteger(V->L, V->pmask);
  players_call(V, 2);
}
static void players_stop(Viewer *V) {
  lua_getglobal(V->L, "viewer_players_stop");
  players_call(V, 0);
}
static void players_tick(Viewer *V, double dt) {   // (standalone too: an exported game can play online)
  lua_getglobal(V->L, "viewer_players_tick");
  lua_pushnumber(V->L, dt);
  players_call(V, 1);
}
static double players_step(Viewer *V) {          // a network session's fixed tick (s); 0: none (a tick a frame)
  lua_getglobal(V->L, "viewer_players_step");
  double s = lua_pcall(V->L, 0, 1, 0) == 0 ? lua_tonumber(V->L, -1) : 0;
  lua_pop(V->L, 1);
  return s;
}
static void players_key(Viewer *V, int k, const char *key, bool down) {
  lua_getglobal(V->L, "viewer_players_key");
  lua_pushinteger(V->L, k);
  lua_pushstring(V->L, key);
  lua_pushboolean(V->L, down);
  players_call(V, 3);
}
static int players_rtt(Viewer *V, int k) {        // ms, 0: not measured (yet)
  lua_getglobal(V->L, "viewer_players_rtt");
  lua_pushinteger(V->L, k);
  int ms = lua_pcall(V->L, 1, 1, 0) == 0 ? (int)lua_tointeger(V->L, -1) : 0;
  lua_pop(V->L, 1);
  return ms;
}
// the Network button: its quality, 0 (awful) .. 1 (local); the presets at 0, 25,
// 50, 75 and 100%: awful, bad, fair, good, local (between two: their numbers
// blend; exactly 100%: no network, everyone in the host's world)
static void players_net(Viewer *V, float q) {
  q = SDL_roundf((q < 0 ? 0 : q > 1 ? 1 : q) * 100) / 100;
  V->net = q;
  lua_getglobal(V->L, "viewer_players_net");
  lua_pushnumber(V->L, q);
  players_call(V, 1);
}
static float net_click(const Viewer *V) {          // a click: the next preset down (awful: local again)
  float p = SDL_ceilf(V->net * 4 - 0.001f) - 1;
  return p < 0 ? 1.f : p / 4;
}
static float net_wheel(const Viewer *V, float dir) { return V->net + (dir > 0 ? 0.01f : -0.01f); }
static void players_net_info(Viewer *V, char *out, size_t n) {   // "75% good, 50 ms +-10, 1% lost"
  lua_State *L = V->L;
  lua_getglobal(L, "viewer_players_net_info");
  if (lua_pcall(L, 0, 5, 0) != 0) { lua_pop(L, 1); out[0] = 0; return; }
  double loss = lua_tonumber(L, -2), dup = lua_tonumber(L, -1);
  const char *name = lua_tostring(L, -5);
  if (V->net >= 1) { SDL_snprintf(out, n, "100%% local: no network"); lua_pop(L, 5); return; }
  int len = SDL_snprintf(out, n, "%.0f%%%s%s, %.0f ms +-%.0f", V->net * 100, name ? " " : "", name ? name : "",
                         lua_tonumber(L, -4), lua_tonumber(L, -3));
  if (loss >= 0.5 && len < (int)n) len += SDL_snprintf(out + len, n - len, ", %.0f%% lost", loss);
  if (dup >= 0.5 && len < (int)n) SDL_snprintf(out + len, n - len, ", %.0f%% doubled", dup);
  lua_pop(L, 5);
}

// the Players icon's quarter under (x, y): TopLeft 1, TopRight 2, BottomLeft 3, BottomRight 4
// the cross that splits the icon is ignored if clicked (< 1 makes the band exactly 2 px wide, matching the drawn gap)
static int players_quarter(const SDL_FRect *b, float x, float y) {
  float cx = b->x + b->w / 2, cy = b->y + b->h / 2;
  if (SDL_fabsf(x - cx) < 1 || SDL_fabsf(y - cy) < 1) return 0;   // on the cross: no player
  return (y >= cy ? 2 : 0) + (x >= cx ? 1 : 0) + 1;
}

// The views follow the icon's quarters (1 top-left, 2 top-right, 3
// bottom-left, 4 bottom-right). One player: the whole area, no split (nobody:
// the host alone, "server"). Two in the same row (1+2, 3+4): side by side;
// in the same column (1+3, 2+4): one over the other; across (1+4, 2+3): the
// 2x2 grid. Three or four: the grid. In the grid each player keeps its own
// quarter, and an empty one stays dark.
static SDL_FRect g_vp[4];                          // this frame's views, in game-area pixels
static int g_vp_who[4];                            // ... whose: 1..4, 0 the server (nobody in), -1 empty
static int g_nvp = 1;
static float g_vp_fit = 1;                         // a view's zoom against the whole area
static int g_key_player = 1;                       // the view under the mouse: the keyboard's player
static int vp_layout(int mask, float w, float h, SDL_FRect r[4], int who[4]) {
  int n = pl_count(mask), ks[4], m = 0;
  for (int k = 1; k <= 4; k++) if ((mask >> (k - 1)) & 1) ks[m++] = k;
  if (n <= 1) { r[0] = (SDL_FRect){ 0, 0, w, h }; who[0] = n ? ks[0] : 0; return 1; }
  float hw = SDL_floorf(w / 2), hh = SDL_floorf(h / 2);
  if (n == 2 && (ks[0] - 1) / 2 == (ks[1] - 1) / 2) {   // the same row: side by side
    r[0] = (SDL_FRect){ 0, 0, hw, h }; r[1] = (SDL_FRect){ hw, 0, w - hw, h };
    who[0] = ks[0]; who[1] = ks[1];
    return 2;
  }
  if (n == 2 && (ks[0] - 1) % 2 == (ks[1] - 1) % 2) {   // the same column: one over the other
    r[0] = (SDL_FRect){ 0, 0, w, hh }; r[1] = (SDL_FRect){ 0, hh, w, h - hh };
    who[0] = ks[0]; who[1] = ks[1];
    return 2;
  }
  r[0] = (SDL_FRect){ 0, 0, hw, hh };      r[1] = (SDL_FRect){ hw, 0, w - hw, hh };
  r[2] = (SDL_FRect){ 0, hh, hw, h - hh }; r[3] = (SDL_FRect){ hw, hh, w - hw, h - hh };
  for (int k = 1; k <= 4; k++) who[k - 1] = (mask >> (k - 1)) & 1 ? k : -1;
  return 4;
}
static int vp_at(float x, float y) {               // game-area pixels -> whose view (see g_vp_who), -2: none
  for (int i = 0; i < g_nvp; i++)
    if (x >= g_vp[i].x && x < g_vp[i].x + g_vp[i].w && y >= g_vp[i].y && y < g_vp[i].y + g_vp[i].h) return g_vp_who[i];
  return -2;
}

static const Col PLAYER_COL[4] = { { 120, 220, 255, 255 }, { 255, 150, 90, 255 }, { 140, 230, 120, 255 }, { 230, 130, 230, 255 } };

// the world on top of the stack drawn into a view (nothing of it is pickable); pops it
static void draw_other_world(Viewer *V, Mat cam) {
  lua_State *L = V->L;
  int host = V->world, np = npicks, ns = nsegs, npp = nppts, npo = npolys, drawn = V->drawn;
  V->world = luaL_ref(L, LUA_REGISTRYINDEX);
  lua_rawgeti(L, LUA_REGISTRYINDEX, V->world);
  lua_getfield(L, -1, "root");
  Col white = { 220, 220, 220, 255 };
  draw_layers(V, -1, cam, white);
  lua_pop(L, 2);
  luaL_unref(L, LUA_REGISTRYINDEX, V->world);
  V->world = host;
  npicks = np; nsegs = ns; nppts = npp; npolys = npo; V->drawn = drawn;
}

// a peer's world drawn into its view
static void draw_peer(Viewer *V, int k, Mat cam) {
  lua_State *L = V->L;
  lua_getglobal(L, "viewer_players_world");
  lua_pushinteger(L, k);
  if (lua_pcall(L, 1, 1, 0) != 0 || !lua_istable(L, -1)) { lua_pop(L, 1); return; }
  draw_other_world(V, cam);
}

// over player k's view (0: the server's), faint: the last state the owners
// sent of what it predicts (the Network menu's Ghosts). Where the guess and
// the truth agree, the ghost hides under it.
static void draw_ghost(Viewer *V, int k, Mat cam) {
  lua_State *L = V->L;
  lua_getglobal(L, "viewer_players_ghost");
  lua_pushinteger(L, k);
  if (lua_pcall(L, 1, 1, 0) != 0 || !lua_istable(L, -1)) { lua_pop(L, 1); return; }
  g_alpha = 0.35f;
  draw_other_world(V, cam);
  g_alpha = 1.f;
}

// the Network menu's settings (this session: never saved), see bar.h
static bool g_net_ghosts = true;
static int g_net_rate = 20;                        // states a second
static int g_net_link[4] = { -1, -1, -1, -1 };     // -1 as everyone's, 0..4 a preset (awful..local), 5 cut
static void players_set_ghosts(Viewer *V, bool on) {
  g_net_ghosts = on;
  lua_getglobal(V->L, "viewer_players_ghosts");
  lua_pushboolean(V->L, on);
  players_call(V, 1);
}
static void players_set_rate(Viewer *V, int hz) {
  g_net_rate = hz;
  lua_getglobal(V->L, "viewer_players_rate");
  lua_pushinteger(V->L, hz);
  players_call(V, 1);
}
static void players_set_link(Viewer *V, int k, int v) {   // k 1..4
  g_net_link[k - 1] = v;
  lua_getglobal(V->L, "viewer_players_link");
  lua_pushinteger(V->L, k);
  lua_pushnumber(V->L, v == 5 ? -2 : v < 0 ? -1 : v / 4.0);
  players_call(V, 2);
}
static double players_bandwidth(Viewer *V) {       // bytes a second on the network now
  lua_getglobal(V->L, "viewer_players_bandwidth");
  double b = lua_pcall(V->L, 0, 1, 0) == 0 ? lua_tonumber(V->L, -1) : 0;
  lua_pop(V->L, 1);
  return b;
}

// the views' frames and names, over the game: "P2 100 ms" (its measured
// round trip to the host); the keyboard's view framed in its player's
// colour (game view: the keys go to the game). One view: named only when
// it isn't player 1's (the server, or another player alone)
static void draw_views(Viewer *V, bool keys_to_game) {
  SDL_Renderer *r = V->ren;
  SDL_SetRenderClipRect(r, NULL);
  if (g_nvp == 1 && g_vp_who[0] == 1) return;
  for (int i = 0; i < g_nvp; i++) {
    int k = g_vp_who[i];
    if (k < 0) {                                   // an empty quarter
      SDL_SetRenderDrawColor(r, 12, 13, 18, 255);
      SDL_RenderFillRect(r, &g_vp[i]);
    }
    SDL_SetRenderDrawColor(r, 60, 64, 80, 255);
    if (g_nvp > 1) SDL_RenderRect(r, &g_vp[i]);
    if (k < 0) continue;
    char t[48];
    Col c = k ? PLAYER_COL[k - 1] : (Col){ 150, 155, 175, 255 };
    int ms = k > 1 ? players_rtt(V, k) : 0;
    if (k == 0) SDL_snprintf(t, sizeof t, "server (nobody plays)");
    else if (k == 1) SDL_snprintf(t, sizeof t, "P1 host");
    else if (ms) SDL_snprintf(t, sizeof t, "P%d %d ms", k, ms);
    else SDL_snprintf(t, sizeof t, "P%d", k);
    SDL_SetRenderDrawColor(r, c.r, c.g, c.b, 255);
    SDL_RenderDebugText(r, g_vp[i].x + 8, g_vp[i].y + g_vp[i].h - 16, t);
    if (keys_to_game && k > 0 && g_key_player == k && g_nvp > 1) {
      SDL_FRect f = { g_vp[i].x + 1, g_vp[i].y + 1, g_vp[i].w - 2, g_vp[i].h - 2 };
      SDL_RenderRect(r, &f);
      SDL_FRect f2 = { f.x + 1, f.y + 1, f.w - 2, f.h - 2 };
      SDL_RenderRect(r, &f2);
    }
  }
}
