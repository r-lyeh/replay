// editor/render.h - drawing the world: render components and the node tree walk.
// Part of replay.c: included once, in order, from there (one compilation unit).

// ---------------------------------------------------------------------------
// Lua helpers (all take absolute stack indices)
// ---------------------------------------------------------------------------

static bool gizmo_wanted(Viewer *V, const char *path);   // (ui.h: under a selected node?)
static int absidx(lua_State *L, int i) {
  return (i > 0 || i <= LUA_REGISTRYINDEX) ? i : lua_gettop(L) + i + 1;
}

static double fnum(lua_State *L, int t, const char *k, double def) {
  lua_getfield(L, t, k);
  double v = lua_isnumber(L, -1) ? lua_tonumber(L, -1) : def;
  lua_pop(L, 1);
  return v;
}

static bool fbool(lua_State *L, int t, const char *k) {
  lua_getfield(L, t, k);
  bool v = lua_toboolean(L, -1);
  lua_pop(L, 1);
  return v;
}

static double inum(lua_State *L, int t, int i, double def) {
  lua_rawgeti(L, t, i);
  double v = lua_isnumber(L, -1) ? lua_tonumber(L, -1) : def;
  lua_pop(L, 1);
  return v;
}

// read a color table at index t: {r,g,b,a} or {r=,g=,b=,a=}
static Col read_color(lua_State *L, int t, Col def) {
  if (!lua_istable(L, t)) return def;
  Col c;
  c.r = (Uint8)inum(L, t, 1, fnum(L, t, "r", def.r));
  c.g = (Uint8)inum(L, t, 2, fnum(L, t, "g", def.g));
  c.b = (Uint8)inum(L, t, 3, fnum(L, t, "b", def.b));
  c.a = (Uint8)inum(L, t, 4, fnum(L, t, "a", 255));
  return c;
}

static float g_alpha = 1.f;                        // everything drawn this much (a ghost: faint)

static void set_color(Viewer *V, Col c) {
  SDL_SetRenderDrawColor(V->ren, c.r, c.g, c.b, (Uint8)(c.a * g_alpha));
}

// call world:method(arg at index argi) -> leaves 1 result on the stack
static bool world_call(Viewer *V, const char *method, int argi, const char *sarg) {
  lua_State *L = V->L;
  lua_rawgeti(L, LUA_REGISTRYINDEX, V->world);
  lua_getfield(L, -1, method);
  lua_pushvalue(L, -2);
  if (sarg) lua_pushstring(L, sarg); else lua_pushvalue(L, argi);
  lua_remove(L, -4);                               // drop the world copy
  if (lua_pcall(L, 2, 1, 0) != 0) {
    SDL_snprintf(V->err, sizeof V->err, "%s", lua_tostring(L, -1));
    lua_pop(L, 1);
    lua_pushnil(L);
    return false;
  }
  return true;
}

// ---------------------------------------------------------------------------
// drawing the recognised components
// ---------------------------------------------------------------------------

#define MAXPTS 4096
static SDL_FPoint pts[MAXPTS];
static SDL_Vertex verts[MAXPTS * 3];

static SDL_FColor fcol(Col c) {
  SDL_FColor f = { c.r / 255.f, c.g / 255.f, c.b / 255.f, c.a / 255.f * g_alpha };
  return f;
}

static void draw_poly(Viewer *V, int n, bool fill, Col col) {
  if (n < 2) return;
  if (fill && n >= 3) {                            // fan from the first point
    int nv = 0;
    SDL_FColor fc = fcol(col);
    for (int i = 1; i + 1 < n && nv + 3 <= MAXPTS * 3; i++) {
      SDL_FPoint tri[3] = { pts[0], pts[i], pts[i + 1] };
      for (int k = 0; k < 3; k++) {
        verts[nv].position = tri[k]; verts[nv].color = fc;
        verts[nv].tex_coord.x = verts[nv].tex_coord.y = 0; nv++;
      }
    }
    SDL_RenderGeometry(V->ren, NULL, verts, nv, NULL, 0);
    acc_solid = true;
  } else {
    set_color(V, col);
    SDL_RenderLines(V->ren, pts, n);
    acc_stroke(pts, n);
  }
}

static void draw_lines(Viewer *V, int t, Mat M, Col col) {
  lua_State *L = V->L;
  int len = (int)objlen(L, t), n = 0;
  for (int i = 1; i + 1 <= len && n < MAXPTS - 1; i += 2)
    pts[n++] = xfa(M, (float)inum(L, t, i, 0), (float)inum(L, t, i + 1, 0));
  if (fbool(L, t, "loop") && n > 2) pts[n++] = pts[0];
  draw_poly(V, n, false, col);
}

static void draw_tris(Viewer *V, int t, Mat M, Col col) {
  lua_State *L = V->L;
  int len = (int)objlen(L, t), nv = 0;
  SDL_FColor fc = fcol(col);
  for (int i = 1; i + 5 <= len && nv + 3 <= MAXPTS * 3; i += 6) {
    for (int k = 0; k < 3; k++) {
      verts[nv].position = xfa(M, (float)inum(L, t, i + k * 2, 0), (float)inum(L, t, i + k * 2 + 1, 0));
      verts[nv].color = fc;
      verts[nv].tex_coord.x = verts[nv].tex_coord.y = 0;
      nv++;
    }
  }
  if (nv) SDL_RenderGeometry(V->ren, NULL, verts, nv, NULL, 0);
  acc_solid = true;
}

static void draw_rect(Viewer *V, int t, Mat M, Col col) {
  float w = (float)fnum(V->L, t, "w", 10) / 2, h = (float)fnum(V->L, t, "h", 10) / 2;
  pts[0] = xfa(M, -w, -h); pts[1] = xfa(M, w, -h);
  pts[2] = xfa(M, w, h);   pts[3] = xfa(M, -w, h); pts[4] = pts[0];
  bool fill = fbool(V->L, t, "fill");
  draw_poly(V, fill ? 4 : 5, fill, col);
}

static void draw_circle(Viewer *V, int t, Mat M, Col col) {
  float r = (float)fnum(V->L, t, "r", 10);
  int n = (int)fnum(V->L, t, "n", 24);
  if (n < 3) n = 3;
  if (n > MAXPTS - 2) n = MAXPTS - 2;
  for (int i = 0; i <= n; i++) {
    float a = (float)i / n * 6.2831853f;
    pts[i] = xfa(M, r * cosf(a), r * sinf(a));
  }
  bool fill = fbool(V->L, t, "fill");
  draw_poly(V, fill ? n : n + 1, fill, col);
}

static void draw_text(Viewer *V, int t, Mat M, Col col) {
  lua_State *L = V->L;
  const char *s = NULL;
  if (lua_type(L, t) == LUA_TSTRING) s = lua_tostring(L, t);
  else if (lua_istable(L, t)) {
    lua_rawgeti(L, t, 1);
    s = lua_tostring(L, -1);
    lua_pop(L, 1);                 // string stays alive: it lives in the table
  }
  if (!s) return;
  float k = 1;                                     // text = { "big", size = 4 }: scaled
  if (lua_istable(L, t)) {                         // font, also by the transform/zoom
    double size = fnum(L, t, "size", 0);
    if (size > 0) k = (float)(size * SDL_sqrt(M.a * M.a + M.b * M.b));
    if (k < 0.25f) k = 0.25f;
  }
  SDL_FPoint p = xfa(M, 0, 0);
  acc_add(p.x, p.y);
  acc_add(p.x + 8.f * k * (float)strlen(s), p.y + 8.f * k);  // debug font is 8x8
  acc_solid = true;
  set_color(V, col);
  if (k == 1) { SDL_RenderDebugText(V->ren, p.x, p.y, s); return; }
  SDL_Rect clip;                                   // (a clip rect scales too: a player's view, players.h)
  bool clipped = SDL_RenderClipEnabled(V->ren) && SDL_GetRenderClipRect(V->ren, &clip);
  float s0x = 1, s0y = 1;                          // (on top of the scale already set: retina)
  SDL_GetRenderScale(V->ren, &s0x, &s0y);
  SDL_SetRenderScale(V->ren, k * s0x, k * s0y);
  if (clipped) {
    SDL_Rect c = { (int)SDL_floorf(clip.x / k), (int)SDL_floorf(clip.y / k), (int)SDL_ceilf(clip.w / k), (int)SDL_ceilf(clip.h / k) };
    SDL_SetRenderClipRect(V->ren, &c);
  }
  SDL_RenderDebugText(V->ren, p.x / k, p.y / k, s);
  SDL_SetRenderScale(V->ren, s0x, s0y);
  if (clipped) SDL_SetRenderClipRect(V->ren, &clip);
}

// sprite = { "row", "row", ..., palette = { ["#"] = {r,g,b,a} }, px = 1 }
static void draw_sprite(Viewer *V, int t, Mat M, Col col) {
  lua_State *L = V->L;
  int rows = (int)objlen(L, t), nv = 0;
  float px = (float)fnum(L, t, "px", 1);
  lua_getfield(L, t, "palette");
  int pal = lua_gettop(L);
  int cols = 0;
  for (int y = 1; y <= rows; y++) {
    lua_rawgeti(L, t, y);
    size_t w = 0;
    lua_tolstring(L, -1, &w);
    if ((int)w > cols) cols = (int)w;
    lua_pop(L, 1);
  }
  float ox = -cols * px / 2, oy = -rows * px / 2;
  for (int y = 0; y < rows; y++) {
    lua_rawgeti(L, t, y + 1);
    size_t w = 0;
    const char *row = lua_tolstring(L, -1, &w);
    for (int x = 0; row && x < (int)w; x++) {
      char ch = row[x];
      if (ch == '.' || ch == ' ') continue;
      Col c = col;
      if (lua_istable(L, pal)) {
        char key[2] = { ch, 0 };
        lua_getfield(L, pal, key);
        c = read_color(L, lua_gettop(L), col);
        lua_pop(L, 1);
      }
      if (nv + 6 > MAXPTS * 3) break;
      float x0 = ox + x * px, y0 = oy + y * px;
      SDL_FPoint q[4] = { xfa(M, x0, y0), xfa(M, x0 + px, y0),
                          xfa(M, x0 + px, y0 + px), xfa(M, x0, y0 + px) };
      int idx[6] = { 0, 1, 2, 0, 2, 3 };
      SDL_FColor fc = fcol(c);
      for (int k = 0; k < 6; k++) {
        verts[nv].position = q[idx[k]]; verts[nv].color = fc;
        verts[nv].tex_coord.x = verts[nv].tex_coord.y = 0; nv++;
      }
    }
    lua_pop(L, 1);
  }
  lua_pop(L, 1);                   // palette
  if (nv) SDL_RenderGeometry(V->ren, NULL, verts, nv, NULL, 0);
  acc_solid = true;
}

// image = "/assets/ship.png"  or  { "/assets/ship.png", w = 32, h = 32,
//          color = { r, g, b, a }, smooth = false, src = { x, y, w, h } }
//          or { "/assets/ui.atlas.lua", frame = "ship" } (atlas_get, below)
// A picture from the game's assets/ folder (a folder world's; a script's: the
// common/ folder beside it, shared by the single-file games), centred on the node, w x h world units (default: its
// size in pixels), turning and scaling with the transform. `color` tints it
// (default: as it is; the node's colour doesn't). smooth = false: crisp
// pixels when scaled. Read again when its file changes on disk.
typedef struct { char file[1024]; SDL_Texture *tex; int w, h; SDL_Time mtime; Uint64 checked; bool smooth; } Tex;
static Tex texs[256];
static int ntexs;

static SDL_Texture *g_dot_tex;                     // (bullets' soft dot: draw_bullets)
static void tex_reset(void) {                      // (the renderer lost its textures: read them again)
  if (g_dot_tex) { SDL_DestroyTexture(g_dot_tex); g_dot_tex = NULL; }
  for (int i = 0; i < ntexs; i++) if (texs[i].tex) SDL_DestroyTexture(texs[i].tex);
  ntexs = 0;
}

static char g_export_root[1024];                 // (export.h's: where runtime/ and plugins/ are)
// "plugin:tiles.png" (a tile map's tileset: plugins/tilemap's own) -> <root>plugins/tilemap/tiles.png
static void tex_file(Viewer *V, const char *name, char *out, size_t size) {
  if (!strncmp(name, "plugin:", 7)) { SDL_snprintf(out, size, "%splugins/tilemap/%s", g_export_root, name + 7); return; }
  char dir[1024];
  SDL_strlcpy(dir, V->path, sizeof dir);
  if (!V->isdir) {                                 // (a script: its folder)
    char *a = SDL_strrchr(dir, '/'), *b = SDL_strrchr(dir, '\\');
    char *e = a > b ? a : b;
    if (e) *e = 0;
  }
  if (!strncmp(name, "/assets/", 8)) name += 8;
  else if (name[0] == '/') name++;
  SDL_snprintf(out, size, "%s/%s/%s", dir, V->isdir ? "assets" : "common", name);   // (a script's: common/ beside it, shared)
}

static void tex_load(Viewer *V, Tex *t) {
  if (t->tex) { SDL_DestroyTexture(t->tex); t->tex = NULL; }
  size_t len = 0;
  void *data = SDL_LoadFile(t->file, &len);
  if (!data) return;
  int w = 0, h = 0;
  unsigned char *px = editor_image_decode(data, (int)len, &w, &h);
  SDL_free(data);
  if (!px) return;
  t->tex = SDL_CreateTexture(V->ren, SDL_PIXELFORMAT_RGBA32, SDL_TEXTUREACCESS_STATIC, w, h);
  if (t->tex) {
    SDL_UpdateTexture(t->tex, NULL, px, w * 4);
    SDL_SetTextureBlendMode(t->tex, SDL_BLENDMODE_BLEND);
    t->w = w; t->h = h;
  }
  editor_image_free(px);
}

static Tex *tex_get(Viewer *V, const char *name) {
  char file[1024];
  tex_file(V, name, file, sizeof file);
  Tex *t = NULL;
  for (int i = 0; i < ntexs && !t; i++) if (!strcmp(texs[i].file, file)) t = &texs[i];
  if (!t) {
    if (ntexs == (int)(sizeof texs / sizeof texs[0])) tex_reset();   // (full: start over)
    t = &texs[ntexs++];
    SDL_zerop(t);
    SDL_strlcpy(t->file, file, sizeof t->file);
    t->smooth = true;
  }
  Uint64 now = SDL_GetTicks();
  if (!t->checked || now - t->checked > 1000) {    // its file changed (or appeared): read it again
    t->checked = now;
    SDL_PathInfo pi;
    SDL_Time m = SDL_GetPathInfo(file, &pi) ? pi.modify_time : 0;
    if (m != t->mtime || (!t->tex && m)) { t->mtime = m; tex_load(V, t); }
  }
  return t;
}

// image = { "/assets/ui.atlas.lua", frame = "ship" }: a frame of an atlas
// (plugins/atlaspacker). Its file is plain data (read in a Lua state of its own,
// no libraries; again when it changes): { image = "/assets/ui.png", frames =
// { { path = "/assets/ship.png", x, y, w, h, deg }... } }. `frame` is a
// frame's name (a cut atlas's: `name = "man1"`), its path, or its path's end
// without the extension ("ship", "rocks/big"). deg = 90: kept turned a
// quarter clockwise in the sheet (w x h: its own size).
// at = "sheet": drawn where it is in the sheet, the sheet centred on the node
// (a Game & Watch screen: every segment's node at the same place, each one
// lit where it belongs); with `src` too.
typedef struct { char path[256], name[64]; float x, y, w, h; int deg; } AtlFrame;
typedef struct { char file[1024], image[512]; AtlFrame *f; int n; SDL_Time mtime; Uint64 checked; } Atl;
static Atl atls[32];
static int natls;

static Atl *atlas_get(Viewer *V, const char *name) {
  char file[1024];
  tex_file(V, name, file, sizeof file);
  Atl *a = NULL;
  for (int i = 0; i < natls && !a; i++) if (!strcmp(atls[i].file, file)) a = &atls[i];
  if (!a) {
    if (natls == (int)(sizeof atls / sizeof atls[0])) { for (int i = 0; i < natls; i++) SDL_free(atls[i].f); natls = 0; }
    a = &atls[natls++];
    SDL_zerop(a);
    SDL_strlcpy(a->file, file, sizeof a->file);
  }
  Uint64 now = SDL_GetTicks();
  if (a->checked && now - a->checked < 1000) return a;
  a->checked = now;
  SDL_PathInfo pi;
  SDL_Time m = SDL_GetPathInfo(file, &pi) ? pi.modify_time : 0;
  if (m == a->mtime && a->f) return a;
  a->mtime = m;
  SDL_free(a->f); a->f = NULL; a->n = 0; a->image[0] = 0;
  lua_State *L = luaL_newstate();                  // (no libraries: data only)
  if (L && luaL_loadfilex(L, file, "t") == LUA_OK && lua_pcall(L, 0, 1, 0) == LUA_OK && lua_istable(L, -1)) {
    lua_getfield(L, -1, "image");
    if (lua_type(L, -1) == LUA_TSTRING) SDL_strlcpy(a->image, lua_tostring(L, -1), sizeof a->image);
    lua_pop(L, 1);
    lua_getfield(L, -1, "frames");
    int n = lua_istable(L, -1) ? (int)objlen(L, -1) : 0;
    if (n > 0) a->f = SDL_calloc(n, sizeof *a->f);
    for (int i = 1; a->f && i <= n; i++) {
      lua_rawgeti(L, -1, i);
      if (lua_istable(L, -1)) {
        int ft = lua_gettop(L);
        AtlFrame *f = &a->f[a->n++];
        lua_getfield(L, ft, "path");
        if (lua_type(L, -1) == LUA_TSTRING) SDL_strlcpy(f->path, lua_tostring(L, -1), sizeof f->path);
        lua_pop(L, 1);
        lua_getfield(L, ft, "name");
        if (lua_type(L, -1) == LUA_TSTRING) SDL_strlcpy(f->name, lua_tostring(L, -1), sizeof f->name);
        lua_pop(L, 1);
        f->x = (float)fnum(L, ft, "x", 0); f->y = (float)fnum(L, ft, "y", 0);
        f->w = (float)fnum(L, ft, "w", 0); f->h = (float)fnum(L, ft, "h", 0);
        f->deg = (int)fnum(L, ft, "deg", 0);
      }
      lua_pop(L, 1);
    }
  }
  if (L) lua_close(L);
  return a;
}

static const AtlFrame *atlas_find(const Atl *a, const char *frame) {
  size_t fl = SDL_strlen(frame);
  for (int i = 0; i < a->n; i++) if (a->f[i].name[0] && !strcmp(a->f[i].name, frame)) return &a->f[i];
  for (int i = 0; i < a->n; i++) if (!strcmp(a->f[i].path, frame)) return &a->f[i];
  for (int i = 0; i < a->n; i++) {                 // ("ship": ".../ship.png")
    const char *p = a->f[i].path, *dot = SDL_strrchr(p, '.'), *sl = SDL_strrchr(p, '/');
    size_t pl = dot && (!sl || dot > sl) ? (size_t)(dot - p) : SDL_strlen(p);
    if (pl >= fl && !strncmp(p + pl - fl, frame, fl) && (pl == fl || p[pl - fl - 1] == '/')) return &a->f[i];
  }
  return NULL;
}

static void draw_image(Viewer *V, int t, Mat M, Col col) {
  lua_State *L = V->L;
  (void)col;
  const char *name = NULL;
  if (lua_type(L, t) == LUA_TSTRING) name = lua_tostring(L, t);
  else if (lua_istable(L, t)) { lua_rawgeti(L, t, 1); name = lua_tostring(L, -1); lua_pop(L, 1); }
  if (!name) return;
  bool tab = lua_istable(L, t);
  const AtlFrame *fr = NULL;                       // a frame of an atlas
  char sheet[512];
  if (tab) {
    lua_getfield(L, t, "frame");
    const char *fname = lua_tostring(L, -1);
    size_t nl = SDL_strlen(name);
    if (fname && nl > 4 && !SDL_strcasecmp(name + nl - 4, ".lua")) {
      Atl *a = atlas_get(V, name);
      fr = a && a->image[0] ? atlas_find(a, fname) : NULL;
      if (fr) { SDL_strlcpy(sheet, a->image, sizeof sheet); name = sheet; }
    }
    lua_pop(L, 1);
  }
  Tex *tx = tex_get(V, name);
  float sx = 0, sy = 0, sw = tx->tex ? (float)tx->w : 16, sh = tx->tex ? (float)tx->h : 16;   // src: a part of the picture, px
  bool part = false;
  if (fr) { sx = fr->x; sy = fr->y; sw = fr->w; sh = fr->h; part = true; }
  if (tab && !fr) {                                       // src = { x, y, w, h } (an atlas's frame: plugins/atlaspacker)
    lua_getfield(L, t, "src");
    if (lua_istable(L, -1)) {
      int s = lua_gettop(L);
      for (int k = 0; k < 4; k++) {
        lua_rawgeti(L, s, k + 1);
        if (lua_isnumber(L, -1)) { float v = (float)lua_tonumber(L, -1); if (k == 0) sx = v; else if (k == 1) sy = v; else if (k == 2) sw = v; else sh = v; part = true; }
        lua_pop(L, 1);
      }
      sx = (float)fnum(L, s, "x", sx); sy = (float)fnum(L, s, "y", sy); sw = (float)fnum(L, s, "w", sw); sh = (float)fnum(L, s, "h", sh);
      part = true;
    }
    lua_pop(L, 1);
  }
  float w = tab ? (float)fnum(L, t, "w", sw) : sw;
  float h = tab ? (float)fnum(L, t, "h", sh) : sh;
  float ox = 0, oy = 0;                            // at = "sheet": where the part is in the whole picture, centred on the node
  bool turned0 = fr && ((fr->deg % 360 + 360) % 360) == 90;
  if (tab && part && tx->tex) {
    lua_getfield(L, t, "at");
    const char *at = lua_tostring(L, -1);
    if (at && !strcmp(at, "sheet")) {
      float ow = turned0 ? sh : sw, oh = turned0 ? sw : sh;   // (what it takes in the sheet)
      ox = sx + ow / 2 - tx->w / 2.f; oy = sy + oh / 2 - tx->h / 2.f;
    }
    lua_pop(L, 1);
  }
  SDL_FPoint q[4] = { xfa(M, ox - w / 2, oy - h / 2), xfa(M, ox + w / 2, oy - h / 2), xfa(M, ox + w / 2, oy + h / 2), xfa(M, ox - w / 2, oy + h / 2) };
  if (!tx->tex) {                                  // not there (or not an image): a magenta box where it would be
    for (int i = 0; i < 4; i++) pts[i] = q[i];
    pts[4] = q[0];
    draw_poly(V, 5, false, (Col){ 255, 0, 255, 255 });
    return;
  }
  Col tint = { 255, 255, 255, 255 };
  if (tab) {
    lua_getfield(L, t, "color");
    tint = read_color(L, lua_gettop(L), tint);
    lua_pop(L, 1);
  }
  bool smooth = true;
  if (tab) { lua_getfield(L, t, "smooth"); smooth = lua_isnil(L, -1) || lua_toboolean(L, -1); lua_pop(L, 1); }
  if (smooth != tx->smooth) {
    SDL_SetTextureScaleMode(tx->tex, smooth ? SDL_SCALEMODE_LINEAR : SDL_SCALEMODE_NEAREST);
    tx->smooth = smooth;
  }
  SDL_FColor fc = fcol(tint);
  float u0 = 0, v0 = 0, u1 = 1, v1 = 1;
  bool turned = fr && ((fr->deg % 360 + 360) % 360) == 90;   // (kept turned: it takes sh x sw there)
  if (part && tx->w > 0 && tx->h > 0) { u0 = sx / tx->w; v0 = sy / tx->h; u1 = (sx + (turned ? sh : sw)) / tx->w; v1 = (sy + (turned ? sw : sh)) / tx->h; }
  float uv[4][2] = { { u0, v0 }, { u1, v0 }, { u1, v1 }, { u0, v1 } };
  if (turned) {                                    // its top left is the sheet's top right, and so on round
    float r[4][2] = { { u1, v0 }, { u1, v1 }, { u0, v1 }, { u0, v0 } };
    SDL_memcpy(uv, r, sizeof uv);
  }
  SDL_Vertex v[4];
  for (int i = 0; i < 4; i++) {
    v[i].position = q[i]; v[i].color = fc;
    v[i].tex_coord.x = uv[i][0]; v[i].tex_coord.y = uv[i][1];
    acc_add(q[i].x, q[i].y);
  }
  static const int idx[6] = { 0, 1, 2, 0, 2, 3 };
  SDL_RenderGeometry(V->ren, tx->tex, v, 4, idx, 6);
  acc_solid = true;
}

// bullets = { "/assets/spark.png", size = 10, xy = { x1, y1, x2, y2, ... },
//   s = { size1, ... }, rgb = { 0xRRGGBB, ... }, a = { angle1, ... }, o = { 0..1, ... }, color = {...} }:
// many small pictures in one batch (a bullet-hell's bullets: runtime/bullets.lua).
// No picture: soft round dots. s / rgb / a are optional, one a bullet (size,
// tint, turn in radians, opacity); color tints them all. Not pickable one by one.
static SDL_Texture *dot_texture(Viewer *V) {       // a white disc with a soft edge, 32 x 32
  if (g_dot_tex) return g_dot_tex;
  Uint32 px[32 * 32];
  for (int y = 0; y < 32; y++) for (int x = 0; x < 32; x++) {
    float dx = x + 0.5f - 16, dy = y + 0.5f - 16, d = SDL_sqrtf(dx * dx + dy * dy);
    float a = d < 13 ? 1.f : d < 16 ? (16 - d) / 3.f : 0.f;
    px[y * 32 + x] = ((Uint32)(a * 255) << 24) | 0xFFFFFF;
  }
  g_dot_tex = SDL_CreateTexture(V->ren, SDL_PIXELFORMAT_ARGB8888, SDL_TEXTUREACCESS_STATIC, 32, 32);
  if (g_dot_tex) { SDL_UpdateTexture(g_dot_tex, NULL, px, 32 * 4); SDL_SetTextureBlendMode(g_dot_tex, SDL_BLENDMODE_BLEND); }
  return g_dot_tex;
}
static void draw_bullets(Viewer *V, int t, Mat M, Col col) {
  lua_State *L = V->L;
  if (!lua_istable(L, t)) return;
  lua_rawgeti(L, t, 1);
  const char *name = lua_tostring(L, -1);
  lua_pop(L, 1);
  SDL_Texture *tex = NULL;
  if (name) { Tex *tx = tex_get(V, name); tex = tx->tex; }
  if (!tex) tex = dot_texture(V);
  if (!tex) return;
  float size = (float)fnum(L, t, "size", 8);
  float k = SDL_sqrtf(SDL_fabsf(M.a * M.d - M.b * M.c));   // (the node's and the camera's scale)
  lua_getfield(L, t, "color");
  Col tint = read_color(L, lua_gettop(L), col);
  lua_pop(L, 1);
  lua_getfield(L, t, "xy"); int xy = lua_gettop(L);
  lua_getfield(L, t, "s"); int ss = lua_istable(L, -1) ? lua_gettop(L) : 0;
  lua_getfield(L, t, "rgb"); int rgb = lua_istable(L, -1) ? lua_gettop(L) : 0;
  lua_getfield(L, t, "a"); int an = lua_istable(L, -1) ? lua_gettop(L) : 0;
  lua_getfield(L, t, "o"); int op = lua_istable(L, -1) ? lua_gettop(L) : 0;
  int n = lua_istable(L, xy) ? (int)objlen(L, xy) / 2 : 0;
  enum { CHUNK = 512 };                             // (drawn in batches of 512)
  static SDL_Vertex v[CHUNK * 4];
  static int idx[CHUNK * 6];
  static bool idx_made;
  if (!idx_made) {
    for (int i = 0; i < CHUNK; i++) {
      int b = i * 4;
      idx[i * 6] = b; idx[i * 6 + 1] = b + 1; idx[i * 6 + 2] = b + 2;
      idx[i * 6 + 3] = b; idx[i * 6 + 4] = b + 2; idx[i * 6 + 5] = b + 3;
    }
    idx_made = true;
  }
  int m = 0;
  float x0 = 1e30f, y0 = 1e30f, x1 = -1e30f, y1 = -1e30f;
  for (int i = 0; i < n; i++) {
    lua_rawgeti(L, xy, i * 2 + 1); lua_rawgeti(L, xy, i * 2 + 2);
    float x = (float)lua_tonumber(L, -2), y = (float)lua_tonumber(L, -1);
    lua_pop(L, 2);
    float sz = size, ang = 0;
    Col c = tint;
    if (ss) { lua_rawgeti(L, ss, i + 1); if (lua_isnumber(L, -1)) sz = (float)lua_tonumber(L, -1); lua_pop(L, 1); }
    if (an) { lua_rawgeti(L, an, i + 1); if (lua_isnumber(L, -1)) ang = (float)lua_tonumber(L, -1); lua_pop(L, 1); }
    if (op) {
      lua_rawgeti(L, op, i + 1);
      if (lua_isnumber(L, -1)) { float o = (float)lua_tonumber(L, -1); c.a = (Uint8)(c.a * (o < 0 ? 0 : o > 1 ? 1 : o)); }
      lua_pop(L, 1);
    }
    if (rgb) {
      lua_rawgeti(L, rgb, i + 1);
      if (lua_isnumber(L, -1)) {
        Uint32 h = (Uint32)lua_tonumber(L, -1);
        c.r = (Uint8)((((h >> 16) & 255) * tint.r) / 255); c.g = (Uint8)((((h >> 8) & 255) * tint.g) / 255); c.b = (Uint8)(((h & 255) * tint.b) / 255);
      }
      lua_pop(L, 1);
    }
    SDL_FPoint p = xf(M, x, y);
    float hs = sz * k / 2, ca = SDL_cosf(ang) * hs, sa = SDL_sinf(ang) * hs;
    SDL_FColor fc = fcol(c);
    SDL_FPoint q[4] = { { p.x - ca + sa, p.y - sa - ca }, { p.x + ca + sa, p.y + sa - ca },
                        { p.x + ca - sa, p.y + sa + ca }, { p.x - ca - sa, p.y - sa + ca } };
    static const float UV[4][2] = { { 0, 0 }, { 1, 0 }, { 1, 1 }, { 0, 1 } };
    for (int j = 0; j < 4; j++) {
      SDL_Vertex *vv = &v[m * 4 + j];
      vv->position = q[j]; vv->color = fc; vv->tex_coord.x = UV[j][0]; vv->tex_coord.y = UV[j][1];
    }
    if (p.x < x0) x0 = p.x;
    if (p.y < y0) y0 = p.y;
    if (p.x > x1) x1 = p.x;
    if (p.y > y1) y1 = p.y;
    if (++m == CHUNK) { SDL_RenderGeometry(V->ren, tex, v, m * 4, idx, m * 6); m = 0; }
  }
  if (m) SDL_RenderGeometry(V->ren, tex, v, m * 4, idx, m * 6);
  lua_settop(L, xy - 1);
  (void)x0; (void)y0; (void)x1; (void)y1;          // (not pickable: a bullet isn't something to select)
}

// tilemap = { "/assets/level.tmap", layer = "ground", size = 16, color = {...} }:
// a layer of a tile map (plugins/tilemap: its .tmap file, plain data read in a
// Lua state of its own, again when it changes: edit the map, the game shows
// it). layer: its name or its index (default: the first). Drawn from the
// node's origin, a cell `size` world units (default: the tile's px), its
// tileset beside the .tmap ("tiles.png" -> assets/<the map's folder>/tiles.png),
// or the tilemap plugin's ("plugin:tiles.png": plugins/tilemap/tiles.png, exported with the game).
typedef struct { char name[64]; Uint16 *cells; } TmLayer;
typedef struct { char file[1024], tileset[512]; int tile, w, h, n; TmLayer *l; SDL_Time mtime; Uint64 checked; } Tmap;
static Tmap tmaps[16];
static int ntmaps;

static void tmap_free(Tmap *m) {
  for (int i = 0; i < m->n; i++) SDL_free(m->l[i].cells);
  SDL_free(m->l); m->l = NULL; m->n = 0;
}
static Tmap *tmap_get(Viewer *V, const char *name) {
  char file[1024];
  tex_file(V, name, file, sizeof file);
  Tmap *m = NULL;
  for (int i = 0; i < ntmaps && !m; i++) if (!strcmp(tmaps[i].file, file)) m = &tmaps[i];
  if (!m) {
    if (ntmaps == (int)(sizeof tmaps / sizeof tmaps[0])) { for (int i = 0; i < ntmaps; i++) tmap_free(&tmaps[i]); ntmaps = 0; }
    m = &tmaps[ntmaps++];
    SDL_zerop(m);
    SDL_strlcpy(m->file, file, sizeof m->file);
  }
  Uint64 now = SDL_GetTicks();
  if (m->checked && now - m->checked < 1000) return m;
  m->checked = now;
  SDL_PathInfo pi;
  SDL_Time mt = SDL_GetPathInfo(file, &pi) ? pi.modify_time : 0;
  if (mt == m->mtime && m->l) return m;
  m->mtime = mt;
  tmap_free(m);
  m->tileset[0] = 0;
  lua_State *L = luaL_newstate();                  // (no libraries: data only)
  if (L && luaL_loadfilex(L, file, "t") == LUA_OK && lua_pcall(L, 0, 1, 0) == LUA_OK && lua_istable(L, -1)) {
    int t = lua_gettop(L);
    m->tile = (int)fnum(L, t, "tile", 16); m->w = (int)fnum(L, t, "w", 0); m->h = (int)fnum(L, t, "h", 0);
    if (m->tile < 1) m->tile = 16;
    lua_getfield(L, t, "tileset");
    const char *ts = lua_tostring(L, -1);
    if (ts && !strncmp(ts, "plugin:", 7)) SDL_strlcpy(m->tileset, ts, sizeof m->tileset);   // (the tilemap plugin's own: tex_file finds it)
    else if (ts) {                                 // beside the map: its folder under assets/
      char dir[512];
      SDL_strlcpy(dir, name, sizeof dir);
      char *sl = SDL_strrchr(dir, '/');
      if (sl) sl[1] = 0; else dir[0] = 0;
      SDL_snprintf(m->tileset, sizeof m->tileset, "%s%s", dir, ts);
    }
    lua_pop(L, 1);
    lua_getfield(L, t, "layers");
    int nl = lua_istable(L, -1) ? (int)objlen(L, -1) : 0;
    if (nl > 0 && m->w > 0 && m->h > 0 && m->w <= 4096 && m->h <= 4096) m->l = SDL_calloc(nl, sizeof *m->l);
    for (int i = 1; m->l && i <= nl; i++) {
      lua_rawgeti(L, -1, i);
      if (lua_istable(L, -1)) {
        int lt = lua_gettop(L);
        TmLayer *ly = &m->l[m->n++];
        lua_getfield(L, lt, "name");
        if (lua_type(L, -1) == LUA_TSTRING) SDL_strlcpy(ly->name, lua_tostring(L, -1), sizeof ly->name);
        lua_pop(L, 1);
        ly->cells = SDL_malloc(sizeof(Uint16) * m->w * m->h);
        for (int k = 0; k < m->w * m->h; k++) ly->cells[k] = 0xFFFF;
        lua_getfield(L, lt, "rows");
        for (int y = 0; lua_istable(L, -1) && y < m->h; y++) {
          lua_rawgeti(L, -1, y + 1);
          size_t len = 0;
          const char *row = lua_type(L, -1) == LUA_TSTRING ? lua_tolstring(L, -1, &len) : "";
          for (int x = 0; x < m->w && (size_t)(x * 2 + 1) < len; x++) {
            char hx[3] = { row[x * 2], row[x * 2 + 1], 0 };
            if (SDL_isxdigit(hx[0]) && SDL_isxdigit(hx[1])) ly->cells[y * m->w + x] = (Uint16)SDL_strtol(hx, NULL, 16);
          }
          lua_pop(L, 1);
        }
        lua_pop(L, 1);
      }
      lua_pop(L, 1);
    }
  }
  if (L) lua_close(L);
  return m;
}

// the cells of a tile map (w x h, 0xFFFF: none) drawn from a tileset
static void draw_cells(Viewer *V, Mat M, const Uint16 *cells, int w, int h, int tile, float cs, Col tint, const char *tileset) {
  Tex *tx = tileset && tileset[0] ? tex_get(V, tileset) : NULL;
  if (!tx || !tx->tex) {                           // (no tileset: its outline in magenta)
    SDL_FPoint q[4] = { xfa(M, 0, 0), xfa(M, w * cs, 0), xfa(M, w * cs, h * cs), xfa(M, 0, h * cs) };
    for (int i = 0; i < 4; i++) pts[i] = q[i];
    pts[4] = q[0];
    draw_poly(V, 5, false, (Col){ 255, 0, 255, 255 });
    return;
  }
  if (tx->smooth) { SDL_SetTextureScaleMode(tx->tex, SDL_SCALEMODE_NEAREST); tx->smooth = false; }   // (pixel art: crisp)
  int cols = tx->w / tile;
  if (cols < 1) return;
  static SDL_Vertex *vb; static int *ib; static int cap;
  int nq = 0;
  for (int k = 0; k < w * h; k++) if (cells[k] != 0xFFFF) nq++;
  if (nq == 0) return;
  if (nq > cap) { cap = nq + 256; vb = SDL_realloc(vb, sizeof *vb * cap * 4); ib = SDL_realloc(ib, sizeof *ib * cap * 6); }
  SDL_FColor fc = fcol(tint);
  float iw = 1.f / tx->w, ih = 1.f / tx->h;
  int q = 0;
  for (int y = 0; y < h; y++) for (int x = 0; x < w; x++) {
    Uint16 c = cells[y * w + x];
    if (c == 0xFFFF) continue;
    float u0 = (c % cols) * tile * iw, v0 = (c / cols) * tile * ih, u1 = u0 + tile * iw, v1 = v0 + tile * ih;
    SDL_FPoint p[4] = { xfa(M, x * cs, y * cs), xfa(M, (x + 1) * cs, y * cs), xfa(M, (x + 1) * cs, (y + 1) * cs), xfa(M, x * cs, (y + 1) * cs) };
    float uv[4][2] = { { u0, v0 }, { u1, v0 }, { u1, v1 }, { u0, v1 } };
    for (int i = 0; i < 4; i++) { vb[q * 4 + i].position = p[i]; vb[q * 4 + i].color = fc; vb[q * 4 + i].tex_coord.x = uv[i][0]; vb[q * 4 + i].tex_coord.y = uv[i][1]; }
    static const int I[6] = { 0, 1, 2, 0, 2, 3 };
    for (int i = 0; i < 6; i++) ib[q * 6 + i] = q * 4 + I[i];
    q++;
  }
  SDL_RenderGeometry(V->ren, tx->tex, vb, q * 4, ib, q * 6);
  acc_add(xfa(M, 0, 0).x, xfa(M, 0, 0).y);         // (picking: the map's whole rectangle)
  acc_add(xfa(M, w * cs, h * cs).x, xfa(M, w * cs, h * cs).y);
  acc_solid = true;
}

// tilemap = { rows = { "0001..", ... }, tileset = "plugin:tiles.png", tile = 16, size = 16 }:
// a layer given in place (a game that makes its maps as it plays: the
// dungeon / terrain generators' data), its rows as a .tmap writes them
static void draw_tilemap_rows(Viewer *V, int t, Mat M) {
  lua_State *L = V->L;
  lua_getfield(L, t, "rows");
  int r = lua_gettop(L);
  int h = (int)objlen(L, r), w = 0;
  if (h > 0) { size_t n0 = 0; lua_rawgeti(L, r, 1); lua_tolstring(L, -1, &n0); w = (int)(n0 / 2); lua_pop(L, 1); }
  if (w <= 0 || h <= 0 || w > 1024 || h > 1024) { lua_settop(L, r - 1); return; }
  static Uint16 *cells; static int ccap;
  if (w * h > ccap) { ccap = w * h; cells = SDL_realloc(cells, sizeof *cells * ccap); }
  for (int y = 0; y < h; y++) {
    lua_rawgeti(L, r, y + 1);
    size_t n = 0;
    const char *row = lua_tolstring(L, -1, &n);
    for (int x = 0; x < w; x++) {
      Uint16 v = 0xFFFF;
      if (row && (size_t)(x * 2 + 1) < n && row[x * 2] != '.') {
        char hx[3] = { row[x * 2], row[x * 2 + 1], 0 };
        v = (Uint16)SDL_strtol(hx, NULL, 16);
      }
      cells[y * w + x] = v;
    }
    lua_pop(L, 1);
  }
  lua_settop(L, r - 1);
  int tile = (int)fnum(L, t, "tile", 16);
  if (tile < 1) tile = 16;
  float cs = (float)fnum(L, t, "size", tile);
  Col tint = { 255, 255, 255, 255 };
  lua_getfield(L, t, "color"); tint = read_color(L, lua_gettop(L), tint); lua_pop(L, 1);
  lua_getfield(L, t, "tileset");
  char ts[512];
  SDL_strlcpy(ts, lua_isstring(L, -1) ? lua_tostring(L, -1) : "plugin:tiles.png", sizeof ts);
  lua_pop(L, 1);
  draw_cells(V, M, cells, w, h, tile, cs, tint, ts);
}

static void draw_tilemap(Viewer *V, int t, Mat M, Col col) {
  lua_State *L = V->L;
  (void)col;
  if (lua_istable(L, t)) {                         // (rows in place: no file)
    lua_getfield(L, t, "rows");
    bool inl = lua_istable(L, -1);
    lua_pop(L, 1);
    if (inl) { draw_tilemap_rows(V, t, M); return; }
  }
  const char *name = NULL;
  if (lua_type(L, t) == LUA_TSTRING) name = lua_tostring(L, t);
  else if (lua_istable(L, t)) { lua_rawgeti(L, t, 1); name = lua_tostring(L, -1); lua_pop(L, 1); }
  if (!name) return;
  Tmap *m = tmap_get(V, name);
  if (!m->l || m->n == 0) return;
  int li = 0;                                      // which layer: its name, or its index
  if (lua_istable(L, t)) {
    lua_getfield(L, t, "layer");
    if (lua_type(L, -1) == LUA_TNUMBER) li = (int)lua_tointeger(L, -1) - 1;
    else if (lua_type(L, -1) == LUA_TSTRING) { li = -1; for (int i = 0; i < m->n; i++) if (!strcmp(m->l[i].name, lua_tostring(L, -1))) li = i; }
    lua_pop(L, 1);
  }
  if (li < 0 || li >= m->n) return;
  float cs = lua_istable(L, t) ? (float)fnum(L, t, "size", m->tile) : (float)m->tile;
  Col tint = { 255, 255, 255, 255 };
  if (lua_istable(L, t)) { lua_getfield(L, t, "color"); tint = read_color(L, lua_gettop(L), tint); lua_pop(L, 1); }
  draw_cells(V, M, m->l[li].cells, m->w, m->h, m->tile, cs, tint, m->tileset);
}

static void draw_gizmo(Viewer *V, Mat M, const char *name) {
  SDL_FPoint o = xf(M, 0, 0), ax = xf(M, 12, 0), ay = xf(M, 0, 12);
  SDL_SetRenderDrawColor(V->ren, 255, 80, 80, 255);
  SDL_RenderLine(V->ren, o.x, o.y, ax.x, ax.y);
  SDL_SetRenderDrawColor(V->ren, 80, 255, 80, 255);
  SDL_RenderLine(V->ren, o.x, o.y, ay.x, ay.y);
  SDL_SetRenderDrawColor(V->ren, 150, 150, 170, 255);
  SDL_RenderDebugText(V->ren, o.x + 4, o.y + 4, name);
}

// ---------------------------------------------------------------------------
// tree traversal
// ---------------------------------------------------------------------------

// ref: 0 = normal node, 1 = root of a `ref` instance, 2 = inside an instance
// Draw order: layers. A node's `layer` component (a name; else its
// parent's; the root's: "default") puts it, and what's below it, in that
// layer; /data/layers' `order` lists the layers bottom to top (unlisted ones
// after, by name: runtime/boot.lua viewer_layers). One pass a layer, each in
// tree order; with one layer (none set), one pass as before.
static char g_lay_names[16][32];
static int g_nlay, g_lay_pass = -1, g_lay_inh;
static int layer_index(const char *name) {
  for (int i = 0; i < g_nlay; i++) if (!strcmp(g_lay_names[i], name)) return i;
  return g_lay_inh;
}

static void draw_node(Viewer *V, int node, Mat parent, Col pcol, int depth, int ref) {
  lua_State *L = V->L;
  if (depth > 64 || !lua_checkstack(L, 16)) return;
  node = absidx(L, node);
  int top = lua_gettop(L);

  lua_getfield(L, node, "c");
  int c = lua_gettop(L);
  if (!lua_istable(L, c)) { lua_settop(L, top); return; }
  if (fbool(L, c, "hidden") && ref != 1) { lua_settop(L, top); return; }
  int lay = g_lay_inh;                             // its layer: its own, or its parent's
  if (g_nlay > 1) {
    lua_getfield(L, c, "layer");
    if (lua_type(L, -1) == LUA_TSTRING) lay = layer_index(lua_tostring(L, -1));
    lua_pop(L, 1);
  }
  bool mine = g_lay_pass < 0 || lay == g_lay_pass; // (this pass draws it, or only goes through it)

  // transform
  Mat M = parent;
  bool has_xf = false;
  lua_getfield(L, c, "xform");
  if (!lua_istable(L, -1)) { lua_pop(L, 1); lua_getfield(L, c, "pos"); }
  if (lua_istable(L, -1)) {
    int t = lua_gettop(L);
    float x = (float)fnum(L, t, "x", 0), y = (float)fnum(L, t, "y", 0);
    float r = (float)fnum(L, t, "r", 0), s = (float)fnum(L, t, "s", 1);
    float sx = (float)fnum(L, t, "sx", s), sy = (float)fnum(L, t, "sy", s);
    Mat Lm = { cosf(r) * sx, sinf(r) * sx, -sinf(r) * sy, cosf(r) * sy, x, y };
    M = mat_mul(parent, Lm);
    has_xf = true;
  }
  lua_pop(L, 1);

  // color
  lua_getfield(L, c, "color");
  Col col = read_color(L, lua_gettop(L), pcol);
  lua_pop(L, 1);

  // visuals
  static const struct { const char *k; void (*fn)(Viewer *, int, Mat, Col); } VIS[] = {
    { "tris", draw_tris }, { "rect", draw_rect }, { "circle", draw_circle },
    { "tilemap", draw_tilemap },
    { "lines", draw_lines }, { "sprite", draw_sprite }, { "image", draw_image }, { "text", draw_text },
    { "bullets", draw_bullets },
  };
  bool drew = false;
  acc_reset();
  for (size_t i = 0; mine && i < sizeof VIS / sizeof VIS[0]; i++) {
    lua_getfield(L, c, VIS[i].k);
    if (!lua_isnil(L, -1)) { VIS[i].fn(V, lua_gettop(L), M, col); drew = true; }
    lua_pop(L, 1);
  }
  lua_getfield(L, node, "path");
  const char *mypath = lua_tostring(L, -1);        // stays alive in the node table
  lua_pop(L, 1);
  if (drew && mypath)
    pick_add(mypath, ref ? cur_via : NULL, ref ? cur_cls : NULL, acc_x0, acc_y0, acc_x1, acc_y1,
             acc_solid, acc_seg0, nsegs, 0, 0);

  // bounds: an explicit picking shape in node space
  lua_getfield(L, c, "bounds");
  if (mine && lua_istable(L, -1) && mypath) {
    int b = lua_gettop(L);
    SDL_FPoint q[32];
    int n = 0;
    float r = (float)fnum(L, b, "r", 0);
    if (r > 0) {                                    // circle
      float cx = (float)fnum(L, b, "x", 0), cy = (float)fnum(L, b, "y", 0);
      for (n = 0; n < 32; n++) {
        float a = n / 32.f * 6.2831853f;
        q[n] = xf(M, cx + r * cosf(a), cy + r * sinf(a));
      }
    } else {                                        // box
      float bw = (float)fnum(L, b, "w", 0), bh = (float)fnum(L, b, "h", 0);
      float bx = (float)fnum(L, b, "x", -bw / 2), by = (float)fnum(L, b, "y", -bh / 2);
      if (bw > 0 && bh > 0) {
        q[0] = xf(M, bx, by); q[1] = xf(M, bx + bw, by);
        q[2] = xf(M, bx + bw, by + bh); q[3] = xf(M, bx, by + bh);
        n = 4;
      }
    }
    if (n) {
      float x0 = 1e30f, y0 = 1e30f, x1 = -1e30f, y1 = -1e30f;
      for (int i = 0; i < n; i++) {
        if (q[i].x < x0) x0 = q[i].x;
        if (q[i].y < y0) y0 = q[i].y;
        if (q[i].x > x1) x1 = q[i].x;
        if (q[i].y > y1) y1 = q[i].y;
      }
      if (fbool(L, b, "aabb")) {                    // screen-aligned box around it
        q[0].x = x0; q[0].y = y0; q[1].x = x1; q[1].y = y0;
        q[2].x = x1; q[2].y = y1; q[3].x = x0; q[3].y = y1;
        n = 4;
      }
      int p0 = npolys;
      acc_poly(q, n);
      pick_add(mypath, ref ? cur_via : NULL, ref ? cur_cls : NULL, x0 + 2, y0 + 2, x1 - 2, y1 - 2,
               false, 0, 0, p0, npolys);
      if (npicks && picks[npicks - 1].poly0 == p0) picks[npicks - 1].bounded = true;
    }
  }
  lua_pop(L, 1);

  // ref: instance another node (and its subtree) with our transform
  lua_getfield(L, c, "ref");
  if (lua_type(L, -1) == LUA_TSTRING) {
    const char *path = lua_tostring(L, -1);
    if (world_call(V, "node", 0, path) && lua_istable(L, -1)) {
      char saved[256], saved_cls[256];
      SDL_strlcpy(saved, cur_via, sizeof saved);
      SDL_strlcpy(saved_cls, cur_cls, sizeof saved_cls);
      if (ref == 0 && mypath) {                     // outermost instance and its class
        SDL_strlcpy(cur_via, mypath, sizeof cur_via);
        SDL_strlcpy(cur_cls, path, sizeof cur_cls);
      }
      int inh = g_lay_inh;
      g_lay_inh = lay;
      draw_node(V, -1, M, col, depth + 1, 1);
      g_lay_inh = inh;
      SDL_strlcpy(cur_via, saved, sizeof cur_via);
      SDL_strlcpy(cur_cls, saved_cls, sizeof cur_cls);
      drew = true;
    }
    lua_pop(L, 1);
  }
  lua_pop(L, 1);
  if (drew) V->drawn++;

  // gizmos (dev UI only): placed nodes with nothing to draw; with the toolbar's
  // Gizmos on, the selected nodes and everything under them too (/: all)
  if (mine && has_xf && ref == 0 && !V->standalone && ((V->gizmos && gizmo_wanted(V, mypath)) || !drew) && g_alpha >= 1.f) {   // (not a ghost's)
    lua_getfield(L, node, "name");
    draw_gizmo(V, M, lua_tostring(L, -1) ? lua_tostring(L, -1) : "?");
    lua_pop(L, 1);
    if (!drew && mypath) {                          // markers are clickable too
      SDL_FPoint o = xf(M, 0, 0);
      pick_add(mypath, NULL, NULL, o.x - 6, o.y - 6, o.x + 14, o.y + 14, true, 0, 0, 0, 0);
    }
  }

  // children, in sorted order (in our layer, unless they say otherwise)
  int inh = g_lay_inh;
  g_lay_inh = lay;
  if (world_call(V, "children", node, NULL) && lua_istable(L, -1)) {
    int kids = lua_gettop(L), n = (int)objlen(L, kids);
    for (int i = 1; i <= n; i++) {
      lua_rawgeti(L, kids, i);
      bool live = true;                            // the root's children: only /o and /e are drawn (the layout; ecs: World:live)
      if (depth == 0 && ref == 0) {
        lua_getfield(L, -1, "path");
        const char *cp = lua_tostring(L, -1);
        if (cp && world_call(V, "live", 0, cp)) live = lua_toboolean(L, -1);
        lua_pop(L, 2);
      }
      if (live) draw_node(V, -1, M, col, depth + 1, ref ? 2 : 0);
      lua_pop(L, 1);
    }
  }
  g_lay_inh = inh;
  lua_settop(L, top);
}

// a world's tree, from its root (on the stack at `node`): one pass a layer
static void draw_layers(Viewer *V, int node, Mat cam, Col col) {
  lua_State *L = V->L;
  node = absidx(L, node);
  g_nlay = 0;
  int def = 0;
  lua_getglobal(L, "viewer_layers");               // the layers' names, bottom to top
  lua_rawgeti(L, LUA_REGISTRYINDEX, V->world);
  if (lua_pcall(L, 1, 1, 0) == 0 && lua_istable(L, -1)) {
    int n = (int)objlen(L, -1);
    for (int i = 1; i <= n && g_nlay < 16; i++) {
      lua_rawgeti(L, -1, i);
      if (lua_isstring(L, -1)) {
        SDL_strlcpy(g_lay_names[g_nlay], lua_tostring(L, -1), sizeof g_lay_names[0]);
        if (!strcmp(g_lay_names[g_nlay], "default")) def = g_nlay;
        g_nlay++;
      }
      lua_pop(L, 1);
    }
  }
  lua_pop(L, 1);
  g_lay_inh = def;
  if (g_nlay <= 1) { g_lay_pass = -1; draw_node(V, node, cam, col, 0, 0); return; }
  for (int p = 0; p < g_nlay; p++) { g_lay_pass = p; g_lay_inh = def; draw_node(V, node, cam, col, 0, 0); }
  g_lay_pass = -1;
}
