// editor/editor.h - the lite text editor, embedded (see editor/editor.c)
#pragma once
#include <SDL3/SDL.h>

// Start lite inside an existing window/renderer.
//   datadir: folder that contains lite's data/ (e.g. "<exe>/3rd/lite")
//   project: folder to open as the project (lite chdir()s into it!)
// Returns false and a message in editor_error() if lite can't start.
bool editor_init(SDL_Window *win, SDL_Renderer *ren, const char *datadir, const char *project);

// Place the editor inside the window (call before editor_init and on every
// resize). Mouse events passed to editor_event() are in window coordinates
// and get translated. Default: the whole window.
void editor_set_scale(float s);   // retina: lite's pixels per point (before editor_init)
void editor_viewport(int x, int y, int w, int h, int win_w, int win_h);   // lite's views in x, y, w, h; its surface (and popups): the whole window
void editor_pane_shown(bool on);                   // the host shows lite's views (off: the game covers them; lite draws only its popups)
void editor_side(float x, float y, float w, float h);   // the left tab (points): lite draws it there (plugins/sidetab.lua)
void editor_side_blur(void);
bool editor_prompt(const char *cmd, const char *s, float a, float b, float c);   // the bar's Lua prompt, typed in lite (plugins/textproxy.lua)
bool editor_prompt_get(char *buf, size_t n, int *cur, int *s1, int *s2, bool *caret);   // its text, caret, selection (byte offsets)
void editor_mods(SDL_Keymod m);                   // lite's CTRL / SHIFT / ALT as SDL has them (before a click sent to it)                       // a click outside lite: the value typed there is kept, its filter left
struct lua_State;
struct lua_State *editor_lua(void);                // lite's Lua state (replay.c registers the tab's host functions: editor/side.h)
// Lite's popups (menus: plugins/contextmenu.lua, plugins/mainmenu.lua) are drawn
// on its surface wherever they fall in the window; replay.c shows those parts
// over everything and sends them the mouse and keys while any is open.
bool editor_menu_modal(void);                      // one of lite's popups is a menu (it takes the mouse and keys), not a tooltip
int editor_overlays(SDL_FRect *out, int max);     // -> how many, their rects (host points)
bool editor_overlay_at(float x, float y);
// lite's host_call(cmd) -> fn(cmd): the menus ask replay.c (settings, the bar's menus) -> a string | NULL
void editor_set_host_call(const char *(*fn)(const char *cmd));
// open a menu (plugins/hostmenu.lua): text = lines "depth\tkind\ttext\tinfo\tflags"; x, y: its top left
// (host points). Its answers come through host_call: "pick <id> <path>", "closed <id>".
bool editor_menu(const char *id, float x, float y, float above, const char *text, bool search);   // above: up from there when there's no room below (-1: none)
void editor_menu_close(void);

// Forward an SDL event. Input events should only be forwarded while the
// editor has focus; window events (resize/expose/quit) always.
void editor_event(const SDL_Event *e);

// Give/take keyboard focus (starts/stops SDL text input).
void editor_focus(bool on);

// Open (or focus) a file in the editor, cursor on `line` (1-based).
bool editor_open(const char *file, int line);
// show a compile error: a graph of that file if one is open (that line's
// node, the message on it), else its text at that line
bool editor_open_error(const char *file, int line, const char *msg);
// The same, after lite's next step (at start: after the workspace / Log tab).
void editor_open_later(const char *file);
// the node graph asks the world what a file's code did (lines run, values):
// fn(file) -> Lua source "return {...}" or NULL. lite: host_probe(file).
void editor_set_probe(const char *(*fn)(const char *file));
// fn(file, line, expr) -> the value of an expression (no calls) at that line
// in the frame shown, or NULL. lite: host_probe_eval(file, line, expr).
void editor_set_probe_eval(const char *(*fn)(const char *file, int line, const char *src));
// breakpoints: set(file, line, on); where() -> "file\nline\nn" while stopped at one, or NULL.
// lite: host_break_set(file, line, on), host_break_where() -> file, line, n.
void editor_set_breaks(void (*set)(const char *file, int line, bool on, int as, int fdef), const char *(*where)(void));
void editor_set_world_file(const char *(*fn)(void));
int editor_unsaved(void (*fn)(const char *path, const char *text, size_t n, void *ud), void *ud);   // the editor's unsaved files -> how many
void editor_prof(double *raster_ms, int *redraws, double *upload_ms, int *rects);   // (--prof) lite since the last call: raster ms, redraws, of which uploading ms, rects uploaded
// from a stop: step(mode), mode "over" | "in" | "out" | "continue". lite: host_break_step(mode).
void editor_set_break_step(void (*step)(const char *mode));
void editor_open_later_at(const char *file, int line);   // (at that line)

// Show a message in lite's status bar (level 0 = info, 1+ = warning/error).
// at = "file:line" it came from (shown in lite's log view), or NULL. A
// multi-line text: the first line is the message, the rest go to the log.
void editor_log(int level, const char *text, const char *at);

// Show lite's Log tab (focus it, or open it once).
void editor_show_log(void);
// Show / hide the Log tab (the main menu's "Log window"); is it open?
void editor_set_log(bool show);
bool editor_log_shown(void);
// At start (after lite's first step): 1 shows the Log tab, anything else hides it.
void editor_boot_log(int arg);

// Run one lite step (events, update, redraw of dirty cells).
void editor_frame(void);

// The texture lite renders into, sized to the window (NULL if not running).
SDL_Texture *editor_texture(void);

// lite's look, for the viewer's own panels (the left tab, tooltips, the bar):
// editor_ui_begin() once a frame -> its UI font's line height (0: lite isn't
// running: no font); editor_ui_text draws text in that font (r NULL: just
// measures) -> the x after it; editor_ui_color("background2" /
// "syntax.string") -> its theme's colour (false: none).
int editor_ui_begin(void);
float editor_ui_text(SDL_Renderer *r, float x, float y, const char *text, SDL_Color c);
bool editor_ui_color(const char *key, SDL_Color *out);
// the panels' own font size, px (lite's UI font, data/fonts/font.ttf, at
// that size); 0: lite's style.font again
void editor_ui_font(int px);
// the project's plugins/ folder: each of its folders with an editor.lua is
// loaded into lite at start (data/plugins/projectplugins.lua). Call before
// editor_init.
void editor_set_plugins_dir(const char *dir);
void editor_set_scripted(bool on);   // a scripted run (--events, --lite, --type, --key): lite neither restores nor saves its workspace
// the renderer lost its textures' contents (SDL_EVENT_RENDER_TARGETS_RESET,
// SDL_EVENT_RENDER_DEVICE_RESET: device true) or the window was exposed:
// lite's whole image goes up again (it only uploads what it redraws)
void editor_render_reset(bool device);

// Run a chunk of Lua inside lite (tests, tools). Errors go to stderr.
bool editor_exec(const char *lua);
// the main menu's Plugins >: "name\ttitle\n"... of the plugins that open a tab of their own
bool editor_plugin_tabs(char *out, size_t n);
// its menu: "i\ttext\tinfo\n" an item (its key, its file), "-\t\t\n" a separator
bool editor_plugin_menu(const char *name, char *out, size_t n);

bool editor_running(void);
bool editor_wants_keys(void);    // is lite's active view one you type in (code, a field)?
bool editor_wants_quit(void);    // lite's quit command / close confirmed
const char *editor_error(void);
int editor_error_seq(void);      // bumps on each new error (a lite frame's update / draw, a step): the host logs editor_error()
void editor_shutdown(void);
unsigned char *editor_image_decode(const void *data, int size, int *w, int *h);   // PNG/JPG/BMP/TGA/GIF -> RGBA (NULL: not an image)
void editor_image_free(unsigned char *pixels);
struct lua_State;
void editor_udp_register(struct lua_State *L);   // the world VM's `udp` (editor/udp.h, compiled in editor/editor.c): sockets for net.udp
