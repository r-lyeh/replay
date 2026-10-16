// editor/picker.h - the project picker, shown at launch.
// Part of play.c: included once, in order, from there (one compilation unit).
//
// With no world on the command line (and none found from the exe's name),
// the entrypoints in games/ are listed: world folders, *.lua and *.hurdy
// scripts (not *.overrides.lua). One entrypoint: it opens directly. More:
// a small window lists them; click one to open it, ESC or close to quit.
// Each row shows a one-line description: a folder's README.md (its first
// text line) or a script's first comment line after its own name.
//
// "New project" (the row under the list, also shown when games/ is empty):
// type a name (letters, digits, _ and -), Enter creates games/<name>.lua from
// runtime/template.lua ({{name}} in it becomes the name) and opens it; ESC
// cancels. An existing name is refused.
//
// Test hooks: --pick "m x,y@frame l x,y@frame t text@frame k code@frame"
//             (mouse move / left click / typed text / a key: 13 Enter),
//             --pick-shot out.bmp (save the picker after a few frames, quit).

typedef struct {
  char path[1024];                 // what to open
  char name[96];                   // "pong/", "pong.lua"
  char kind[8];                    // "folder", "lua", "hurdy"
  char about[160];                 // one line, may be empty
} PickEntry;

#define PICK_MAX_ 64
static PickEntry pick_list[PICK_MAX_];
static int pick_n;

static bool pick_has_suffix(const char *s, const char *suf) {
  size_t n = strlen(s), k = strlen(suf);
  return n > k && !SDL_strcasecmp(s + n - k, suf);
}

// a one-line description from a README.md or a script's leading comments
static void pick_about(PickEntry *e, const char *file, bool script, const char *self) {
  size_t size = 0;
  char *text = (char *)SDL_LoadFile(file, &size);
  if (!text) return;
  for (char *line = text, *next; line && *line; line = next) {
    next = strchr(line, '\n');
    if (next) *next++ = 0;
    size_t n = strlen(line);
    while (n && (line[n - 1] == '\r' || line[n - 1] == ' ')) line[--n] = 0;
    char *t = line;
    if (script) {
      if (strncmp(t, "--", 2)) break;              // comments come first; stop at code
      t += 2;
      while (*t == ' ') t++;
      if (!*t || !SDL_strcasecmp(t, self)) continue;   // "-- pong.lua": its own name
    } else {
      while (*t == ' ') t++;
      if (!*t || *t == '#' || *t == '!' || *t == '[') continue;   // headings, images
    }
    size_t k = 0;                                  // without markdown's ** and `
    for (; *t && k + 1 < sizeof e->about; t++) if (*t != '*' && *t != '`') e->about[k++] = *t;
    e->about[k] = 0;
    break;
  }
  SDL_free(text);
}

static SDL_EnumerationResult SDLCALL pick_found(void *dir, const char *dirname, const char *fname) {
  (void)dir;
  if (pick_n >= PICK_MAX_ || fname[0] == '.') return SDL_ENUM_CONTINUE;
  PickEntry *e = &pick_list[pick_n];
  SDL_snprintf(e->path, sizeof e->path, "%s%s", dirname, fname);
  SDL_PathInfo info;
  if (!SDL_GetPathInfo(e->path, &info)) return SDL_ENUM_CONTINUE;
  if (info.type == SDL_PATHTYPE_DIRECTORY) {
    SDL_snprintf(e->name, sizeof e->name, "%s/", fname);
    SDL_strlcpy(e->kind, "folder", sizeof e->kind);
    char readme[1100];
    SDL_snprintf(readme, sizeof readme, "%s/README.md", e->path);
    pick_about(e, readme, false, NULL);
  } else if (pick_has_suffix(fname, ".overrides.lua")) {
    return SDL_ENUM_CONTINUE;                      // edits of a script, not a script
  } else if (pick_has_suffix(fname, ".lua") || pick_has_suffix(fname, ".hurdy")) {
    SDL_strlcpy(e->name, fname, sizeof e->name);
    SDL_strlcpy(e->kind, pick_has_suffix(fname, ".lua") ? "lua" : "hurdy", sizeof e->kind);
    pick_about(e, e->path, true, fname);
  } else {
    return SDL_ENUM_CONTINUE;
  }
  pick_n++;
  return SDL_ENUM_CONTINUE;
}

static int pick_cmp(const void *a, const void *b) {
  return SDL_strcasecmp(((const PickEntry *)a)->name, ((const PickEntry *)b)->name);
}

static char pick_root[1024];                      // where games/ and runtime/ are (the last scan's)

// a new project: games/<name>.lua from runtime/template.lua -> its path, or
// NULL with why in `err`
static char pick_new_path[1100];
static const char *pick_create(const char *name, char *err, size_t errn) {
  if (!name[0]) { SDL_snprintf(err, errn, "type a name first"); return NULL; }
  for (const char *c = name; *c; c++)
    if (!(SDL_isalnum((unsigned char)*c) || *c == '_' || *c == '-')) { SDL_snprintf(err, errn, "letters, digits, _ and - only"); return NULL; }
  char dir[1100], tpl[1100];
  SDL_snprintf(dir, sizeof dir, "%sgames/%s", pick_root, name);
  SDL_snprintf(pick_new_path, sizeof pick_new_path, "%sgames/%s.lua", pick_root, name);
  SDL_snprintf(tpl, sizeof tpl, "%sruntime/template.lua", pick_root);
  SDL_PathInfo info;
  if (SDL_GetPathInfo(pick_new_path, &info) || SDL_GetPathInfo(dir, &info)) { SDL_snprintf(err, errn, "%s exists already", name); return NULL; }
  size_t size = 0;
  char *text = (char *)SDL_LoadFile(tpl, &size);
  if (!text) { SDL_snprintf(err, errn, "no template: %s", tpl); return NULL; }
  size_t nl = strlen(name), cap = size + 1, n = 0;    // {{name}} -> name
  for (const char *p = text; (p = strstr(p, "{{name}}")); p += 8) cap += nl;
  char *out = (char *)SDL_malloc(cap);
  if (!out) { SDL_free(text); SDL_snprintf(err, errn, "out of memory"); return NULL; }
  for (const char *p = text; *p; ) {
    if (!strncmp(p, "{{name}}", 8)) { memcpy(out + n, name, nl); n += nl; p += 8; }
    else out[n++] = *p++;
  }
  bool ok = SDL_SaveFile(pick_new_path, out, n);
  SDL_free(out); SDL_free(text);
  if (!ok) { SDL_snprintf(err, errn, "can't write %s", pick_new_path); return NULL; }
  return pick_new_path;
}

// the entrypoints in <root>games/ (root ends with a separator, or is "")
static int pick_scan(const char *root) {
  char dir[1024];
  SDL_strlcpy(pick_root, root ? root : "", sizeof pick_root);
  SDL_snprintf(dir, sizeof dir, "%sgames/", root ? root : "");
  pick_n = 0;
  SDL_EnumerateDirectory(dir, pick_found, NULL);
  SDL_qsort(pick_list, pick_n, sizeof pick_list[0], pick_cmp);
  return pick_n;
}

// pick_list[] -> the chosen path, or NULL (closed / ESC / --pick-shot).
static const char *pick_project(const char *events, const char *shot) {
  if (!SDL_Init(SDL_INIT_VIDEO)) return NULL;

  const float ROW = 22, TOP = 40, PAD = 12;
  int namew = 0;
  for (int i = 0; i < pick_n; i++) {
    int n = (int)strlen(pick_list[i].name);
    if (n > namew) namew = n;
  }
  float xkind = PAD + 8.f * (namew + 2), xabout = xkind + 8.f * 8;
  int W = 720, H = (int)(TOP + (pick_n + 1) * ROW + 34);   // (+ the "New project" row)
  SDL_Window *win = NULL;
  SDL_Renderer *r = NULL;
  if (!SDL_CreateWindowAndRenderer("Replay - open a project", W, H, 0, &win, &r)) return NULL;
  apply_window_icon(win);                          // (like the main window: <exe name>.png)
  SDL_SetWindowPosition(win, SDL_WINDOWPOS_CENTERED, SDL_WINDOWPOS_CENTERED);
  SDL_RaiseWindow(win);
  SDL_SetRenderVSync(r, 1);
  SDL_SetRenderDrawBlendMode(r, SDL_BLENDMODE_BLEND);
  SDL_Cursor *hand = SDL_CreateSystemCursor(SDL_SYSTEM_CURSOR_POINTER);
  SDL_Cursor *arrow = SDL_CreateSystemCursor(SDL_SYSTEM_CURSOR_DEFAULT);

  int hot = -1, chosen = -1, frame = 0;
  bool quit = false;
  float mx = -1, my = -1;
  bool naming = false;                             // typing a new project's name
  char name[64] = "", msg[160] = "";
  const char *created = NULL;
  while (chosen < 0 && !quit && !created) {
    for (const char *ev = events; ev && *ev; ) {   // scripted mouse, for tests
      char b; float x, y; int f, used = 0;
      if (sscanf(ev, " %c%f,%f@%d%n", &b, &x, &y, &f, &used) != 4) break;
      ev += used;
      if (f != frame) continue;
      SDL_Event c = { 0 };
      c.motion.windowID = SDL_GetWindowID(win);
      if (b == 'm') { c.type = SDL_EVENT_MOUSE_MOTION; c.motion.x = x; c.motion.y = y; }
      else { c.type = SDL_EVENT_MOUSE_BUTTON_DOWN; c.button.button = SDL_BUTTON_LEFT;
             c.button.down = true; c.button.x = x; c.button.y = y; c.button.clicks = 1; }
      SDL_PushEvent(&c);
    }
    for (const char *ev = events; ev && *ev; ) {   // scripted typing: "t name@frame", "k 13@frame" (a key)
      char b, word[64]; int f, used = 0;
      if (sscanf(ev, " %c%63[^@]@%d%n", &b, word, &f, &used) != 3) break;
      ev += used;
      if (f != frame || (b != 't' && b != 'k')) continue;
      SDL_Event c = { 0 };
      if (b == 't') { c.type = SDL_EVENT_TEXT_INPUT; c.text.text = SDL_strdup(word); }   // (SDL3: text owned by SDL; a test leak)
      else { c.type = SDL_EVENT_KEY_DOWN; c.key.key = (SDL_Keycode)atoi(word); c.key.down = true; }
      SDL_PushEvent(&c);
    }
    SDL_Event e;
    while (SDL_PollEvent(&e)) {
      if (e.type == SDL_EVENT_QUIT || e.type == SDL_EVENT_WINDOW_CLOSE_REQUESTED) quit = true;
      else if (naming && e.type == SDL_EVENT_TEXT_INPUT) {   // the name being typed
        size_t n = strlen(name);
        msg[0] = 0;
        for (const char *t = e.text.text; *t && n + 1 < sizeof name; t++) {
          if (SDL_isalnum((unsigned char)*t) || *t == '_' || *t == '-') name[n++] = *t;
          else SDL_snprintf(msg, sizeof msg, "'%c' can't be in a name: letters, digits, _ and - only", *t);   // (. ? $ : and the rest: other meanings)
        }
        name[n] = 0;
      }
      else if (naming && e.type == SDL_EVENT_KEY_DOWN) {
        size_t n = strlen(name);
        if (e.key.key == SDLK_ESCAPE) { naming = false; name[0] = 0; msg[0] = 0; SDL_StopTextInput(win); }
        else if (e.key.key == SDLK_BACKSPACE && n) name[n - 1] = 0;
        else if (e.key.key == SDLK_RETURN || e.key.key == SDLK_KP_ENTER) created = pick_create(name, msg, sizeof msg);
      }
      else if (e.type == SDL_EVENT_KEY_DOWN && e.key.key == SDLK_ESCAPE) quit = true;
      else if (e.type == SDL_EVENT_MOUSE_MOTION) { mx = e.motion.x; my = e.motion.y; }
      else if (e.type == SDL_EVENT_MOUSE_BUTTON_DOWN && e.button.button == SDL_BUTTON_LEFT) {
        mx = e.button.x; my = e.button.y;
        int i = (int)((my - TOP) / ROW);
        if (my >= TOP && i >= 0 && i < pick_n) chosen = i;
        else if (my >= TOP && i == pick_n && !naming) { naming = true; msg[0] = 0; SDL_StartTextInput(win); }
      }
    }
    int i = (int)((my - TOP) / ROW);
    hot = (my >= TOP && mx >= 0 && mx < W && i >= 0 && i <= pick_n) ? i : -1;   // (pick_n: "New project")
    SDL_SetCursor(hot >= 0 ? hand : arrow);

    ui_begin();                                    // the editor's colours (its Theme: dark / light, ui.h)
    ui_color(r, ui.bg);                           // (the code's background: background, as lite's editor)
    SDL_RenderClear(r);
    ui_color(r, ui.caret);
    SDL_RenderDebugText(r, PAD, 14, "Open a project");
    ui_color(r, ui.dim);
    SDL_RenderDebugText(r, PAD + 8 * 16, 14, "from games/");
    for (int k = 0; k < pick_n; k++) {
      const PickEntry *pe = &pick_list[k];
      float y = TOP + k * ROW;
      if (k == hot) {
        SDL_FRect bg = { 4, y, W - 8.f, ROW - 2 };
        ui_color(r, ui.selection);
        SDL_RenderFillRect(r, &bg);
      }
      float ty = y + (ROW - 2 - 8) / 2;
      ui_color(r, ui.accent);
      SDL_RenderDebugText(r, PAD, ty, pe->name);
      if (pe->kind[0] == 'h') ui_color(r, ui.keyword);   // hurdy
      else if (pe->kind[0] == 'l') ui_color(r, ui.func);
      else ui_color(r, ui.string);
      SDL_RenderDebugText(r, xkind, ty, pe->kind);
      char about[160];
      int maxc = (int)((W - PAD - xabout) / 8);
      SDL_strlcpy(about, pe->about, sizeof about);
      if ((int)strlen(about) > maxc && maxc > 3) { about[maxc - 2] = '.'; about[maxc - 1] = '.'; about[maxc] = 0; }
      ui_color(r, ui.text);
      SDL_RenderDebugText(r, xabout, ty, about);
    }
    {                                              // the last row: a new project
      float y = TOP + pick_n * ROW, ty = y + (ROW - 2 - 8) / 2;
      if (hot == pick_n || naming) {
        SDL_FRect bg = { 4, y, W - 8.f, ROW - 2 };
        ui_color(r, naming ? ui.hilite : ui.selection);
        SDL_RenderFillRect(r, &bg);
      }
      ui_color(r, ui.caret);
      if (!naming) SDL_RenderDebugText(r, PAD, ty, "+ New project (from runtime/template.lua)");
      else {
        char line[200];
        SDL_snprintf(line, sizeof line, "New project: games/%s%s.lua", name, (frame / 30) % 2 ? "_" : " ");
        SDL_RenderDebugText(r, PAD, ty, line);
      }
    }
    ui_color(r, ui.dim);
    if (msg[0]) { ui_color(r, ui.error); SDL_RenderDebugText(r, PAD, H - 20.f, msg); }
    else if (naming) SDL_RenderDebugText(r, PAD, H - 20.f, "type a name    Enter: create and open it    ESC: cancel");
    else SDL_RenderDebugText(r, PAD, H - 20.f, "click one to open it    ESC: quit    (or pass a path: play games\\pong\\)");

    if (shot && frame >= 3) {                      // test: save the picker, then quit
      SDL_Surface *s = SDL_RenderReadPixels(r, NULL);
      if (s) { SDL_SaveBMP(s, shot); SDL_DestroySurface(s); printf("saved %s\n", shot); }
      quit = true;
    }
    SDL_RenderPresent(r);
    frame++;
  }
  SDL_SetCursor(SDL_GetDefaultCursor());
  SDL_DestroyCursor(hand);
  SDL_DestroyCursor(arrow);
  SDL_DestroyRenderer(r);
  SDL_DestroyWindow(win);
  if (created) return created;
  return chosen >= 0 ? pick_list[chosen].path : NULL;
}
