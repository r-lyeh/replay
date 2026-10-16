// Copyright (c) 2020 rxi
//
// Permission is hereby granted, free of charge, to any person obtaining a copy of
// this software and associated documentation files (the "Software"), to deal in
// the Software without restriction, including without limitation the rights to
// use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies
// of the Software, and to permit persons to whom the Software is furnished to do
// so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in all
// copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.

// [doc] https://rxi.github.io/lite_an_implementation_overview.html
// [chg] differences from https://github.com/rxi/lite listed below:
//
// a) amalgamated as single-file source.
// b) platform agnostic now (no more specific SDL calls; tested with GLFW backend).
// c) specific `lt_` platform bits have been moved out to an external file (lite_sys.h)
// d) lua, stb-truetype and lite_sys headers *must be included* beforehand.
// e) embeddable: reverted loop handler from framework to library mode. see: lt_init/lt_tick
// f) data folders reorganized as data/themes, data/languages/ and data/plugins/.
// g) DATADIR path can be specified now and no longer forced to be EXEDIR/data/.
// h) packaged with a bunch of handy plugins from https://github.com/rxi/lite-plugins
// i) packaged with all color themes from https://github.com/rxi/lite-colors
// j) merged a few pending PRs and pending fixes from original repo.
// k) Lua sources fixed for Lua >= 5.2
//
// All contributions released under same MIT licensing terms than original code.
// - rlyeh.

#include <assert.h>
#include <ctype.h>
#include <errno.h>
#include <math.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <sys/stat.h>

#ifndef S_ISDIR
#define S_ISDIR(mode) (((mode) & S_IFMT) == S_IFDIR)
#endif

#ifndef S_ISREG
#define S_ISREG(mode) (((mode) & S_IFMT) == S_IFREG)
#endif

// ----------------------------------------------------------------------------
// lite/api.h

#define API_TYPE_FONT "Font"
#define API_TYPE_IMAGE "Image" //< Replay: renderer.image.load(path)

// ----------------------------------------------------------------------------
// lite/renderer.h

typedef struct RenImage RenImage;
typedef struct RenFont RenFont;

typedef struct { uint8_t b, g, r, a; } RenColor;
//typedef struct { int x, y, width, height; } RenRect;
typedef lt_rect RenRect;


void ren_init(void *win);
void ren_update_rects(RenRect *rects, int count);
void ren_set_clip_rect(RenRect rect);
void ren_get_size(int *x, int *y);

RenImage* ren_new_image(int width, int height);
void ren_free_image(RenImage *image);

RenFont* ren_load_font(const char *filename, float size);
void ren_free_font(RenFont *font);
void ren_set_font_tab_width(RenFont *font, int n);
int ren_get_font_tab_width(RenFont *font);
int ren_get_font_width(RenFont *font, const char *text);
int ren_get_font_height(RenFont *font);

void ren_draw_rect(RenRect rect, RenColor color);
void ren_draw_line(float x1, float y1, float x2, float y2, float width, RenColor color); //< Replay: lines
void ren_draw_image(RenImage *image, RenRect *sub, int x, int y, RenColor color);
void ren_blit_image(RenImage *image, RenRect sub, RenRect dst, RenColor color); //< Replay: a part of an image (sub; width 0: all of it) scaled into dst (nearest)
int ren_draw_text(RenFont *font, const char *text, int x, int y, RenColor color);

// ----------------------------------------------------------------------------
// lite/rencache.h

void rencache_show_debug(bool enable);
void rencache_free_font(RenFont *font);
void rencache_free_image(RenImage *image); //< Replay
void rencache_draw_image(RenImage *image, unsigned serial, RenRect sub, RenRect dst, RenColor color); //< Replay (sub: a part; width 0: all)
void rencache_set_clip_rect(RenRect rect);
void rencache_draw_rect(RenRect rect, RenColor color);
void rencache_draw_line(float x1, float y1, float x2, float y2, float width, RenColor color); //< Replay: lines
int  rencache_draw_text(RenFont *font, const char *text, int x, int y, RenColor color);
void rencache_invalidate(void);
void rencache_begin_frame(void);
void rencache_end_frame(void);

// ----------------------------------------------------------------------------
// lite/renderer.c

#define MAX_GLYPHSET 256

struct RenImage {
    RenColor *pixels;
    int width, height;
};

typedef struct {
    RenImage *image;
    stbtt_bakedchar glyphs[256];
} GlyphSet;

struct RenFont {
    void *data;
    stbtt_fontinfo stbfont;
    GlyphSet *sets[MAX_GLYPHSET];
    float size;
    int height;
};

static struct { int left, top, right, bottom; } lt_clip;

static const char* codepoint_to_utf8(unsigned c) { //< @r-lyeh
    static char s[4+1];
    lt_memset(s, 0, 5);
    /**/ if (c <     0x80) s[0] = c, s[1] = 0;
    else if (c <    0x800) s[0] = 0xC0 | ((c >>  6) & 0x1F), s[1] = 0x80 | ( c        & 0x3F), s[2] = 0;
    else if (c <  0x10000) s[0] = 0xE0 | ((c >> 12) & 0x0F), s[1] = 0x80 | ((c >>  6) & 0x3F), s[2] = 0x80 | ( c        & 0x3F), s[3] = 0;
    else if (c < 0x110000) s[0] = 0xF0 | ((c >> 18) & 0x07), s[1] = 0x80 | ((c >> 12) & 0x3F), s[2] = 0x80 | ((c >>  6) & 0x3F), s[3] = 0x80 | (c & 0x3F), s[4] = 0;
    return s;
}
static const char* utf8_to_codepoint(const char *p, unsigned *dst) {
    unsigned res, n;
    switch (*p & 0xf0) {
        case 0xf0 :  res = *p & 0x07;  n = 3;  break;
        case 0xe0 :  res = *p & 0x0f;  n = 2;  break;
        case 0xd0 :
        case 0xc0 :  res = *p & 0x1f;  n = 1;  break;
        default   :  res = *p;         n = 0;  break;
    }
    while (n-- && *p++) {               //< https://github.com/rxi/lite/issues/262
        res = (res << 6) | (*p & 0x3f); //< https://github.com/rxi/lite/issues/262
    }
    *dst = res;
    return p + 1;
}

void ren_init(void *win) {
    lt_surface *surf = lt_getsurface(lt_window());
    ren_set_clip_rect( (RenRect) { 0, 0, surf->w, surf->h } );
}


void ren_update_rects(RenRect *rects, int count) {
    lt_updatesurfacerects(lt_getsurface(lt_window()), (lt_rect*) rects, count);
}


void ren_set_clip_rect(RenRect rect) {
    lt_clip.left   = rect.x;
    lt_clip.top    = rect.y;
    lt_clip.right  = rect.x + rect.width;
    lt_clip.bottom = rect.y + rect.height;
}


void ren_get_size(int *x, int *y) {
    lt_surface *surf = lt_getsurface(lt_window());
    *x = surf->w;
    *y = surf->h;
}


RenImage* ren_new_image(int width, int height) {
    lt_assert(width > 0 && height > 0);
    RenImage *image = lt_malloc(sizeof(RenImage) + width * height * sizeof(RenColor));
    image->pixels = (void*) (image + 1);
    image->width = width;
    image->height = height;
    return image;
}


void ren_free_image(RenImage *image) {
    lt_free(image);
}


static GlyphSet* load_glyphset(RenFont *font, int idx) {
    GlyphSet *set = lt_calloc(1, sizeof(GlyphSet));

    /* init image */
    int width = 128;
    int height = 128;
retry:
    set->image = ren_new_image(width, height);

    /* load glyphs */
    float s =
        stbtt_ScaleForMappingEmToPixels(&font->stbfont, 1) /
        stbtt_ScaleForPixelHeight(&font->stbfont, 1);
    int res = stbtt_BakeFontBitmap(
        font->data, 0, font->size * s, (void*) set->image->pixels,
        width, height, idx * 256, 256, set->glyphs);

    /* retry with a larger image buffer if the buffer wasn't large enough */
    if (res < 0) {
        width *= 2;
        height *= 2;
        ren_free_image(set->image);
        goto retry;
    }

    /* adjust glyph yoffsets and xadvance */
    int ascent, descent, linegap;
    stbtt_GetFontVMetrics(&font->stbfont, &ascent, &descent, &linegap);
    float scale = stbtt_ScaleForMappingEmToPixels(&font->stbfont, font->size);
    int scaled_ascent = ascent * scale + 0.5;
    for (int i = 0; i < 256; i++) {
        set->glyphs[i].yoff += scaled_ascent;
        set->glyphs[i].xadvance = floor(set->glyphs[i].xadvance);
    }

    /* convert 8bit data to 32bit */
    for (int i = width * height - 1; i >= 0; i--) {
        uint8_t n = *((uint8_t*) set->image->pixels + i);
        set->image->pixels[i] = (RenColor) { .r = 255, .g = 255, .b = 255, .a = n };
    }

    return set;
}


static GlyphSet* get_glyphset(RenFont *font, int codepoint) {
    int idx = (codepoint >> 8) % MAX_GLYPHSET;
    if (!font->sets[idx]) {
        font->sets[idx] = load_glyphset(font, idx);
    }
    return font->sets[idx];
}


RenFont* ren_load_font(const char *filename, float size) {
    /* load font into buffer */ //< @r-lyeh: load font file before allocating `font`
    char *fontdata = lt_load_file(filename, NULL);
    if( !fontdata ) return NULL;

    RenFont *font = NULL;

    /* init font */
    font = lt_calloc(1, sizeof(RenFont));
    font->size = size;
    font->data = fontdata;

    /* init stbfont */
    int ok = stbtt_InitFont(&font->stbfont, font->data, 0);
    if (!ok) {
        if (font) { lt_free(font->data); }
        lt_free(font);
        return NULL;
    }

    /* get height and scale */
    int ascent, descent, linegap;
    stbtt_GetFontVMetrics(&font->stbfont, &ascent, &descent, &linegap);
    float scale = stbtt_ScaleForMappingEmToPixels(&font->stbfont, size);
    font->height = (ascent - descent + linegap) * scale + 0.5;

    /* make tab and newline glyphs invisible */
    stbtt_bakedchar *g = get_glyphset(font, '\n')->glyphs;
    g['\t'].x1 = g['\t'].x0;
    g['\n'].x1 = g['\n'].x0;

    return font;
}


void ren_free_font(RenFont *font) {
    for (int i = 0; i < MAX_GLYPHSET; i++) {
        GlyphSet *set = font->sets[i];
        if (set) {
            ren_free_image(set->image);
            lt_free(set);
        }
    }
    lt_free(font->data);
    lt_free(font);
}


void ren_set_font_tab_width(RenFont *font, int n) {
    GlyphSet *set = get_glyphset(font, '\t');
    set->glyphs['\t'].xadvance = n;
}


int ren_get_font_tab_width(RenFont *font) {
    GlyphSet *set = get_glyphset(font, '\t');
    return set->glyphs['\t'].xadvance;
}


int ren_get_font_width(RenFont *font, const char *text) {
    int x = 0;
    const char *p = text;
    unsigned codepoint;
    while (*p) {
        p = utf8_to_codepoint(p, &codepoint);
        GlyphSet *set = get_glyphset(font, codepoint);
        stbtt_bakedchar *g = &set->glyphs[codepoint & 0xff];
        x += g->xadvance;
    }
    return x;
}


int ren_get_font_height(RenFont *font) {
    return font->height;
}


static inline RenColor blend_pixel(RenColor dst, RenColor src) {
    int ia = 0xff - src.a;
    dst.r = ((src.r * src.a) + (dst.r * ia)) >> 8;
    dst.g = ((src.g * src.a) + (dst.g * ia)) >> 8;
    dst.b = ((src.b * src.a) + (dst.b * ia)) >> 8;
    dst.a = src.a + (dst.a * ia + 127) / 255;      //< Replay: alpha too (premultiplied: see rencache_end_frame)
    return dst;
}


static inline RenColor blend_pixel2(RenColor dst, RenColor src, RenColor color) {
    src.a = (src.a * color.a) >> 8;
    int ia = 0xff - src.a;
    dst.r = ((src.r * color.r * src.a) >> 16) + ((dst.r * ia) >> 8);
    dst.g = ((src.g * color.g * src.a) >> 16) + ((dst.g * ia) >> 8);
    dst.b = ((src.b * color.b * src.a) >> 16) + ((dst.b * ia) >> 8);
    dst.a = src.a + (dst.a * ia + 127) / 255;      //< Replay
    return dst;
}


#define rect_draw_loop(expr)        \
    for (int j = y1; j < y2; j++) {   \
        for (int i = x1; i < x2; i++) { \
            *d = expr;                    \
            d++;                          \
        }                               \
        d += dr;                        \
    }

void ren_draw_rect(RenRect rect, RenColor color) {
    if (color.a == 0) { return; }

    int x1 = rect.x < lt_clip.left ? lt_clip.left : rect.x;
    int y1 = rect.y < lt_clip.top  ? lt_clip.top  : rect.y;
    int x2 = rect.x + rect.width;
    int y2 = rect.y + rect.height;
    x2 = x2 > lt_clip.right  ? lt_clip.right  : x2;
    y2 = y2 > lt_clip.bottom ? lt_clip.bottom : y2;

    lt_surface *surf = lt_getsurface(lt_window());
    RenColor *d = (RenColor*) surf->pixels;
    d += x1 + y1 * surf->w;
    int dr = surf->w - (x2 - x1);

    if (color.a == 0xff) {
        rect_draw_loop(color);
    } else {
        rect_draw_loop(blend_pixel(*d, color));
    }
}


//< Replay: anti-aliased line of `width` px (round caps), clipped like rects.
// Per row, only the span the line can touch is visited; each pixel gets its
// coverage from its distance to the segment.
void ren_draw_line(float x1, float y1, float x2, float y2, float width, RenColor color) {
    if (color.a == 0) { return; }
    float hw = width * 0.5f, dx = x2 - x1, dy = y2 - y1, len2 = dx * dx + dy * dy;
    int bx1 = (int) floorf(fminf(x1, x2) - hw - 1), by1 = (int) floorf(fminf(y1, y2) - hw - 1);
    int bx2 = (int) ceilf(fmaxf(x1, x2) + hw + 1),  by2 = (int) ceilf(fmaxf(y1, y2) + hw + 1);
    if (bx1 < lt_clip.left) { bx1 = lt_clip.left; }
    if (by1 < lt_clip.top) { by1 = lt_clip.top; }
    if (bx2 > lt_clip.right) { bx2 = lt_clip.right; }
    if (by2 > lt_clip.bottom) { by2 = lt_clip.bottom; }
    if (bx1 >= bx2 || by1 >= by2) { return; }
    lt_surface *surf = lt_getsurface(lt_window());
    RenColor *pixels = (RenColor*) surf->pixels;
    for (int y = by1; y < by2; y++) {
        float cy = y + 0.5f;
        int sx = bx1, ex = bx2;
        if (fabsf(dy) > 0.01f) {                    // the line's x at this row, +- its reach
            float xc = x1 + (cy - y1) * dx / dy;
            float half = (hw + 1.5f) * sqrtf(len2) / fabsf(dy);
            int a = (int) floorf(xc - half), b = (int) ceilf(xc + half);
            if (a > sx) { sx = a; }
            if (b < ex) { ex = b; }
        }
        RenColor *d = pixels + y * surf->w;
        for (int x = sx; x < ex; x++) {
            float cx = x + 0.5f;
            float t = len2 > 0 ? ((cx - x1) * dx + (cy - y1) * dy) / len2 : 0;
            t = t < 0 ? 0 : t > 1 ? 1 : t;
            float px = x1 + t * dx - cx, py = y1 + t * dy - cy;
            float cov = hw + 0.5f - sqrtf(px * px + py * py);
            if (cov <= 0) { continue; }
            RenColor c = color;
            if (cov < 1) { c.a = (uint8_t) (color.a * cov); }
            d[x] = blend_pixel(d[x], c);
        }
    }
}


void ren_draw_image(RenImage *image, RenRect *sub, int x, int y, RenColor color) {
    if (color.a == 0) { return; }

    /* clip */
    int n;
    if ((n = lt_clip.left - x) > 0) { sub->width  -= n; sub->x += n; x += n; }
    if ((n = lt_clip.top  - y) > 0) { sub->height -= n; sub->y += n; y += n; }
    if ((n = x + sub->width  - lt_clip.right ) > 0) { sub->width  -= n; }
    if ((n = y + sub->height - lt_clip.bottom) > 0) { sub->height -= n; }

    if (sub->width <= 0 || sub->height <= 0) {
        return;
    }

    /* draw */
    lt_surface *surf = lt_getsurface(lt_window());
    RenColor *s = image->pixels;
    RenColor *d = (RenColor*) surf->pixels;
    s += sub->x + sub->y * image->width;
    d += x + y * surf->w;
    int sr = image->width - sub->width;
    int dr = surf->w - sub->width;

    for (int j = 0; j < sub->height; j++) {
        for (int i = 0; i < sub->width; i++) {
            *d = blend_pixel2(*d, *s, color);
            d++;
            s++;
        }
        d += dr;
        s += sr;
    }
}


//< Replay: an image (or the part sub of it: a tile of a sheet), scaled into
// dst (nearest pixel), alpha-blended, tinted by color; only the clipped part
// of dst is visited (a huge zoom costs what the screen does)
void ren_blit_image(RenImage *image, RenRect sub, RenRect dst, RenColor color) {
    if (!image || dst.width <= 0 || dst.height <= 0 || color.a == 0) { return; }
    if (sub.width <= 0 || sub.height <= 0) { sub = (RenRect) { 0, 0, image->width, image->height }; }
    if (sub.x < 0 || sub.y < 0 || sub.x + sub.width > image->width || sub.y + sub.height > image->height) { return; }
    int x1 = maxi(dst.x, lt_clip.left), y1 = maxi(dst.y, lt_clip.top);
    int x2 = mini(dst.x + dst.width, lt_clip.right), y2 = mini(dst.y + dst.height, lt_clip.bottom);
    if (x1 >= x2 || y1 >= y2) { return; }
    lt_surface *surf = lt_getsurface(lt_window());
    RenColor *pixels = (RenColor*) surf->pixels;
    bool plain = color.r == 255 && color.g == 255 && color.b == 255 && color.a == 255;
    for (int j = y1; j < y2; j++) {
        int sy = sub.y + (int) (((long long) (j - dst.y) * sub.height) / dst.height);
        const RenColor *srow = image->pixels + (size_t) sy * image->width + sub.x;
        RenColor *d = pixels + (size_t) j * surf->w + x1;
        for (int i = x1; i < x2; i++, d++) {
            RenColor s = srow[((long long) (i - dst.x) * sub.width) / dst.width];
            if (plain) {
                if (s.a == 255) { *d = s; } else if (s.a) { *d = blend_pixel(*d, s); }
            } else {
                *d = blend_pixel2(*d, s, color);
            }
        }
    }
}


int ren_draw_text(RenFont *font, const char *text, int x, int y, RenColor color) {
    RenRect rect;
    const char *p = text;
    unsigned codepoint;
    while (*p) {
        p = utf8_to_codepoint(p, &codepoint);
        GlyphSet *set = get_glyphset(font, codepoint);
        stbtt_bakedchar *g = &set->glyphs[codepoint & 0xff];
        rect.x = g->x0;
        rect.y = g->y0;
        rect.width = g->x1 - g->x0;
        rect.height = g->y1 - g->y0;
        ren_draw_image(set->image, &rect, x + g->xoff, y + g->yoff, color);
        x += g->xadvance;
    }
    return x;
}

// ----------------------------------------------------------------------------
// lite/renderer_font.c

static int f_load(lua_State *L) {
    const char *filename  = luaL_checkstring(L, 1);
    float size = luaL_checknumber(L, 2);
    RenFont **self = lua_newuserdata(L, sizeof(*self));
    luaL_setmetatable(L, API_TYPE_FONT);
    *self = ren_load_font(filename, size);
    if (!*self) { luaL_error(L, "failed to load font"); }
    return 1;
}


static int f_set_tab_width(lua_State *L) {
    RenFont **self = luaL_checkudata(L, 1, API_TYPE_FONT);
    int n = luaL_checknumber(L, 2);
    ren_set_font_tab_width(*self, n);
    return 0;
}


static int f_GC(lua_State *L) {
    RenFont **self = luaL_checkudata(L, 1, API_TYPE_FONT);
    if (*self) { rencache_free_font(*self); }
    return 0;
}


static int f_get_width(lua_State *L) {
    RenFont **self = luaL_checkudata(L, 1, API_TYPE_FONT);
    const char *text = luaL_checkstring(L, 2);
    lua_pushnumber(L, ren_get_font_width(*self, text) );
    return 1;
}


static int f_get_height(lua_State *L) {
    RenFont **self = luaL_checkudata(L, 1, API_TYPE_FONT);
    lua_pushnumber(L, ren_get_font_height(*self) );
    return 1;
}


int luaopen_renderer_font(lua_State *L) {
    static const luaL_Reg lib[] = {
        { "__gc",          f_GC            },
        { "load",          f_load          },
        { "set_tab_width", f_set_tab_width },
        { "get_width",     f_get_width     },
        { "get_height",    f_get_height    },
        { NULL, NULL }
    };
    luaL_newmetatable(L, API_TYPE_FONT);
    luaL_setfuncs(L, lib, 0);
    lua_pushvalue(L, -1);
    lua_setfield(L, -2, "__index");
    return 1;
}

// ----------------------------------------------------------------------------
// lite/renderer_api.c

static RenColor checkcolor(lua_State *L, int idx, int def) {
    RenColor color;
    if (lua_isnoneornil(L, idx)) {
        return (RenColor) { def, def, def, 255 };
    }
    lua_rawgeti(L, idx, 1);
    lua_rawgeti(L, idx, 2);
    lua_rawgeti(L, idx, 3);
    lua_rawgeti(L, idx, 4);
    color.r = luaL_checknumber(L, -4);
    color.g = luaL_checknumber(L, -3);
    color.b = luaL_checknumber(L, -2);
    color.a = luaL_optnumber(L, -1, 255);
    lua_pop(L, 4);
    return color;
}


static int f_show_debug(lua_State *L) {
    luaL_checkany(L, 1);
    rencache_show_debug(lua_toboolean(L, 1));
    return 0;
}


static int f_get_size(lua_State *L) {
    int w, h;
    ren_get_size(&w, &h);
    lua_pushnumber(L, w);
    lua_pushnumber(L, h);
    return 2;
}


static int f_begin_frame(lua_State *L) {
    rencache_begin_frame();
    return 0;
}


unsigned long long lite_raster_ns, lite_raster_n;    //< Replay: --prof (rasterizing + uploading lite's changed cells)
unsigned long long lite_upload_ns, lite_upload_rects; //< Replay: --prof (of which uploading: time, rects)
static int f_end_frame(lua_State *L) {
    Uint64 t0 = SDL_GetTicksNS();
    rencache_end_frame();
    lite_raster_ns += SDL_GetTicksNS() - t0; lite_raster_n++;
    return 0;
}


static int f_set_clip_rect(lua_State *L) {
    RenRect rect;
    rect.x = luaL_checknumber(L, 1);
    rect.y = luaL_checknumber(L, 2);
    rect.width = luaL_checknumber(L, 3);
    rect.height = luaL_checknumber(L, 4);
    rencache_set_clip_rect(rect);
    return 0;
}


static int f_draw_rect(lua_State *L) {
    RenRect rect;
    rect.x = luaL_checknumber(L, 1);
    rect.y = luaL_checknumber(L, 2);
    rect.width = luaL_checknumber(L, 3);
    rect.height = luaL_checknumber(L, 4);
    RenColor color = checkcolor(L, 5, 255);
    rencache_draw_rect(rect, color);
    return 0;
}


//< Replay: renderer.draw_line(x1, y1, x2, y2, width, color)
static int f_draw_line(lua_State *L) {
    float x1 = luaL_checknumber(L, 1), y1 = luaL_checknumber(L, 2);
    float x2 = luaL_checknumber(L, 3), y2 = luaL_checknumber(L, 4);
    float w = luaL_optnumber(L, 5, 1);
    RenColor color = checkcolor(L, 6, 255);
    rencache_draw_line(x1, y1, x2, y2, w, color);
    return 0;
}


static int f_draw_text(lua_State *L) {
    RenFont **font = luaL_checkudata(L, 1, API_TYPE_FONT);
    const char *text = luaL_checkstring(L, 2);
    int x = luaL_checknumber(L, 3);
    int y = luaL_checknumber(L, 4);
    RenColor color = checkcolor(L, 5, 255);
    x = rencache_draw_text(*font, text, x, y, color);
    lua_pushnumber(L, x);
    return 1;
}

//< Replay: images. renderer.image.load(path) -> Image | nil, err (PNG, JPG,
// BMP, TGA, GIF's first frame: stb_image); img:get_size() -> w, h;
// renderer.draw_image(img, x, y, w, h [, color [, sx, sy, sw, sh]]): the
// whole image (or its part sx, sy, sw, sh: a tile of a sheet) scaled into
// that rect. A draw command like the others: the redraw cache knows
// when it changed (each loaded image has its own serial)
typedef struct { RenImage *img; unsigned serial; } LtImage;
static unsigned lt_image_serial;

static int f_image_load(lua_State *L) {
    const char *filename = luaL_checkstring(L, 1);
    int size = 0;
    unsigned char *data = (unsigned char*) lt_load_file(filename, &size);
    if (!data) { lua_pushnil(L); lua_pushfstring(L, "can't read %s", filename); return 2; }
    int w = 0, h = 0, n = 0;
    unsigned char *rgba = stbi_load_from_memory(data, size, &w, &h, &n, 4);
    free(data);
    if (!rgba) { lua_pushnil(L); lua_pushfstring(L, "%s: %s", filename, stbi_failure_reason()); return 2; }
    RenImage *img = ren_new_image(w, h);
    for (int i = 0; i < w * h; i++) {
        img->pixels[i] = (RenColor) { .r = rgba[i * 4], .g = rgba[i * 4 + 1], .b = rgba[i * 4 + 2], .a = rgba[i * 4 + 3] };
    }
    stbi_image_free(rgba);
    LtImage *self = lua_newuserdata(L, sizeof(*self));
    self->img = img;
    self->serial = ++lt_image_serial;
    luaL_setmetatable(L, API_TYPE_IMAGE);
    return 1;
}

static int f_image_gc(lua_State *L) {
    LtImage *self = luaL_checkudata(L, 1, API_TYPE_IMAGE);
    if (self->img) { rencache_free_image(self->img); self->img = NULL; }
    return 0;
}

static int f_image_get_size(lua_State *L) {
    LtImage *self = luaL_checkudata(L, 1, API_TYPE_IMAGE);
    lua_pushnumber(L, self->img ? self->img->width : 0);
    lua_pushnumber(L, self->img ? self->img->height : 0);
    return 2;
}

//< Replay: renderer.image.write_atlas(path, w, h, { { file =, x =, y = [, deg = 90] }... })
// -> true | nil, err: each image file (PNG, JPG...) copied at x, y into a w x h
// RGBA picture (clear elsewhere; cut at its edges), written as a PNG
// (plugins/atlaspacker: the packed sheet). deg = 90: turned a quarter clockwise
// (an image w x h takes h x w there). renderer.image.compose(w, h, entries)
// -> Image | nil, err: the same picture, to draw (the packer's preview)
static void lt_write_io(void *ctx, void *data, int size) { SDL_WriteIO((SDL_IOStream*) ctx, data, (size_t) size); }
static unsigned char *lt_compose(lua_State *L, int W, int H, int t, char *err, size_t errsize) {
    if (W <= 0 || H <= 0 || W > 16384 || H > 16384) { SDL_strlcpy(err, "bad size", errsize); return NULL; }
    unsigned char *out = calloc((size_t) W * H, 4);
    if (!out) { SDL_strlcpy(err, "out of memory", errsize); return NULL; }
    int n = (int) lua_rawlen(L, t);
    for (int k = 1; k <= n; k++) {
        lua_rawgeti(L, t, k);
        lua_getfield(L, -1, "file"); const char *file = lua_tostring(L, -1);
        lua_getfield(L, -2, "x"); int x = (int) lua_tointeger(L, -1);
        lua_getfield(L, -3, "y"); int y = (int) lua_tointeger(L, -1);
        lua_getfield(L, -4, "deg"); int rot = ((int) lua_tointeger(L, -1) % 360 + 360) % 360 == 90;
        int size = 0, w = 0, h = 0, c = 0;
        unsigned char *data = file ? (unsigned char*) lt_load_file(file, &size) : NULL;
        unsigned char *rgba = data ? stbi_load_from_memory(data, size, &w, &h, &c, 4) : NULL;
        free(data);
        if (!rgba) {
            free(out);
            SDL_snprintf(err, errsize, "can't read %s", file ? file : "?");
            lua_pop(L, 5);
            return NULL;
        }
        for (int j = 0; j < h; j++) {
            for (int i = 0; i < w; i++) {
                int ox = rot ? x + (h - 1 - j) : x + i, oy = rot ? y + i : y + j;   // (turned: its left column on top)
                if (ox < 0 || ox >= W || oy < 0 || oy >= H) { continue; }
                memcpy(out + ((size_t) oy * W + ox) * 4, rgba + ((size_t) j * w + i) * 4, 4);
            }
        }
        stbi_image_free(rgba);
        lua_pop(L, 5);
    }
    return out;
}
static int f_image_write_atlas(lua_State *L) {
    const char *path = luaL_checkstring(L, 1);
    int W = (int) luaL_checkinteger(L, 2), H = (int) luaL_checkinteger(L, 3);
    luaL_checktype(L, 4, LUA_TTABLE);
    char err[1100];
    unsigned char *out = lt_compose(L, W, H, 4, err, sizeof err);
    if (!out) { lua_pushnil(L); lua_pushstring(L, err); return 2; }
    SDL_IOStream *io = SDL_IOFromFile(path, "wb");
    int ok = io && stbi_write_png_to_func(lt_write_io, io, W, H, 4, out, W * 4);
    if (io) { SDL_CloseIO(io); }
    free(out);
    if (!ok) { lua_pushnil(L); lua_pushfstring(L, "can't write %s", path); return 2; }
    lua_pushboolean(L, 1);
    return 1;
}
static int f_image_compose(lua_State *L) {
    int W = (int) luaL_checkinteger(L, 1), H = (int) luaL_checkinteger(L, 2);
    luaL_checktype(L, 3, LUA_TTABLE);
    char err[1100];
    unsigned char *rgba = lt_compose(L, W, H, 3, err, sizeof err);
    if (!rgba) { lua_pushnil(L); lua_pushstring(L, err); return 2; }
    RenImage *img = ren_new_image(W, H);
    for (int i = 0; i < W * H; i++) {
        img->pixels[i] = (RenColor) { .r = rgba[i * 4], .g = rgba[i * 4 + 1], .b = rgba[i * 4 + 2], .a = rgba[i * 4 + 3] };
    }
    free(rgba);
    LtImage *self = lua_newuserdata(L, sizeof(*self));
    self->img = img;
    self->serial = ++lt_image_serial;
    luaL_setmetatable(L, API_TYPE_IMAGE);
    return 1;
}

//< Replay: renderer.image.regions(path [, alpha]) -> { { x, y, w, h }... } | nil, err:
// the boxes around each patch of pixels that show (alpha above `alpha`, 0..255,
// default 16; touching corners count: 8-connected), specks under 4 px left
// out (plugins/atlaspacker: a Game & Watch screen's segments, from its "on" picture)
static int f_image_regions(lua_State *L) {
    const char *path = luaL_checkstring(L, 1);
    int cut = (int) luaL_optinteger(L, 2, 16);
    int size = 0, w = 0, h = 0, c = 0;
    unsigned char *data = (unsigned char*) lt_load_file(path, &size);
    unsigned char *rgba = data ? stbi_load_from_memory(data, size, &w, &h, &c, 4) : NULL;
    free(data);
    if (!rgba) { lua_pushnil(L); lua_pushfstring(L, "can't read %s", path); return 2; }
    unsigned char *seen = calloc((size_t) w * h, 1);
    int *stack = malloc(sizeof(int) * (size_t) w * h);
    if (!seen || !stack) { free(seen); free(stack); stbi_image_free(rgba); lua_pushnil(L); lua_pushstring(L, "out of memory"); return 2; }
    lua_newtable(L);
    int n = 0;
    for (int p0 = 0; p0 < w * h; p0++) {
        if (seen[p0] || rgba[p0 * 4 + 3] <= cut) { continue; }
        int top = 0, x0 = w, y0 = h, x1 = -1, y1 = -1, count = 0;
        stack[top++] = p0; seen[p0] = 1;
        while (top > 0) {
            int p = stack[--top], x = p % w, y = p / w;
            count++;
            if (x < x0) { x0 = x; } if (x > x1) { x1 = x; } if (y < y0) { y0 = y; } if (y > y1) { y1 = y; }
            for (int dy = -1; dy <= 1; dy++) {
                for (int dx = -1; dx <= 1; dx++) {
                    int nx = x + dx, ny = y + dy;
                    if (nx < 0 || ny < 0 || nx >= w || ny >= h) { continue; }
                    int q = ny * w + nx;
                    if (!seen[q] && rgba[q * 4 + 3] > cut) { seen[q] = 1; stack[top++] = q; }
                }
            }
        }
        if (count < 4) { continue; }
        lua_createtable(L, 0, 4);
        lua_pushinteger(L, x0); lua_setfield(L, -2, "x");
        lua_pushinteger(L, y0); lua_setfield(L, -2, "y");
        lua_pushinteger(L, x1 - x0 + 1); lua_setfield(L, -2, "w");
        lua_pushinteger(L, y1 - y0 + 1); lua_setfield(L, -2, "h");
        lua_rawseti(L, -2, ++n);
    }
    free(seen); free(stack); stbi_image_free(rgba);
    return 1;
}

static int f_draw_image(lua_State *L) {
    LtImage *self = luaL_checkudata(L, 1, API_TYPE_IMAGE);
    RenRect dst;
    dst.x = luaL_checknumber(L, 2);
    dst.y = luaL_checknumber(L, 3);
    dst.width = luaL_checknumber(L, 4);
    dst.height = luaL_checknumber(L, 5);
    RenColor color = lua_isnoneornil(L, 6) ? (RenColor) { 255, 255, 255, 255 } : checkcolor(L, 6, 255);
    RenRect sub = { 0, 0, 0, 0 };
    if (!lua_isnoneornil(L, 7)) {
        sub.x = luaL_checknumber(L, 7); sub.y = luaL_checknumber(L, 8);
        sub.width = luaL_checknumber(L, 9); sub.height = luaL_checknumber(L, 10);
    }
    if (self->img) { rencache_draw_image(self->img, self->serial, sub, dst, color); }
    return 0;
}

static int luaopen_renderer_image(lua_State *L) {
    static const luaL_Reg lib[] = {
        { "__gc",     f_image_gc       },
        { "load",     f_image_load     },
        { "write_atlas", f_image_write_atlas },
        { "compose",  f_image_compose  },
        { "regions",  f_image_regions  },
        { "get_size", f_image_get_size },
        { NULL,       NULL             }
    };
    luaL_newmetatable(L, API_TYPE_IMAGE);
    luaL_setfuncs(L, lib, 0);
    lua_pushvalue(L, -1);
    lua_setfield(L, -2, "__index");
    return 1;
}

int luaopen_renderer(lua_State *L) {
    static const luaL_Reg lib[] = {
        { "draw_image",    f_draw_image    }, //< Replay
        { "show_debug",    f_show_debug    },
        { "get_size",      f_get_size      },
        { "begin_frame",   f_begin_frame   },
        { "end_frame",     f_end_frame     },
        { "set_clip_rect", f_set_clip_rect },
        { "draw_rect",     f_draw_rect     },
        { "draw_line",     f_draw_line     }, //< Replay
        { "draw_text",     f_draw_text     },
        { NULL,            NULL            }
    };
    luaL_newlib(L, lib);
    luaopen_renderer_font(L);
    lua_setfield(L, -2, "font");
    luaopen_renderer_image(L); //< Replay
    lua_setfield(L, -2, "image");
    return 1;
}

// ----------------------------------------------------------------------------
// lite/rencache.c

/* a cache over the software renderer -- all drawing operations are stored as
** commands when issued. At the end of the frame we write the commands to a grid
** of hash values, take the cells that have changed since the previous frame,
** merge them into dirty rectangles and redraw only those regions */

#define CELLS_X 80
#define CELLS_Y 50
#define CELL_SIZE 96
#define COMMAND_BUF_SIZE (1024 * 1024 * 8) //< Replay: was 512 KB (the node graph draws many lines)

enum { FREE_FONT, SET_CLIP, DRAW_TEXT, DRAW_RECT, DRAW_LINE, DRAW_IMAGE, FREE_IMAGE }; //< Replay: DRAW_LINE, images

typedef struct {
    int type, size;
    RenRect rect;
    RenColor color;
    RenFont *font;
    int tab_width;
    char text[0];
} Command;


static unsigned cells_buf1[CELLS_X * CELLS_Y];
static unsigned cells_buf2[CELLS_X * CELLS_Y];
static unsigned *cells_prev = cells_buf1;
static unsigned *cells = cells_buf2;
static RenRect rect_buf[CELLS_X * CELLS_Y / 2];
static char command_buf[COMMAND_BUF_SIZE];
static int command_buf_idx;
static bool command_buf_lost; //< Replay: a frame's commands didn't fit: the next one redraws everything
static RenRect screen_rect;
static bool show_debug;


/* 32bit fnv-1a hash */
#define HASH_INITIAL 2166136261

static void hash(unsigned *h, const void *data, int size) {
    const unsigned char *p = data;
    while (size--) {
        *h = (*h ^ *p++) * 16777619;
    }
}


static inline int cell_idx(int x, int y) {
    return x + y * CELLS_X;
}


static inline bool rects_overlap(RenRect a, RenRect b) {
    return b.x + b.width  >= a.x && b.x <= a.x + a.width
            && b.y + b.height >= a.y && b.y <= a.y + a.height;
}


static RenRect intersect_rects(RenRect a, RenRect b) {
    int x1 = maxi(a.x, b.x);
    int y1 = maxi(a.y, b.y);
    int x2 = mini(a.x + a.width, b.x + b.width);
    int y2 = mini(a.y + a.height, b.y + b.height);
    return (RenRect) { x1, y1, max(0, x2 - x1), max(0, y2 - y1) };
}


static RenRect merge_rects(RenRect a, RenRect b) {
    int x1 = mini(a.x, b.x);
    int y1 = mini(a.y, b.y);
    int x2 = maxi(a.x + a.width, b.x + b.width);
    int y2 = maxi(a.y + a.height, b.y + b.height);
    return (RenRect) { x1, y1, x2 - x1, y2 - y1 };
}


static Command* push_command(int type, int size) {
    size_t alignment = 7; // alignof(max_align_t) - 1; //< C11 https://github.com/rxi/lite/pull/292/commits/ad1bdf56e3f212446e1c61fd45de8b94de5e2bc3
    size = (size + alignment) & ~alignment; //< https://github.com/rxi/lite/pull/292/commits/ad1bdf56e3f212446e1c61fd45de8b94de5e2bc3
    int n = command_buf_idx + size;
    if (n > COMMAND_BUF_SIZE) {
        if (!command_buf_lost) fprintf(stderr, "Warning: (" __FILE__ "): exhausted command buffer\n");
        command_buf_lost = true; //< Replay: what's dropped would leave stale cells: the next frame redraws all
        return NULL;
    }
    Command *cmd = (Command*) (command_buf + command_buf_idx);
    command_buf_idx = n;
    lt_memset(cmd, 0, sizeof(Command));
    cmd->type = type;
    cmd->size = size;
    return cmd;
}


static bool next_command(Command **prev) {
    if (*prev == NULL) {
        *prev = (Command*) command_buf;
    } else {
        *prev = (Command*) (((char*) *prev) + (*prev)->size);
    }
    return *prev != ((Command*) (command_buf + command_buf_idx));
}


void rencache_show_debug(bool enable) {
    show_debug = enable;
}


void rencache_free_font(RenFont *font) {
    Command *cmd = push_command(FREE_FONT, sizeof(Command));
    if (cmd) { cmd->font = font; }
}


void rencache_set_clip_rect(RenRect rect) {
    Command *cmd = push_command(SET_CLIP, sizeof(Command));
    if (cmd) { cmd->rect = intersect_rects(rect, screen_rect); }
}


void rencache_draw_rect(RenRect rect, RenColor color) {
    if (!rects_overlap(screen_rect, rect)) { return; }
    Command *cmd = push_command(DRAW_RECT, sizeof(Command));
    if (cmd) {
        cmd->rect = rect;
        cmd->color = color;
    }
}


//< Replay: a line command; rect = its bounding box (for the dirty cells),
// the end points and width follow the command (they are part of its hash)
void rencache_draw_line(float x1, float y1, float x2, float y2, float width, RenColor color) {
    float hw = width * 0.5f + 1;
    RenRect rect;
    rect.x = (int) floorf(fminf(x1, x2) - hw);
    rect.y = (int) floorf(fminf(y1, y2) - hw);
    rect.width = (int) ceilf(fmaxf(x1, x2) + hw) - rect.x;
    rect.height = (int) ceilf(fmaxf(y1, y2) + hw) - rect.y;
    if (!rects_overlap(screen_rect, rect)) { return; }
    Command *cmd = push_command(DRAW_LINE, sizeof(Command) + 5 * sizeof(float));
    if (cmd) {
        float v[5] = { x1, y1, x2, y2, width };
        memcpy(cmd->text, v, sizeof v);
        cmd->rect = rect;
        cmd->color = color;
    }
}


int rencache_draw_text(RenFont *font, const char *text, int x, int y, RenColor color) {
    RenRect rect;
    rect.x = x;
    rect.y = y;
    rect.width = ren_get_font_width(font, text);
    rect.height = ren_get_font_height(font);

    if (rects_overlap(screen_rect, rect)) {
        int sz = strlen(text) + 1;
        Command *cmd = push_command(DRAW_TEXT, sizeof(Command) + sz);
        if (cmd) {
            memcpy(cmd->text, text, sz);
            cmd->color = color;
            cmd->font = font;
            cmd->rect = rect;
            cmd->tab_width = ren_get_font_tab_width(font);
        }
    }

    return x + rect.width;
}


void rencache_invalidate(void) {
    lt_memset(cells_prev, 0xff, sizeof(cells_buf1));
}


//< Replay: an image's command: the image and its serial follow it (part of
// its hash: another image, or the same one reloaded, redraws)
typedef struct { RenImage *img; unsigned serial; RenRect sub; } ImageArgs;

void rencache_draw_image(RenImage *image, unsigned serial, RenRect sub, RenRect dst, RenColor color) {
    if (!rects_overlap(screen_rect, dst)) { return; }
    Command *cmd = push_command(DRAW_IMAGE, sizeof(Command) + sizeof(ImageArgs));
    if (cmd) {
        ImageArgs a = { image, serial, sub };
        memcpy(cmd->text, &a, sizeof a);
        cmd->rect = dst;
        cmd->color = color;
    }
}


void rencache_free_image(RenImage *image) { //< Replay: freed after the frame that may still draw it
    Command *cmd = push_command(FREE_IMAGE, sizeof(Command) + sizeof(ImageArgs));
    if (cmd) { ImageArgs a = { image, 0, { 0, 0, 0, 0 } }; memcpy(cmd->text, &a, sizeof a); }
    else { ren_free_image(image); }
}


void rencache_begin_frame(void) {
    /* reset all cells if the screen width/height has changed */
    int w, h;
    ren_get_size(&w, &h);
    if (screen_rect.width != w || h != screen_rect.height) {
        screen_rect.width = w;
        screen_rect.height = h;
        rencache_invalidate();
    }
}


static void update_overlapping_cells(RenRect r, unsigned h) {
    int x1 = r.x / CELL_SIZE;
    int y1 = r.y / CELL_SIZE;
    int x2 = (r.x + r.width) / CELL_SIZE;
    int y2 = (r.y + r.height) / CELL_SIZE;

    for (int y = y1; y <= y2; y++) {
        for (int x = x1; x <= x2; x++) {
            int idx = cell_idx(x, y);
            hash(&cells[idx], &h, sizeof(h));
        }
    }
}


static void push_rect(RenRect r, int *count) {
    /* try to merge with existing rectangle */
    for (int i = *count - 1; i >= 0; i--) {
        RenRect *rp = &rect_buf[i];
        if (rects_overlap(*rp, r)) {
            *rp = merge_rects(*rp, r);
            return;
        }
    }
    /* couldn't merge with previous rectangle: push */
    rect_buf[(*count)++] = r;
}


void rencache_end_frame(void) {
    /* update cells from commands */
    Command *cmd = NULL;
    RenRect cr = screen_rect;
    while (next_command(&cmd)) {
        if (cmd->type == SET_CLIP) { cr = cmd->rect; }
        RenRect r = intersect_rects(cmd->rect, cr);
        if (r.width == 0 || r.height == 0) { continue; }
        unsigned h = HASH_INITIAL;
        hash(&h, cmd, cmd->size);
        update_overlapping_cells(r, h);
    }

    /* push rects for all cells changed from last frame, reset cells */
    int rect_count = 0;
    int max_x = screen_rect.width / CELL_SIZE + 1;
    int max_y = screen_rect.height / CELL_SIZE + 1;
    for (int y = 0; y < max_y; y++) {
        for (int x = 0; x < max_x; x++) {
            /* compare previous and current cell for change */
            int idx = cell_idx(x, y);
            if (cells[idx] != cells_prev[idx]) {
                push_rect((RenRect) { x, y, 1, 1 }, &rect_count);
            }
            cells_prev[idx] = HASH_INITIAL;
        }
    }

    /* expand rects from cells to pixels */
    for (int i = 0; i < rect_count; i++) {
        RenRect *r = &rect_buf[i];
        r->x *= CELL_SIZE;
        r->y *= CELL_SIZE;
        r->width *= CELL_SIZE;
        r->height *= CELL_SIZE;
        *r = intersect_rects(*r, screen_rect);
    }

    /* redraw updated regions */
    bool has_free_commands = false;
    for (int i = 0; i < rect_count; i++) {
        /* draw */
        RenRect r = rect_buf[i];
        ren_set_clip_rect(r);
        { //< Replay: from transparent: the surface is premultiplied ARGB, composed over the game
            lt_surface *surf = lt_getsurface(lt_window());
            RenColor *row = (RenColor*) surf->pixels + r.x + r.y * surf->w;
            for (int j = 0; j < r.height; j++, row += surf->w) { lt_memset(row, 0, r.width * sizeof(RenColor)); }
        }

        cmd = NULL;
        while (next_command(&cmd)) {
            switch (cmd->type) {
                case FREE_FONT:
                    has_free_commands = true;
                    break;
                case SET_CLIP:
                    ren_set_clip_rect(intersect_rects(cmd->rect, r));
                    break;
                case DRAW_RECT:
                    ren_draw_rect(cmd->rect, cmd->color);
                    break;
                case DRAW_LINE: { //< Replay
                    float v[5];
                    memcpy(v, cmd->text, sizeof v);
                    ren_draw_line(v[0], v[1], v[2], v[3], v[4], cmd->color);
                    break;
                }
                case DRAW_IMAGE: { //< Replay
                    ImageArgs a;
                    memcpy(&a, cmd->text, sizeof a);
                    ren_blit_image(a.img, a.sub, cmd->rect, cmd->color);
                    break;
                }
                case FREE_IMAGE:
                    has_free_commands = true;
                    break;
                case DRAW_TEXT:
                    ren_set_font_tab_width(cmd->font, cmd->tab_width);
                    ren_draw_text(cmd->font, cmd->text, cmd->rect.x, cmd->rect.y, cmd->color);
                    break;
            }
        }

        if (show_debug) {
            RenColor color = { rand(), rand(), rand(), 50 };
            ren_draw_rect(r, color);
        }
    }

    /* update dirty rects */
    if (rect_count > 0) {
        extern unsigned long long lite_upload_ns, lite_upload_rects;   //< Replay: --prof
        Uint64 t0 = SDL_GetTicksNS();
        ren_update_rects(rect_buf, rect_count);
        lite_upload_ns += SDL_GetTicksNS() - t0; lite_upload_rects += rect_count;
    }

    /* free fonts (and images) */
    (void) has_free_commands; //< Replay: always looked for (a frame that redrew nothing still frees what was let go)
    {
        cmd = NULL;
        while (next_command(&cmd)) {
            if (cmd->type == FREE_FONT) {
                ren_free_font(cmd->font);
            }
            if (cmd->type == FREE_IMAGE) { //< Replay
                ImageArgs a;
                memcpy(&a, cmd->text, sizeof a);
                ren_free_image(a.img);
            }
        }
    }

    /* swap cell buffer and reset */
    unsigned *tmp = cells;
    cells = cells_prev;
    cells_prev = tmp;
    command_buf_idx = 0;
    if (command_buf_lost) { rencache_invalidate(); command_buf_lost = false; } //< Replay: (what was dropped: drawn next frame)
}

// ----------------------------------------------------------------------------
// lite/system.c

static int f_set_cursor(lua_State *L) {
    static const char *cursor_opts[] = {
        "arrow",
        "ibeam",
        "sizeh",
        "sizev",
        "hand",
        NULL
    };
    int n = luaL_checkoption(L, 1, "arrow", cursor_opts);
    lt_setcursor(n);
    return 0;
}

static int f_set_window_title(lua_State *L) {
    const char *title = luaL_checkstring(L, 1);
    lt_setwindowtitle(title);
    return 0;
}
static int f_set_window_mode(lua_State *L) {
    static const char *window_opts[] = { "normal", "maximized", "fullscreen", 0 };
    enum { WIN_NORMAL, WIN_MAXIMIZED, WIN_FULLSCREEN };
    int n = luaL_checkoption(L, 1, "normal", window_opts);
    lt_setwindowmode(n);
    return 0;
}
static int f_window_has_focus(lua_State *L) {
    unsigned flags = lt_haswindowfocus();
    lua_pushboolean(L, flags);
    return 1;
}

// system.show_dialog(title, msg, button1, ...) -> the button picked, 1..n (0: closed)  (Replay)
static int f_show_dialog(lua_State *L) {
    const char *title = luaL_checkstring(L, 1);
    const char *msg = luaL_checkstring(L, 2);
    const char *labels[4];
    int n = lua_gettop(L) - 2;
    if (n > 4) n = 4;
    for (int i = 0; i < n; i++) labels[i] = luaL_checkstring(L, 3 + i);
    lua_pushinteger(L, n > 0 ? lt_dialog(title, msg, labels, n) : 0);
    return 1;
}

static int f_show_confirm_dialog(lua_State *L) {
    const char *title = luaL_checkstring(L, 1);
    const char *msg = luaL_checkstring(L, 2);
    int id = lt_prompt(msg, title); // 0:no, 1:yes
    lua_pushboolean(L, !!id);
    return 1;
}

static int f_chdir(lua_State *L) {
    const char *path = luaL_checkstring(L, 1);
    int err = chdir(path);
    if (err) { luaL_error(L, "chdir() failed"); }
    return 0;
}
static int f_list_dir(lua_State *L) {
    const char *path = luaL_checkstring(L, 1);
    lua_newtable(L);
    lt_globpath(L, path);
    return 1;
}
static int f_absolute_path(lua_State *L) {
    const char *path = luaL_checkstring(L, 1);
    char *res = lt_realpath(path, NULL);
    if (!res) { return 0; }
    lua_pushstring(L, res);
    lt_realpath_free(res);
    return 1;
}
static int f_get_file_info(lua_State *L) {
    const char *path = luaL_checkstring(L, 1);

    struct stat s;
    int err = stat(path, &s);
    if (err < 0) {
        lua_pushnil(L);
        lua_pushstring(L, strerror(errno));
        return 2;
    }

    lua_newtable(L);
    lua_pushnumber(L, s.st_mtime);
    lua_setfield(L, -2, "modified");

    lua_pushnumber(L, s.st_size);
    lua_setfield(L, -2, "size");

    if (S_ISREG(s.st_mode)) {
        lua_pushstring(L, "file");
    } else if (S_ISDIR(s.st_mode)) {
        lua_pushstring(L, "dir");
    } else {
        lua_pushnil(L);
    }
    lua_setfield(L, -2, "type");

    return 1;
}


static int f_get_clipboard(lua_State *L) {
    const char *text = lt_getclipboard(lt_window());
    if (!text) { return 0; }
    lua_pushstring(L, text);
    return 1;
}
static int f_set_clipboard(lua_State *L) {
    const char *text = luaL_checkstring(L, 1);
    lt_setclipboard(lt_window(), text);
    return 0;
}


static int f_get_display_size(lua_State *L) {   // the monitor's size in pixels: sizes that look the same everywhere
    int w = 0, h = 0;
    lt_displaysize(&w, &h);
    lua_pushinteger(L, w);
    lua_pushinteger(L, h);
    return 2;
}

static int f_get_time(lua_State *L) {
    double ss = lt_time_ms() / 1000.0;
    lua_pushnumber(L, ss);
    return 1;
}
static int f_sleep(lua_State *L) {
    double ss = luaL_checknumber(L, 1);
    lt_sleep_ms(ss * 1000);
    return 0;
}


static int f_exec(lua_State *L) {
    size_t len;
    const char *cmd = luaL_checklstring(L, 1, &len);
    char *buf = lt_malloc(len + 32);
    if (!buf) { luaL_error(L, "buffer allocation failed"); }
#if _WIN32
    sprintf(buf, "cmd /c \"%s\"", cmd);
    WinExec(buf, SW_HIDE);
#else
    sprintf(buf, "%s &", cmd);
    int res = system(buf);
#endif
    lt_free(buf);
    return 0;
}


static int f_fuzzy_match(lua_State *L) {
    const char *str = luaL_checkstring(L, 1);
    const char *ptn = luaL_checkstring(L, 2);
    int score = 0;
    int run = 0;

    while (*str && *ptn) {
        while (*str == ' ') { str++; }
        while (*ptn == ' ') { ptn++; }
        if (tolower(*str) == tolower(*ptn)) {
            score += run * 10 - (*str != *ptn);
            run++;
            ptn++;
        } else {
            score -= 10;
            run = 0;
        }
        str++;
    }
    if (*ptn) { return 0; }

    lua_pushnumber(L, score - (int) strlen(str));
    return 1;
}

static int f_poll_event(lua_State *L) { // init.lua > core.step() wakes on mousemoved || inputtext
    int rc = lt_poll_event(L);
    return rc;
}

int luaopen_system(lua_State *L) {
    static const luaL_Reg lib[] = {
        { "poll_event",          f_poll_event          },
        { "set_cursor",          f_set_cursor          },
        { "set_window_title",    f_set_window_title    },
        { "set_window_mode",     f_set_window_mode     },
        { "window_has_focus",    f_window_has_focus    },
        { "show_confirm_dialog", f_show_confirm_dialog },
        { "show_dialog",         f_show_dialog         },
        { "chdir",               f_chdir               },
        { "list_dir",            f_list_dir            },
        { "absolute_path",       f_absolute_path       },
        { "get_file_info",       f_get_file_info       },
        { "get_clipboard",       f_get_clipboard       },
        { "set_clipboard",       f_set_clipboard       },
        { "get_time",            f_get_time            },
        { "get_display_size",    f_get_display_size    },
        { "sleep",               f_sleep               },
        { "exec",                f_exec                },
        { "fuzzy_match",         f_fuzzy_match         },
        { NULL, NULL }
    };
    luaL_newlib(L, lib);
    return 1;
}

// ----------------------------------------------------------------------------
// lite/api/api.c

void api_load_libs(lua_State *L) {
    static const luaL_Reg libs[] = {
        { "system",    luaopen_system     },
        { "renderer",  luaopen_renderer   },
        { NULL, NULL }
    };
    for (int i = 0; libs[i].name; i++) {
        luaL_requiref(L, libs[i].name, libs[i].func, 1);
    }
}

// ----------------------------------------------------------------------------
// lite/main.c

void lt_init(lua_State *L, void *handle, const char *pathdata, int argc, char **argv, float scale, const char *platform, const char *pathexe) {
    // setup renderer
    ren_init(handle);

    // setup lua context
    api_load_libs(L);

    lua_newtable(L);
    for (int i = 0; i < argc; i++) {
        lua_pushstring(L, argv[i]);
        lua_rawseti(L, -2, i + 1);
    }
    lua_setglobal(L, "ARGS");

    lua_pushstring(L, "1.11");
    lua_setglobal(L, "VERSION");

    lua_pushstring(L, platform);
    lua_setglobal(L, "PLATFORM");

    lua_pushnumber(L, scale);
    lua_setglobal(L, "SCALE");

    lua_pushstring(L, pathdata);
    lua_setglobal(L, "DATADIR");

    lua_pushstring(L, pathexe);
    lua_setglobal(L, "EXEFILE");

    // init lite
    luaL_dostring(L, "core = {}");
    luaL_dostring(L,
        "xpcall(function()\n"
        "  SCALE = tonumber(os.getenv(\"LITE_SCALE\")) or SCALE\n"
        "  PATHSEP = package.config:sub(1, 1)\n"
        "  EXEDIR = EXEFILE:match(\"^(.+)[/\\\\].*$\")\n"
        "  USERDIR = EXEDIR .. 'data/user/'\n"
        "  package.path = EXEDIR .. '/data/?.lua;' .. package.path\n"
        "  package.path = EXEDIR .. '/data/?/init.lua;' .. package.path\n"
        "  core = require('core')\n"
        "  core.init()\n"
        "end, function(err)\n"
        "  print('Error: ' .. tostring(err))\n"
        "  print(debug.traceback(nil, 2))\n"
        "  if core and core.on_error then\n"
        "    pcall(core.on_error, err)\n"
        "  end\n"
        "  os.exit(1)\n"
        "end)"
    );
}
void lt_tick(struct lua_State *L) {
    luaL_dostring(L,
        "xpcall(function()\n"
        "  core.run1()\n"
        "end, function(err)\n"
        "  print('Error: ' .. tostring(err))\n"
        "  print(debug.traceback(nil, 2))\n"
        "  if core and core.on_error then\n"
        "    pcall(core.on_error, err)\n"
        "  end\n"
        "  os.exit(1)\n"
        "end)"
    );
}
