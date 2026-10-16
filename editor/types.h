// editor/types.h - Viewer state, Mat/Col and 2D transform math.
// Part of replay.c: included once, in order, from there (one compilation unit).

typedef struct { float a, b, c, d, tx, ty; } Mat;
typedef struct { Uint8 r, g, b, a; } Col;

typedef struct {
  lua_State *L;
  int world;                       // registry ref, LUA_NOREF if none
  SDL_Renderer *ren;
  const char *path;
  SDL_Time mtime;
  bool isdir;                      // path is a world folder
  char err[512];
  bool paused, panel, gizmos, pickdbg;
  bool launched;                   // a --standalone copy of the game is running (launch button)
  bool standalone;                 // game only: no tab, timeline, editor, overlay or dev keys
  bool stopped;                    // editing the authored world (no session): saving allowed
  bool savable, dirty;             // world can be written back / differs from disk
  bool sel_dirty;                  // the selected nodes differ from disk (props Save / Undo)
  bool logwin;                     // lite's Log tab is open (the main menu's "Log window")
  bool editing;                    // lite is visible (editing mode), mirrored from main's edfocus
  bool script;                     // a script world: saving writes the overrides file
  char opath[1024];                // its overrides file (scene1.overrides.lua)
  SDL_Time omtime;                 // ... and its mtime (0: none), watched like the script
  float fade;                      // game opacity over lite now: fades[] of the current state
  float fades[3];                  // ... per state (0 playing, 1 paused, 2 stopped): 0 editor, 1 game, between: mixed
  int edmode;                      // editor shown as: 1 mixed (game over it, `fade`), 2 editor only
  double gtime;                    // game time (s): what the timeline shows
  double acc;                      // a network session's fixed ticks: game time not ticked yet (s)
  int gframe;                      // game frames (ticks) so far: what the overlay's "frame N" shows; rewinds with the timeline
  float speed;                     // game time multiplier, x0.01 .. x4.00 (click: x1..x4, wheel: fine)
  bool seeked;                     // time was moved: the next tick starts a new future
  double fr_time;                  // real time and frames since the last snapshot,
  int fr_frames;                   // -> the fps stored with the next one
  float camx, camy, zoom;
  int drawn, frame;
  char info[512];                  // last inspect message
  char code_err[512];              // first error of a code-leaf system (ecs.code)
  char selected[256], via[256];    // inspected node (and the instance it was clicked through)
  int tab_w;                       // tree tab width (left column), game area starts here
  bool reveal;                     // scroll the tab to the selected node (lite's: plugins/sidetab.lua)
  int pmask;                       // the Players button: who's in while playing, bit k-1 = player k (players.h)
  float net;                       // the Network button: the simulated network's quality, 0 awful .. 1 none (players.h)
} Viewer;

// ---------------------------------------------------------------------------
// math
// ---------------------------------------------------------------------------

static Mat mat_mul(Mat P, Mat L) {
  Mat M;
  M.a = P.a * L.a + P.c * L.b;   M.b = P.b * L.a + P.d * L.b;
  M.c = P.a * L.c + P.c * L.d;   M.d = P.b * L.c + P.d * L.d;
  M.tx = P.a * L.tx + P.c * L.ty + P.tx;
  M.ty = P.b * L.tx + P.d * L.ty + P.ty;
  return M;
}

static SDL_FPoint xf(Mat M, float x, float y) {
  SDL_FPoint p = { M.a * x + M.c * y + M.tx, M.b * x + M.d * y + M.ty };
  return p;
}
