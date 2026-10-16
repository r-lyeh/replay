// editor/picker.h - the project picker, shown at launch.
// Part of replay.c: included once, in order, from there (one compilation unit).
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
  if (!SDL_strcasecmp(fname, "common")) return SDL_ENUM_CONTINUE;   // (games/common/: the script games' shared assets, not a game)
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

static int pick_cmp(const void *a, const void *b) {   // folders first, then single files; each alphabetical
  const PickEntry *x = a, *y = b;
  int fx = !SDL_strcmp(x->kind, "folder"), fy = !SDL_strcmp(y->kind, "folder");
  if (fx != fy) return fy - fx;
  return SDL_strcasecmp(x->name, y->name);
}

static char pick_root[1024];                      // where games/ and runtime/ are (the last scan's)

// a new project: games/<name>.lua from runtime/template.lua (and Replay's icon,
// play.png, as games/<name>.png: its icon when exported) -> its path, or
// NULL with why in `err`
static char pick_new_path[1100];
static const char *pick_create(const char *name, char *err, size_t errn) {
  if (!name[0]) { SDL_snprintf(err, errn, "type a name first"); return NULL; }
  for (const char *c = name; *c; c++)
    if (!(SDL_isalnum((unsigned char)*c) || *c == '_' || *c == '-')) { SDL_snprintf(err, errn, "letters, digits, _ and - only"); return NULL; }
  if (!SDL_strcasecmp(name, "common")) { SDL_snprintf(err, errn, "common is the games' shared assets: another name"); return NULL; }
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
  char icon[1100], png[1100];                       // its icon: Replay's (play.png), as games/<name>.png (Export ships it)
  SDL_snprintf(icon, sizeof icon, "%splay.png", pick_root);
  SDL_snprintf(png, sizeof png, "%sgames/%s.png", pick_root, name);
  size_t isz = 0;
  void *idata = SDL_LoadFile(icon, &isz);
  if (idata) { SDL_SaveFile(png, idata, isz); SDL_free(idata); }
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
  SDL_InitSubSystem(SDL_INIT_GAMEPAD);              // (dpad / stick + A / START: open; B: quit)

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
  const char *force = SDL_getenv("REPLAY_SCALE");   // (test hook: as a Retina display shows it)
  float fk = force ? (float)SDL_atof(force) : 1;
  if (fk < 1) fk = 1;
  bool retina = g_settings.retina != 0;            // (.preferences.lua retina: the display's own pixels)
  if (!SDL_CreateWindowAndRenderer("Replay - open a project", (int)(W * fk), (int)(H * fk),
                                   retina ? SDL_WINDOW_HIGH_PIXEL_DENSITY : 0, &win, &r)) return NULL;
  float density = force ? fk : retina ? SDL_GetWindowPixelDensity(win) : 1;
  if (density > 1.01f) SDL_SetRenderScale(r, density, density);   // (drawn in points, at the display's pixels)
  apply_window_icon(win);                          // (like the main window: <exe name>.png)
  SDL_SetWindowPosition(win, SDL_WINDOWPOS_CENTERED, SDL_WINDOWPOS_CENTERED);
  SDL_RaiseWindow(win);
  SDL_SetRenderVSync(r, 1);
  SDL_SetRenderDrawBlendMode(r, SDL_BLENDMODE_BLEND);
  SDL_Cursor *hand = SDL_CreateSystemCursor(SDL_SYSTEM_CURSOR_POINTER);
  SDL_Cursor *arrow = SDL_CreateSystemCursor(SDL_SYSTEM_CURSOR_DEFAULT);

  int hot = -1, chosen = -1, frame = 0, sel = 0, stick = 0;   // sel: the keyboard / gamepad row (pick_n: "New project")
  bool quit = false;
  float mx = -1, my = -1;
  bool naming = false;                             // typing a new project's name
  char msg[160] = "";
  static LineEd ne;                                // the name typed (ui.h: the code editor's keys: selection, words, undo...)
  bool ne_drag = false;
  const float NAME_X = PAD + 8 * (float)strlen("New project: games/");   // (the debug font: 8 px a character)
  const char *created = NULL;
  int shot_at = 3;                                 // (the last scripted event's frame + 2)
  for (const char *ev = events; ev && (ev = strchr(ev, '@')); ev++) shot_at = SDL_max(shot_at, atoi(ev + 1) + 2);
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
    for (const char *ev = events; ev && *ev; ) {   // scripted typing: "t name@frame", "k 13@frame" (a key), "s ..." / "c ..." (with SHIFT / CTRL)
      char b, word[64]; int f, used = 0;
      if (sscanf(ev, " %c%63[^@]@%d%n", &b, word, &f, &used) != 3) break;
      ev += used;
      if (f != frame || (b != 't' && b != 'k' && b != 's' && b != 'c')) continue;
      SDL_Event c = { 0 };
      if (b == 't') { c.type = SDL_EVENT_TEXT_INPUT; c.text.text = SDL_strdup(word); }   // (SDL3: text owned by SDL; a test leak)
      else {
        c.type = SDL_EVENT_KEY_DOWN; c.key.key = (SDL_Keycode)SDL_strtoul(word, NULL, 10); c.key.down = true;
        c.key.mod = b == 's' ? SDL_KMOD_LSHIFT : b == 'c' ? SDL_KMOD_LCTRL : 0;
      }
      SDL_PushEvent(&c);
    }
    SDL_Event e;
    int go = 0;                                    // -1 / +1: move the selection; 2: open it; 3: back
    while (SDL_PollEvent(&e)) {
      SDL_ConvertEventToRenderCoordinates(r, &e);  // (the mouse in points: retina)
      if (e.type == SDL_EVENT_QUIT || e.type == SDL_EVENT_WINDOW_CLOSE_REQUESTED) quit = true;
      else if (naming && e.type == SDL_EVENT_TEXT_INPUT) {   // the name being typed
        char ok[64];
        int n = 0;
        msg[0] = 0;
        for (const char *t = e.text.text; *t && n + 1 < (int)sizeof ok; t++) {
          if (SDL_isalnum((unsigned char)*t) || *t == '_' || *t == '-') ok[n++] = *t;
          else SDL_snprintf(msg, sizeof msg, "'%c' can't be in a name: letters, digits, _ and - only", *t);   // (. ? $ : and the rest: other meanings)
        }
        ok[n] = 0;
        if (n && ne.len + n < 60) le_insert(&ne, ok);
      }
      else if (naming && e.type == SDL_EVENT_KEY_DOWN) {
        if (e.key.key == SDLK_ESCAPE) { naming = false; le_set(&ne, ""); ne.nundo = 0; msg[0] = 0; SDL_StopTextInput(win); }
        else if (e.key.key == SDLK_RETURN || e.key.key == SDLK_KP_ENTER) created = pick_create(ne.s, msg, sizeof msg);
        else if (e.key.key == SDLK_V && (e.key.mod & SDL_KMOD_CTRL)) {   // (pasted: only what a name can hold)
          char *c = SDL_GetClipboardText(), ok[64];
          int n = 0;
          for (const char *t = c ? c : ""; *t && n + 1 < (int)sizeof ok; t++) if (SDL_isalnum((unsigned char)*t) || *t == '_' || *t == '-') ok[n++] = *t;
          ok[n] = 0;
          if (n) le_insert(&ne, ok);
          SDL_free(c);
        }
        else { le_key(&ne, e.key.key, e.key.mod); msg[0] = 0; }
      }
      else if (naming && ne_drag && e.type == SDL_EVENT_MOUSE_MOTION) {   // a drag in the name: selects
        mx = e.motion.x; my = e.motion.y;
        le_drag(&ne, (int)SDL_floorf((mx - NAME_X) / 8 + 0.5f));
      }
      else if (e.type == SDL_EVENT_MOUSE_BUTTON_UP) ne_drag = false;
      else if (e.type == SDL_EVENT_KEY_DOWN && e.key.key == SDLK_ESCAPE) quit = true;
      else if (e.type == SDL_EVENT_KEY_DOWN && e.key.key == SDLK_UP) go = -1;
      else if (e.type == SDL_EVENT_KEY_DOWN && e.key.key == SDLK_DOWN) go = 1;
      else if (e.type == SDL_EVENT_KEY_DOWN && (e.key.key == SDLK_RETURN || e.key.key == SDLK_KP_ENTER)) go = 2;
      else if (e.type == SDL_EVENT_GAMEPAD_ADDED) SDL_OpenGamepad(e.gdevice.which);
      else if (e.type == SDL_EVENT_GAMEPAD_BUTTON_DOWN) {
        int b = e.gbutton.button;
        if (b == SDL_GAMEPAD_BUTTON_EAST || b == SDL_GAMEPAD_BUTTON_BACK) go = 3;
        else if (naming) { if (b == SDL_GAMEPAD_BUTTON_SOUTH || b == SDL_GAMEPAD_BUTTON_START) created = pick_create(ne.s, msg, sizeof msg); }
        else if (b == SDL_GAMEPAD_BUTTON_DPAD_UP) go = -1;
        else if (b == SDL_GAMEPAD_BUTTON_DPAD_DOWN) go = 1;
        else if (b == SDL_GAMEPAD_BUTTON_SOUTH || b == SDL_GAMEPAD_BUTTON_START) go = 2;
      }
      else if (e.type == SDL_EVENT_GAMEPAD_AXIS_MOTION && e.gaxis.axis == SDL_GAMEPAD_AXIS_LEFTY && !naming) {
        int now = e.gaxis.value < -16000 ? -1 : e.gaxis.value > 16000 ? 1 : 0;   // (a push moves one row)
        if (now && now != stick) go = now;
        stick = now;
      }
      else if (e.type == SDL_EVENT_MOUSE_MOTION) {
        mx = e.motion.x; my = e.motion.y;
        int i = (int)((my - TOP) / ROW);
        if (my >= TOP && i >= 0 && i <= pick_n) sel = i;   // (the mouse moves the selection too)
      }
      else if (e.type == SDL_EVENT_MOUSE_BUTTON_DOWN && e.button.button == SDL_BUTTON_LEFT) {
        mx = e.button.x; my = e.button.y;
        int i = (int)((my - TOP) / ROW);
        if (naming && i == pick_n) {               // in the name: the caret there (SHIFT: select to it; double-click: all of it)
          le_click(&ne, (int)SDL_floorf((mx - NAME_X) / 8 + 0.5f), e.button.clicks, (SDL_GetModState() & SDL_KMOD_SHIFT) != 0);
          ne_drag = true;
        }
        else if (my >= TOP && i >= 0 && i < pick_n) chosen = i;
        else if (my >= TOP && i == pick_n && !naming) { naming = true; msg[0] = 0; SDL_StartTextInput(win); }
      }
    }
    if (go == 3) { if (naming) { naming = false; le_set(&ne, ""); ne.nundo = 0; msg[0] = 0; SDL_StopTextInput(win); } else quit = true; }
    else if (go == 2 && !naming) {
      if (sel < pick_n) chosen = sel;
      else { naming = true; msg[0] = 0; SDL_StartTextInput(win); }
    }
    else if ((go == 1 || go == -1) && !naming) sel = (sel + go + pick_n + 1) % (pick_n + 1);
    int i = (int)((my - TOP) / ROW);
    bool over = my >= TOP && mx >= 0 && mx < W && i >= 0 && i <= pick_n;
    SDL_SetCursor(over ? hand : arrow);
    hot = sel;                                     // (pick_n: "New project")

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
      else {                                       // "New project: games/<name>.lua": its selection, its caret
        SDL_RenderDebugText(r, PAD, ty, "New project: games/");
        int a, b;
        le_sel(&ne, &a, &b);
        if (b > a) { ui_color(r, ui.selection); SDL_RenderFillRect(r, &(SDL_FRect){ NAME_X + 8 * a, ty - 2, 8.f * (b - a), 12 }); }
        ui_color(r, ui.caret);
        SDL_RenderDebugText(r, NAME_X, ty, ne.s);
        ui_color(r, ui.dim);
        SDL_RenderDebugText(r, NAME_X + 8 * ne.len, ty, ".lua");
        if ((frame / 30) % 2 == 0) { ui_color(r, ui.caret); SDL_RenderFillRect(r, &(SDL_FRect){ NAME_X + 8 * ne.cur - 1, ty - 2, 2, 12 }); }
      }
    }
    ui_color(r, ui.dim);
    if (msg[0]) { ui_color(r, ui.error); SDL_RenderDebugText(r, PAD, H - 20.f, msg); }
    else if (naming) SDL_RenderDebugText(r, PAD, H - 20.f, "type a name    Enter: create and open it    ESC / B: cancel");
    else SDL_RenderDebugText(r, PAD, H - 20.f, "click or arrows + Enter (a gamepad: A)    ESC / B: quit    (or: replay games\\pong\\)");

    if (shot && frame >= shot_at) {                // test: save the picker (after its scripted events), then quit
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
