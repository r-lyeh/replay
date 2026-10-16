// editor/export.h - Export: the open game, ready to share (the toolbar's
// second button: a box with an arrow out of it).
// Part of replay.c: included once, in order, from there (one compilation unit).
//
// A click asks for a folder (the system's folder dialog), then puts there:
//   <name>.exe          this exe, renamed (elsewhere: <name>, or <name>.bin
//                       beside a folder <name>/): with no .c files beside it, it's a
//                       packaged game (runs standalone) and opens <name>/ or
//                       <name>.lua beside it (see main: the exe's name)
//   *.dll               the libraries beside this exe (SDL3.dll)
//   <name>.png          its icon: <game>/<name>.png, else games/<name>.png,
//                       else play.png (Replay's, beside this exe)
//   runtime/            the modules a game loads: runtime/*.lua (not
//                       template.lua), runtime/hurdyl/ and runtime/msgpack/
//                       (not tests/, meta/)
//   <name>/             a folder world (not its dot files: .workspace.lua...),
//   or <name>.lua       or a script (.hurdy too) and its <name>.overrides.lua,
//   and common/         and the folder of art the scripts share (games/common/)
//   plugins/tilemap/tiles.png   the tilemap plugin's tileset (maps made with
//                       it say "plugin:tiles.png": the dungeon and terrain generators')
//   plugins/*/gen.lua   the generators (no Lite in them): a game runs them with w:generate
// It works from the disk: unsaved edits aren't in it (the message says so).
// Before asking where: the game stops (if playing), and every Lua file it
// reads must compile as it is on disk (play_check, the editor's unsaved
// texts left out); one that doesn't: shown in the editor, a message box,
// no export. (Free disk space isn't checked: SDL3 can't tell, see
// ROADMAP.md.)
// Then it says how it went, gently: OK (where, how many files) or FAIL (what
// failed; nothing outside that folder was touched), in the log and a
// message box, after a beep (later, exporting may take minutes: whoever
// started it may be away).
// Test hook: --export-dir DIR (no dialog, no message box: the log only).

#ifndef _WIN32
#include <sys/stat.h>                              // chmod: the exe, executable
#endif
#ifdef _WIN32
#define EXPORT_SEP "\\"                            // (paths in the message: as Windows writes them)
#else
#define EXPORT_SEP "/"
#endif
static char g_export_dir_arg[1024];              // --export-dir: the folder, no dialog
static char g_export_last[1024];                 // the folder picked last (the dialog starts there)
static char g_export_pick[1024];                 // the dialog's answer (its thread -> ours)
// (g_export_state, in bar.h: 0 idle, 1 asking, 2 an answer: g_export_pick, "" cancelled)
static char g_export_root[1024];                 // where runtime/ is (this exe's folder, or the cwd; declared in render.h too)

// a beep: the system's own sound, from a short-lived process (SDL has no
// beeper); a terminal bell if that can't start
static void app_beep(void) {
#if defined(_WIN32)
  const char *args[] = { "rundll32", "user32.dll,MessageBeep", NULL };
#elif defined(__APPLE__)
  const char *args[] = { "afplay", "/System/Library/Sounds/Glass.aiff", NULL };
#else
  const char *args[] = { "paplay", "/usr/share/sounds/freedesktop/stereo/complete.oga", NULL };
#endif
  SDL_Process *p = SDL_CreateProcess(args, false);
  if (p) SDL_DestroyProcess(p);                  // (it plays on: we don't wait for it)
  else { fputc('\a', stdout); fflush(stdout); }
}

typedef struct {
  int files;
  Uint64 bytes;
  char err[600];
} ExportRun;

static bool export_file(ExportRun *x, const char *from, const char *to) {
  if (!SDL_CopyFile(from, to)) {
    char why[300];
    SDL_strlcpy(why, SDL_GetError(), sizeof why);
    size_t wl = strlen(why);
    while (wl > 0 && (why[wl - 1] == '.' || why[wl - 1] == ' ')) why[--wl] = 0;   // (its own full stop: ours ends it)
    SDL_snprintf(x->err, sizeof x->err, "couldn't copy %s to %s (%s)", from, to, why);
    return false;
  }
  SDL_PathInfo pi;
  if (SDL_GetPathInfo(to, &pi)) x->bytes += pi.size;
  x->files++;
  return true;
}

typedef struct { ExportRun *x; const char *to; bool ok; } TreeCopy;
static bool export_tree(ExportRun *x, const char *from, const char *to);
static SDL_EnumerationResult export_tree_cb(void *ud, const char *dir, const char *name) {
  TreeCopy *t = (TreeCopy *)ud;
  if (name[0] == '.') return SDL_ENUM_CONTINUE;  // (.workspace.lua, .log.txt...: the editor's, not the game's)
  const char *ext = SDL_strrchr(name, '.');
  if (ext && !SDL_strcasecmp(ext, ".sav")) return SDL_ENUM_CONTINUE;   // (saves/*.sav: this machine's savegames, not shipped)
  char src[1024], dst[1024];
  SDL_snprintf(src, sizeof src, "%s%s", dir, name);
  SDL_snprintf(dst, sizeof dst, "%s" EXPORT_SEP "%s", t->to, name);
  SDL_PathInfo pi;
  if (!SDL_GetPathInfo(src, &pi)) return SDL_ENUM_CONTINUE;
  t->ok = pi.type == SDL_PATHTYPE_DIRECTORY ? export_tree(t->x, src, dst) : export_file(t->x, src, dst);
  return t->ok ? SDL_ENUM_CONTINUE : SDL_ENUM_FAILURE;
}
static bool export_tree(ExportRun *x, const char *from, const char *to) {   // a folder, all of it (not dot files)
  if (!SDL_CreateDirectory(to)) {
    SDL_snprintf(x->err, sizeof x->err, "couldn't make the folder %s: %s", to, SDL_GetError());
    return false;
  }
  TreeCopy t = { x, to, true };
  SDL_EnumerateDirectory(from, export_tree_cb, &t);
  return t.ok;
}

typedef struct { ExportRun *x; const char *to; const char *ext; bool ok; } GlobCopy;
static SDL_EnumerationResult export_glob_cb(void *ud, const char *dir, const char *name) {   // the files with that extension
  GlobCopy *g = (GlobCopy *)ud;
  const char *ext = SDL_strrchr(name, '.');
  if (!ext || SDL_strcasecmp(ext, g->ext) || name[0] == '.') return SDL_ENUM_CONTINUE;
  if (!strcmp(name, "template.lua")) return SDL_ENUM_CONTINUE;   // (the new-project template: the editor's)
  char src[1024], dst[1024];
  SDL_snprintf(src, sizeof src, "%s%s", dir, name);
  SDL_PathInfo pi;
  if (!SDL_GetPathInfo(src, &pi) || pi.type != SDL_PATHTYPE_FILE) return SDL_ENUM_CONTINUE;
  SDL_snprintf(dst, sizeof dst, "%s" EXPORT_SEP "%s", g->to, name);
  g->ok = export_file(g->x, src, dst);
  return g->ok ? SDL_ENUM_CONTINUE : SDL_ENUM_FAILURE;
}
static bool export_glob(ExportRun *x, const char *dir, const char *ext, const char *to) {
  GlobCopy g = { x, to, ext, true };
  SDL_EnumerateDirectory(dir, export_glob_cb, &g);
  return g.ok;
}

// the game's name: its folder's, or its script's without the extension
static void export_name(const Viewer *V, char *out, size_t n) {
  char p[1024];
  SDL_strlcpy(p, V->path, sizeof p);
  size_t len = strlen(p);
  while (len > 1 && (p[len - 1] == '/' || p[len - 1] == '\\')) p[--len] = 0;
  const char *b = p;
  for (const char *c = p; *c; c++) if (*c == '/' || *c == '\\') b = c + 1;
  SDL_strlcpy(out, b, n);
  if (!V->isdir) { char *dot = SDL_strrchr(out, '.'); if (dot && dot != out) *dot = 0; }
}

// a folder's path, to compare: '\\' as '/', no trailing '/', lower case
static void export_norm(const char *p, char *out, size_t n) {
  SDL_strlcpy(out, p, n);
  for (char *c = out; *c; c++) *c = *c == '\\' ? '/' : (char)SDL_tolower((unsigned char)*c);
  size_t l = strlen(out);
  while (l > 1 && out[l - 1] == '/') out[--l] = 0;
}

// the export itself -> ok; x: what it copied, or why it failed
static bool export_to(Viewer *V, const char *dest, const char *name, ExportRun *x) {
  char d[1024], to[1024], from[1024];
  SDL_strlcpy(d, dest, sizeof d);
  size_t dl = strlen(d);
  while (dl > 1 && (d[dl - 1] == '/' || d[dl - 1] == '\\')) d[--dl] = 0;
  {                                                // not the editor's own folder, nor inside the game
    char nd[1024], nb[1024], ng[1024];
    export_norm(d, nd, sizeof nd);
    export_norm(g_export_root, nb, sizeof nb);
    export_norm(V->path, ng, sizeof ng);
    size_t gl = strlen(ng);
    if (!strcmp(nd, nb)) { SDL_snprintf(x->err, sizeof x->err, "that's the editor's own folder: pick an empty one"); return false; }
    if (V->isdir && !strncmp(nd, ng, gl) && (nd[gl] == 0 || nd[gl] == '/')) {
      SDL_snprintf(x->err, sizeof x->err, "that folder is inside the game: pick one outside it"); return false;
    }
  }
  if (!SDL_CreateDirectory(d)) { SDL_snprintf(x->err, sizeof x->err, "couldn't use the folder %s: %s", d, SDL_GetError()); return false; }
  // the exe, renamed (its extension kept: .exe on Windows, none elsewhere)
  const char *ext = SDL_strrchr(launch_exe, '.');
  const char *slash = SDL_strrchr(launch_exe, '/');
  const char *bslash = SDL_strrchr(launch_exe, '\\');
  if (ext && ((slash && ext < slash) || (bslash && ext < bslash))) ext = NULL;
  if (!ext && V->isdir) ext = ".bin";             // (no .exe here: pong/ and a file pong can't share a name)
  SDL_snprintf(to, sizeof to, "%s" EXPORT_SEP "%s%s", d, name, ext ? ext : "");
  if (!export_file(x, launch_exe, to)) return false;
#ifndef _WIN32
  chmod(to, 0755);                                 // (a copy isn't executable elsewhere: it must run)
#endif
  // the libraries beside it
  const char *base = SDL_GetBasePath();
  if (base && !export_glob(x, base, ".dll", d)) return false;
  // the icon
  {
    char dir[1024], cand[3][1100];
    SDL_strlcpy(dir, V->path, sizeof dir);
    size_t n = strlen(dir);
    while (n > 1 && (dir[n - 1] == '/' || dir[n - 1] == '\\')) dir[--n] = 0;
    char *cut = SDL_strrchr(dir, '/'), *cut2 = SDL_strrchr(dir, '\\');
    if (cut2 > cut) cut = cut2;
    if (cut) *cut = 0;                             // the folder the game is in (games/)
    if (V->isdir) SDL_snprintf(cand[0], sizeof cand[0], "%s" EXPORT_SEP "%s.png", V->path, name);
    else cand[0][0] = 0;
    SDL_snprintf(cand[1], sizeof cand[1], "%s" EXPORT_SEP "%s.png", dir, name);
    SDL_snprintf(cand[2], sizeof cand[2], "%splay.png", base ? base : "");
    SDL_snprintf(to, sizeof to, "%s" EXPORT_SEP "%s.png", d, name);
    for (int i = 0; i < 3; i++) {
      if (cand[i][0] && exists(cand[i])) { if (!export_file(x, cand[i], to)) return false; break; }
    }
  }
  // runtime/: the modules
  SDL_snprintf(from, sizeof from, "%sruntime/", g_export_root);
  SDL_snprintf(to, sizeof to, "%s" EXPORT_SEP "runtime", d);
  if (!SDL_CreateDirectory(to)) { SDL_snprintf(x->err, sizeof x->err, "couldn't make the folder %s: %s", to, SDL_GetError()); return false; }
  if (!export_glob(x, from, ".lua", to)) return false;
  SDL_PathInfo pi;
  static const char *SUB[] = { "hurdyl", "msgpack" };  // (its folders: hurdy's compiler, the network's MessagePack)
  for (int i = 0; i < 2; i++) {
    SDL_snprintf(from, sizeof from, "%sruntime/%s", g_export_root, SUB[i]);
    if (SDL_GetPathInfo(from, &pi) && pi.type == SDL_PATHTYPE_DIRECTORY) {
      SDL_snprintf(to, sizeof to, "%s" EXPORT_SEP "runtime" EXPORT_SEP "%s", d, SUB[i]);
      if (!export_tree(x, from, to)) return false;
    }
  }
  // the tilemap plugin's tileset ("plugin:tiles.png" in a .tmap)
  SDL_snprintf(from, sizeof from, "%splugins/tilemap/tiles.png", g_export_root);
  if (exists(from)) {
    SDL_snprintf(to, sizeof to, "%s" EXPORT_SEP "plugins", d);
    SDL_CreateDirectory(to);
    SDL_snprintf(to, sizeof to, "%s" EXPORT_SEP "plugins" EXPORT_SEP "tilemap", d);
    SDL_CreateDirectory(to);
    SDL_snprintf(to, sizeof to, "%s" EXPORT_SEP "plugins" EXPORT_SEP "tilemap" EXPORT_SEP "tiles.png", d);
    if (!export_file(x, from, to)) return false;
  }
  // the generators (plugins/<name>/gen.lua: w:generate("dungeon", ...))
  {
    char pdir[1100];
    SDL_snprintf(pdir, sizeof pdir, "%splugins/", g_export_root);
    char **names = SDL_GlobDirectory(pdir, "*/gen.lua", 0, NULL);
    for (int i = 0; names && names[i]; i++) {
      char plug[256];
      SDL_strlcpy(plug, names[i], sizeof plug);
      char *sl = SDL_strchr(plug, '/');
      if (!sl) sl = SDL_strchr(plug, '\\');
      if (!sl) continue;
      *sl = 0;
      SDL_snprintf(from, sizeof from, "%s%s", pdir, names[i]);
      SDL_snprintf(to, sizeof to, "%s" EXPORT_SEP "plugins", d); SDL_CreateDirectory(to);
      SDL_snprintf(to, sizeof to, "%s" EXPORT_SEP "plugins" EXPORT_SEP "%s", d, plug); SDL_CreateDirectory(to);
      SDL_snprintf(to, sizeof to, "%s" EXPORT_SEP "plugins" EXPORT_SEP "%s" EXPORT_SEP "gen.lua", d, plug);
      if (!export_file(x, from, to)) { SDL_free(names); return false; }
    }
    SDL_free(names);
  }
  // the game: its folder, or its script (and overrides)
  if (V->isdir) {
    SDL_snprintf(to, sizeof to, "%s" EXPORT_SEP "%s", d, name);
    return export_tree(x, V->path, to);
  }
  const char *sext = SDL_strrchr(V->path, '.');
  SDL_snprintf(to, sizeof to, "%s" EXPORT_SEP "%s%s", d, name, sext ? sext : ".lua");
  if (!export_file(x, V->path, to)) return false;
  if (V->opath[0] && exists(V->opath)) {
    SDL_snprintf(to, sizeof to, "%s" EXPORT_SEP "%s.overrides.lua", d, name);
    if (!export_file(x, V->opath, to)) return false;
  }
  SDL_strlcpy(from, V->path, sizeof from);         // the art scripts share: common/ beside it
  char *a = SDL_strrchr(from, '/'), *b = SDL_strrchr(from, '\\'), *e = a > b ? a : b;
  if (e) SDL_strlcpy(e + 1, "common", sizeof from - (size_t)(e + 1 - from)); else SDL_strlcpy(from, "common", sizeof from);
  if (SDL_GetPathInfo(from, &pi) && pi.type == SDL_PATHTYPE_DIRECTORY) {
    SDL_snprintf(to, sizeof to, "%s" EXPORT_SEP "common", d);
    if (!export_tree(x, from, to)) return false;
  }
  return true;
}

// the dialog's answer (any thread)
static void SDLCALL export_chosen(void *ud, const char *const *files, int filter) {
  (void)ud; (void)filter;
  SDL_strlcpy(g_export_pick, files && files[0] ? files[0] : "", sizeof g_export_pick);
  SDL_SetAtomicInt(&g_export_state, 2);
}

// the button: ask where (or --export-dir)
static void export_start(Viewer *V, SDL_Window *win) {
  if (SDL_GetAtomicInt(&g_export_state) != 0) return;   // (asking already)
  if (!V->stopped) session_stop(V);                // (stopped first: what's exported is the disk's)
  {                                                // does it compile? (the disk's texts: what's exported)
    lua_State *L = V->L;
    lua_getglobal(L, "viewer_unsaved_new");
    int keep = luaL_ref(L, LUA_REGISTRYINDEX);
    lua_newtable(L);                               // (no unsaved texts: the disk's)
    lua_setglobal(L, "viewer_unsaved_new");
    char why[1200] = "";
    bool ok = play_check(V, why, sizeof why);
    lua_rawgeti(L, LUA_REGISTRYINDEX, keep);
    lua_setglobal(L, "viewer_unsaved_new");
    luaL_unref(L, LUA_REGISTRYINDEX, keep);
    if (!ok) {
      char nm[256], msg[1500];
      export_name(V, nm, sizeof nm);
      SDL_snprintf(msg, sizeof msg, "%s can't be exported yet: a file doesn't compile.\n\n%s\n\n"
                   "It's open in the editor at that line. Fix it, save, then export again.", nm, why);
      ov_log(OV_ERROR, "export: %s doesn't compile (%s)", nm, why);
      if (!g_export_dir_arg[0]) SDL_ShowSimpleMessageBox(SDL_MESSAGEBOX_WARNING, "Export: not yet", msg, win);
      return;
    }
  }
  if (g_export_dir_arg[0]) {
    SDL_strlcpy(g_export_pick, g_export_dir_arg, sizeof g_export_pick);
    SDL_SetAtomicInt(&g_export_state, 2);
    return;
  }
  SDL_SetAtomicInt(&g_export_state, 1);
  SDL_ShowOpenFolderDialog(export_chosen, NULL, win, g_export_last[0] ? g_export_last : NULL, false);
}

// each frame: an answer came? export, then say how it went
static void export_poll(Viewer *V, SDL_Window *win) {
  if (SDL_GetAtomicInt(&g_export_state) != 2) return;
  SDL_SetAtomicInt(&g_export_state, 0);
  if (!g_export_pick[0]) return;                   // (cancelled: nothing to say)
  SDL_strlcpy(g_export_last, g_export_pick, sizeof g_export_last);
  char name[256], msg[1400];
  export_name(V, name, sizeof name);
  ExportRun x = { 0 };
  bool ok = export_to(V, g_export_pick, name, &x);
  if (ok) {
    SDL_snprintf(msg, sizeof msg, "%s is ready to share: %s (%d files, %.1f MB). Run %s there to play it.%s",
                 name, g_export_pick, x.files, x.bytes / 1048576.0, name,
                 V->dirty ? "\n\nThe editor has unsaved changes: they aren't in it (save, then export again)." : "");
    ov_log(OV_INFO, "export: %s", msg);
  } else {
    SDL_snprintf(msg, sizeof msg, "Couldn't export %s: %s.\n\nNothing outside %s was changed; what was copied there so far can be deleted.",
                 name, x.err, g_export_pick);
    ov_log(OV_ERROR, "export failed: %s", x.err);
  }
  app_beep();
  if (!g_export_dir_arg[0])
    SDL_ShowSimpleMessageBox(ok ? SDL_MESSAGEBOX_INFORMATION : SDL_MESSAGEBOX_ERROR,
                             ok ? "Export: done" : "Export: it didn't work", msg, win);
}
