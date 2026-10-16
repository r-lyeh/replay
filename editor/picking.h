// editor/picking.h - picking: what is under the mouse (bounds, boxes, strokes).
// Part of replay.c: included once, in order, from there (one compilation unit).

// ---------------------------------------------------------------------------
// picking: while drawing, every visual grows a screen box for its node
// ---------------------------------------------------------------------------

// What counts as "under the mouse":
//   1. a `bounds` component (oriented box, screen box or circle): anything
//      inside one wins; if several, the smallest
//   2. otherwise: filled shapes, sprites, text anywhere inside their box;
//      outlines (lines, unfilled rect/circle) within 5 px of the line;
//      the smallest wins (a planet beats its orbit)
// Parts drawn through `ref` remember the outermost instance (via) and the
// class/asset it instantiates (cls): right-click picks the instance,
// Alt+right-click the class part.
typedef struct {
  SDL_FRect r;
  bool solid;
  bool bounded;                                    // from a `bounds` component
  int seg0, seg1;                                  // outline segments
  int poly0, poly1;                                // `bounds` shape
  char path[256], via[256], cls[256];
} Pick;
#define MAXPICK 4096
#define MAXSEG 65536
#define MAXPOLY 8192
static Pick picks[MAXPICK];
static int npicks;
static SDL_FPoint segs[MAXSEG][2];                 // outline segments, screen space
static int nsegs;
static SDL_FPoint ppts[MAXSEG];                    // `bounds` shape points, screen space
static int nppts;
static struct { int a, n; float area; } polys[MAXPOLY];
static int npolys;
static char cur_via[256], cur_cls[256];            // instance / class being drawn through `ref`
static float acc_x0, acc_y0, acc_x1, acc_y1;
static bool acc_solid;
static int acc_seg0, acc_poly0;

static void acc_reset(void) {
  acc_x0 = acc_y0 = 1e30f; acc_x1 = acc_y1 = -1e30f;
  acc_solid = false;
  acc_seg0 = nsegs;
  acc_poly0 = npolys;
}
static void acc_poly(const SDL_FPoint *p, int n) {  // record a `bounds` shape
  if (npolys >= MAXPOLY || nppts + n > MAXSEG || n < 3) return;
  float area = 0;
  for (int i = 0; i < n; i++) {
    ppts[nppts + i] = p[i];
    const SDL_FPoint *q = &p[(i + 1) % n];
    area += p[i].x * q->y - q->x * p[i].y;
  }
  polys[npolys].a = nppts; polys[npolys].n = n; polys[npolys].area = SDL_fabsf(area) / 2;
  nppts += n; npolys++;
}
static bool in_poly(float x, float y, int pi) {    // even-odd rule
  const SDL_FPoint *p = &ppts[polys[pi].a];
  int n = polys[pi].n;
  bool in = false;
  for (int i = 0, j = n - 1; i < n; j = i++)
    if ((p[i].y > y) != (p[j].y > y) &&
        x < (p[j].x - p[i].x) * (y - p[i].y) / (p[j].y - p[i].y) + p[i].x) in = !in;
  return in;
}
static void acc_stroke(const SDL_FPoint *p, int n) {  // record an outline polyline
  for (int i = 0; i + 1 < n && nsegs < MAXSEG; i++) {
    segs[nsegs][0] = p[i]; segs[nsegs][1] = p[i + 1]; nsegs++;
  }
}
static float seg_dist2(SDL_FPoint p, SDL_FPoint a, SDL_FPoint b) {
  float dx = b.x - a.x, dy = b.y - a.y, len2 = dx * dx + dy * dy, t = 0;
  if (len2 > 0) t = ((p.x - a.x) * dx + (p.y - a.y) * dy) / len2;
  if (t < 0) t = 0; else if (t > 1) t = 1;
  float x = a.x + t * dx - p.x, y = a.y + t * dy - p.y;
  return x * x + y * y;
}
static void acc_add(float x, float y) {
  if (x < acc_x0) acc_x0 = x;
  if (y < acc_y0) acc_y0 = y;
  if (x > acc_x1) acc_x1 = x;
  if (y > acc_y1) acc_y1 = y;
}
static SDL_FPoint xfa(Mat M, float x, float y) {   // transform + grow the box
  SDL_FPoint p = xf(M, x, y);
  acc_add(p.x, p.y);
  return p;
}

static void pick_add(const char *path, const char *via, const char *cls,
                     float x0, float y0, float x1, float y1,
                     bool solid, int seg0, int seg1, int poly0, int poly1) {
  if (npicks >= MAXPICK || x1 < x0 || y1 < y0) return;
  Pick *k = &picks[npicks++];
  k->r.x = x0 - 2; k->r.y = y0 - 2; k->r.w = x1 - x0 + 4; k->r.h = y1 - y0 + 4;
  k->solid = solid; k->seg0 = seg0; k->seg1 = seg1; k->poly0 = poly0; k->poly1 = poly1;
  k->bounded = false;
  SDL_strlcpy(k->path, path, sizeof k->path);
  SDL_strlcpy(k->via, via ? via : "", sizeof k->via);
  SDL_strlcpy(k->cls, cls ? cls : "", sizeof k->cls);
}

// bounds first (smallest wins); if none, drawn shapes (smallest box wins)
static const Pick *pick_at(float x, float y) {
  const Pick *best = NULL;
  float best_area = 1e30f;
  for (int i = npicks - 1; i >= 0; i--) {           // 1. `bounds` components
    const Pick *k = &picks[i];
    if (!k->bounded) continue;
    for (int q = k->poly0; q < k->poly1; q++)
      if (in_poly(x, y, q) && polys[q].area < best_area) { best_area = polys[q].area; best = k; }
  }
  if (best) return best;
  SDL_FPoint p = { x, y };
  for (int i = npicks - 1; i >= 0; i--) {           // 2. what was drawn
    const Pick *k = &picks[i];
    const SDL_FRect *r = &k->r;
    if (k->bounded) continue;
    if (x < r->x - 5 || y < r->y - 5 || x > r->x + r->w + 5 || y > r->y + r->h + 5) continue;
    bool hit = k->solid && x >= r->x && y >= r->y && x <= r->x + r->w && y <= r->y + r->h;
    for (int s = k->seg0; !hit && s < k->seg1; s++)
      hit = seg_dist2(p, segs[s][0], segs[s][1]) <= 5.f * 5.f;
    if (!hit) continue;
    float area = r->w * r->h;
    if (area < best_area) { best_area = area; best = k; }
  }
  return best;
}

// the game's picture: is (x, y) (game-area coordinates) inside the box around
// everything the last frame drew (all picks, 8 px around)? Nothing drawn: no.
