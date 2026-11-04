// ============================================================================
// game.h -- "GFX-1408 SURVIVOR", a Vampire-Survivors style survival shooter.
//
// Why this shape: the only input channel is a 4-way UART keyboard, so the game
// attacks automatically and the player only moves. That makes the frame budget
// go into hundreds of enemies on screen -- which is exactly what this project
// wants to demonstrate.
//
// Rendering contract (see work/game-design.md):
//   * the battlefield is ONE flat colour, so dirty rectangles can be erased
//     with a fill instead of a full-screen clear (10 ms of DDR writes);
//   * double buffering means each back buffer holds a frame from two frames
//     ago, so a single "previous position" array would erase the wrong pixels.
//     Instead every buffer keeps its own draw list (g_rb) and each frame
//     erases exactly what it drew into that buffer last time.
// ============================================================================
#ifndef GAME_H
#define GAME_H

#include <stdint.h>
#include "gfx.h"
#include "hud.h"
#include "assets.h"
#include "knife8.h"
#include "small8.h"
#define GEM8_ADDR   A16ADDR(A16_GEM)
#define KNIFE8_ADDR A16ADDR(A16_KNIFE)
#define ORB8_ADDR   A16ADDR(A16_ORB)
#include "font_cn.h"

// ---------------------------------------------------------------- geometry
#define GW          1920u
#define GH          1080u
// MUST equal FB_STRIDE in main.c (4096): the game draws with this pitch while the
// framebuffer stride is programmed into the engine/scan-out separately.
#define GSTRIDE     4096u
#define G_HUD_H     132u
#define G_BG        0x10A2u          // battlefield colour, also the erase colour
#define G_HUDBG     0x2104u
#define G_ACC       0x5AEBu
#define G_BORDER    0x2945u
#define G_TRANS     0xF81Fu          // transparent colour in every sprite

#define GX_LO       8
#define GX_HI       1912             // exclusive
#define GY_LO       132
#define GY_HI       1080             // exclusive

#define GAME_ASSET_BASE 0x08A00000u
#define BG_BASE    0x0B400000u   // 1920x1080 background bitmap in DDR
#define BG_STRIDE  4096u
#define A16ADDR(i)  (GAME_ASSET_BASE + (uint32_t)(i) * 512u)
#define A32ADDR(i)  (GAME_ASSET_BASE + (uint32_t)ASSET16_N * 512u + (uint32_t)(i) * 2048u)
#define A64ADDR(i)  (A32ADDR(ASSET32_N) + (uint32_t)(i) * 8192u)

// Copy the generated sprite bitmaps into DDR once at start-up.
static void game_assets_upload(void)
{
    // Expand the 4bpp palette sprites into RGB565 directly into DDR. Doing it
    // here (instead of storing RGB565 in RAM) is what makes the 2x-scaled art
    // affordable: 16 KB of pixel data would overflow the 124 KB SoC RAM.
    volatile uint16_t *p;
    uint32_t i, k;
    for (i = 0; i < ASSET16_N; i++) {
        p = (volatile uint16_t *)(GAME_ASSET_BASE + i * 512u);
        for (k = 0; k < 256u; k++) {
            uint8_t b = asset16_idx[i][k >> 1];
            uint32_t ix = (k & 1u) ? (uint32_t)(b & 0x0Fu) : (uint32_t)(b >> 4);
            p[k] = asset_pal[ix];
        }
    }
    for (i = 0; i < ASSET32_N; i++) {
        p = (volatile uint16_t *)(A32ADDR(i));
        for (k = 0; k < 1024u; k++) {
            uint8_t b = asset32_idx[i][k >> 1];
            uint32_t ix = (k & 1u) ? (uint32_t)(b & 0x0Fu) : (uint32_t)(b >> 4);
            p[k] = asset_pal[ix];
        }
    }
    for (i = 0; i < ASSET64_N; i++) {
        p = (volatile uint16_t *)(A64ADDR(i));
        for (k = 0; k < 4096u; k++) {
            uint8_t b = asset64_idx[i][k >> 1];
            uint32_t ix = (k & 1u) ? (uint32_t)(b & 0x0Fu) : (uint32_t)(b >> 4);
            p[k] = asset_pal[ix];
        }
    }
    p = (volatile uint16_t *)GEM8_ADDR;
    for (k = 0; k < 64u; k++) p[k] = g_gem8[k];
    p = (volatile uint16_t *)KNIFE8_ADDR;
    for (k = 0; k < 64u; k++) p[k] = g_knife8[k];
    p = (volatile uint16_t *)ORB8_ADDR;
    for (k = 0; k < 64u; k++) p[k] = g_orb8[k];
}

// ---------------------------------------------------------------- pools
#define KN_MAX      50
#define GEM_MAX       40
#define PA_MAX      60
#define E8_MAX       40
#define E16_MAX     8
#define REND_MAX    800

typedef struct {
    int16_t  x, y;        // sprite top-left, pixels
    int16_t  vx, vy;      // enemy: speed in 1/16 px; knife/gem/particle: px/frame
    uint8_t  alive, kind;
    uint8_t  hp, acc;     // acc: sub-pixel accumulator
    uint8_t  t, pad;      // t: timer / life
} gobj;

// One entry of a back buffer draw list. k: 0=8x8 1=16x16 2=4x4 3=6x6
typedef struct { int16_t x, y; uint8_t k; } ritem;

// ---------------------------------------------------------------- input
typedef struct {
    uint32_t dir;      // held direction, bit0 up bit1 right bit2 down bit3 left
    uint32_t fire;     // held fire (unused by this game, kept for protocol)
    uint32_t step;     // one-shot direction from the legacy character protocol
    uint32_t start;    // edge: start / restart
    uint32_t pause;    // edge: pause toggle
    uint32_t exit;     // edge: leave the game
    uint32_t keytog;   // edge: colour key toggle (demo scenes)
    uint32_t dev;      // edge: developer shortcut (V) -> open the level-up menu
    uint32_t stress;   // edge: developer shortcut (B) -> fill every object pool
} ginput;

// ---------------------------------------------------------------- state
#define GS_TITLE    0u
#define GS_PLAY     1u
#define GS_PAUSE    2u
#define GS_OVER     3u
#define GS_UPGRADE  4u

// Upgrade pool. The reference implementation shuffles its 8 categories and
// shows 4; we do the same with 7, which is what the level-up decision is made
// of -- it is the one moment where the player actually chooses.
#define UP_FIRE     0u
#define UP_MULTI    1u
#define UP_POWER    2u
#define UP_ORB      3u
#define UP_SPEED    4u
#define UP_HEAL     5u
#define UP_MAGNET   6u
#define UP_N        7u

#define EN_A        0u
#define EN_B        1u
#define EN_C        2u
#define EN_BIG      3u
#define EN_ELITE    4u

static gobj     g_e8[E8_MAX], g_e16[E16_MAX];
static gobj     g_kn[KN_MAX], g_gem[GEM_MAX], g_pa[PA_MAX];
static ritem    g_rb[2][REND_MAX];
static uint16_t g_rbn[2];

static uint32_t g_state;
static uint32_t g_tick;            // frames since this run started
static uint32_t g_rng;
static uint32_t g_life, g_fire_lv;
static int16_t  g_px, g_py;        // player sprite top-left
static uint32_t g_inv;             // invincibility frames
static uint32_t g_kill, g_level, g_exp, g_exp_need;
static uint32_t g_sec, g_diff;
static uint32_t g_best_time;       // best survival time in seconds
static uint32_t g_fire_cd;
static uint32_t g_orb_n, g_orb_ang;
static uint32_t g_kn_dmg, g_kn_n, g_kn_int;
static uint32_t g_pmove, g_magnet;
static uint32_t g_bg_dirty;        // buffers still missing the background
static uint32_t g_repaint;         // frames to redraw a frozen scene
static uint32_t g_clear_center;
static uint32_t g_spawn_cd, g_elite_cd;
static int32_t  g_banner;
static char     g_banner_txt[20];
static uint32_t g_over_cd;
static uint8_t  g_opt[4], g_opt_n, g_opt_sel;
static uint32_t g_paint;        // frames left to repaint a frozen overlay
static uint32_t g_hud_dirty;    // frames left to repaint the HUD text
static uint32_t g_hud_sec_seen; // g_sec value the HUD text was built from
static uint32_t g_clear_left;   // menu panel clears still owed (one per buffer)
static uint32_t g_hud_fps_shown, g_hud_sec_shown;  // values locked while repainting both buffers
static uint32_t g_hud_kill_shown, g_hud_lv_shown, g_hud_life_shown;
static uint32_t g_hud_elem_shown, g_hud_enemy_shown, g_hud_diff_shown;
static uint32_t g_hud_tick;     // HUD refresh divider (30 Hz)
static uint32_t g_hud_alt;      // which text line to repaint this frame
static uint32_t g_hud3_static[2]; // line 3 drawn per buffer
static uint32_t g_stress_on;    // developer stress mode: refill pools every frame
static uint32_t g_dbg_edge;     // debug: menu selection edge count

// Cycle counter usable from inside game.h (main.c's cyc() is defined later).
static inline uint32_t gcyc(void)
{
    uint32_t c;
    asm volatile ("csrr %0, mcycle" : "=r"(c));
    return c;
}
static uint32_t g_prof_phys, g_prof_rend;   // profile: physics / render cycles
static uint32_t g_overlay_on;   // draw the CPU overlay this frame
static uint8_t  g_upg_lv[UP_N];
static uint32_t g_prev_dir;

// ---------------------------------------------------------------- helpers
static uint32_t g_rand(void)
{
    uint32_t z = (g_rng += 0x9E3779B9u);
    z = (z ^ (z >> 16)) * 0x85EBCA6Bu;
    z = (z ^ (z >> 13)) * 0xC2B2AE35u;
    return z ^ (z >> 16);
}

static inline void g_rec(uint32_t b, int32_t x, int32_t y, uint32_t k)
{
    uint16_t n = g_rbn[b];
    if (n < REND_MAX) {
        g_rb[b][n].x = (int16_t)x;
        g_rb[b][n].y = (int16_t)y;
        g_rb[b][n].k = (uint8_t)k;
        g_rbn[b] = (uint16_t)(n + 1u);
    }
}

// Draw an 8x8 or 16x16 sprite with the colour key, and remember it for erase.
static void g_spr(uint32_t back, uint32_t b, uint32_t src, int32_t x, int32_t y, uint32_t sz)
{
    g_rec(b, x, y, (sz == 16u) ? 1u : ((sz == 32u) ? 4u : ((sz == 64u) ? 5u : 0u)));
    gfx_copy_key(src,
                back + (uint32_t)y * GSTRIDE + (uint32_t)x * 2u,
                sz, sz, sz * 2u, GSTRIDE, G_TRANS);
}

// Draw a solid square with a fill command (particles) and remember it.
static void g_box(uint32_t back, uint32_t b, int32_t x, int32_t y, uint32_t sz, uint16_t col)
{
    g_rec(b, x, y, (sz == 6u) ? 3u : 2u);
    gfx_fill(back + (uint32_t)y * GSTRIDE + (uint32_t)x * 2u, sz, sz, GSTRIDE, col);
}

static inline uint32_t g_rb_size(uint32_t k)
{
    if (k == 1u) return 16u;
    if (k == 2u) return 4u;
    if (k == 3u) return 6u;
    if (k == 4u) return 32u;
    if (k == 5u) return 64u;
    return 8u;
}

// ---------------------------------------------------------------- background
// The battlefield is no longer one flat colour: a gentle vertical gradient gives
// the screen depth, and the side rails frame it. Erase restores the gradient
// colour of the rows the sprite came from (see bg_col_at).
#define G_SEG_H 144u
static const uint16_t G_SEG_COL[7] = {
    0x0861u, 0x0882u, 0x08A3u, 0x10C4u, 0x10E5u, 0x1906u, 0x1927u
};

static inline uint16_t bg_col_at(int32_t y)
{
    /* Flat background: allows erase-by-FILL (one DDR write) instead of
       erase-by-COPY (read + write), which halves the erase traffic. */
    (void)y;
    return G_SEG_COL[3];
}

// Build the full-screen background bitmap into DDR once at boot. It is drawn
// by the CPU (2M pixels, about 0.1 s) because the art needs per-pixel detail the
// engine cannot produce; afterwards the engine only COPIES small rectangles out
// of it to erase sprites, so the running cost is one extra source read per erase.
static void bg_build(void)
{
    /* Flat background bitmap so erase-by-FILL matches what is on screen. */
    gfx_fill(BG_BASE, GW, GH, BG_STRIDE, G_SEG_COL[3]);
    return;

    uint32_t x, y, i;
    for (y = 0; y < GH; y++) {
        volatile uint16_t *row = (volatile uint16_t *)(BG_BASE + y * BG_STRIDE);
        uint16_t c;
        if (y < G_HUD_H) {
            c = G_HUDBG;
        } else {
            uint32_t seg = (y - GY_LO) / G_SEG_H;
            if (seg > 6u) seg = 6u;
            c = G_SEG_COL[seg];
        }
        for (x = 0; x < GW; x++) row[x] = c;
    }
    // stars in the arena
    for (i = 0; i < 1400u; i++) {
        uint32_t sx = g_rand() % GW;
        uint32_t sy = (uint32_t)GY_LO + (g_rand() % (uint32_t)(GH - GY_LO));
        volatile uint16_t *row = (volatile uint16_t *)(BG_BASE + sy * BG_STRIDE);
        row[sx] = (g_rand() & 3u) == 0u ? 0xFFFFu : 0x6B7Du;
    }
    // brighter stars with a faint cross glint
    for (i = 0; i < 60u; i++) {
        uint32_t sx = g_rand() % GW;
        uint32_t sy = (uint32_t)GY_LO + (g_rand() % (uint32_t)(GH - GY_LO));
        volatile uint16_t *row = (volatile uint16_t *)(BG_BASE + sy * BG_STRIDE);
        if (sx > 0u && sx + 1u < GW) { row[sx - 1u] = 0x52AAu; row[sx] = 0xFFFFu; row[sx + 1u] = 0x52AAu; }
    }
    // side rails
    for (i = 0; i < 2u; i++) {
        uint32_t x0 = i ? (GW - 8u) : 0u;
        for (y = (uint32_t)GY_LO; y < GH; y++) {
            volatile uint16_t *row = (volatile uint16_t *)(BG_BASE + y * BG_STRIDE);
            uint32_t k;
            for (k = 0; k < 8u; k++) row[x0 + k] = G_BORDER;
        }
    }
    // HUD separator accent
    for (y = G_HUD_H - 4u; y < G_HUD_H; y++) {
        volatile uint16_t *row = (volatile uint16_t *)(BG_BASE + y * BG_STRIDE);
        for (x = 0; x < GW; x++) row[x] = G_ACC;
    }
}

static uint32_t game_bg(uint32_t back)
{
    uint32_t i;
    uint32_t n = 0u;
    (void)i;
    gfx_copy(BG_BASE, back, GW, GH, BG_STRIDE, GSTRIDE);
    n++;
    return n;
}

// ---------------------------------------------------------------- text
// ---------------------------------------------------------------- text
// Mixed ASCII + Chinese text drawn by the CPU. ASCII uses the 5x7 glyphs from
// hud.h, Chinese uses the 16x16 bitmaps in font_cn.h (only the ~90 glyphs the
// UI actually uses, so the table stays around 3 KB).
static const uint8_t *cn_glyph(uint32_t cp)
{
    uint32_t i;
    for (i = 0; i < CN_N; i++) if (CN_CP[i] == cp) return CN_BITS[i];
    return 0;
}

static uint32_t utf8_next(const char **ps)
{
    const unsigned char *p = (const unsigned char *)*ps;
    uint32_t c = *p++;
    if (c < 0x80u) { *ps = (const char *)p; return c; }
    if ((c & 0xE0u) == 0xC0u) {
        c = ((c & 0x1Fu) << 6) | (uint32_t)(*p++ & 0x3Fu);
    } else if ((c & 0xF0u) == 0xE0u) {
        c = ((c & 0x0Fu) << 12) | ((uint32_t)(*p & 0x3Fu) << 6);
        p++;
        c |= (uint32_t)(*p++ & 0x3Fu);
    } else {
        p += 3;
        c = 0x25A1u;      // unknown -> empty box
    }
    *ps = (const char *)p;
    return c;
}

// asc scales the 6x8 ASCII glyphs separately: a 32 px CJK cell needs ASCII
// about 3x the raw bitmap to look proportional. Pure-ASCII strings pass 1.
static uint32_t text_adv(uint32_t cp, uint32_t sc, uint32_t asc)
{
    return (cp < 0x80u) ? (6u * sc * asc) : (32u * sc);
}

static uint32_t game_text_w(const char *s, uint32_t sc, uint32_t asc)
{
    const char *p = s;
    uint32_t w = 0u;
    while (*p) w += text_adv(utf8_next(&p), sc, asc);
    return w;
}

static void game_text(volatile uint16_t *fb, uint32_t pitch, uint32_t x, uint32_t y,
                      const char *s, uint16_t fg, uint16_t bg, uint32_t sc, uint32_t asc)
{
    const char *p = s;
    uint32_t ay = (32u - 8u * asc) / 2u * sc;   // vertical centring of the ASCII cell
    while (*p) {
        uint32_t cp = utf8_next(&p);
        if (cp < 0x80u) {
            const uint8_t *g = hud_glyph((char)cp);
            uint32_t col, row, dx, dy;
            uint32_t a = sc * asc;
            for (col = 0; col < 6u; col++) {
                uint8_t bits = (col < 5u) ? g[col] : 0u;
                for (row = 0; row < 8u; row++) {
                    uint16_t px = ((bits >> row) & 1u) ? fg : bg;
                    for (dy = 0; dy < a; dy++) {
                        volatile uint16_t *q = fb + (y + ay + row * a + dy) * pitch + x + col * a;
                        for (dx = 0; dx < a; dx++) q[dx] = px;
                    }
                }
            }
            x += 6u * a;
        } else {
            const uint8_t *b = cn_glyph(cp);
            uint32_t row, col, dx, dy;
            if (!b) {                 // glyph not in the 32x32 table: skip it.
                x += 32u * sc;        // (drawing a solid block looked like a bug)
                continue;
            }
            for (row = 0; row < 32u; row++) {
                uint32_t bits = ((uint32_t)b[row * 4u] << 24) | ((uint32_t)b[row * 4u + 1u] << 16)
                              | ((uint32_t)b[row * 4u + 2u] << 8) | (uint32_t)b[row * 4u + 3u];
                for (col = 0; col < 32u; col++) {
                    uint16_t px = (bits & (1u << (31u - col))) ? fg : bg;
                    for (dy = 0; dy < sc; dy++) {
                        volatile uint16_t *q = fb + (y + row * sc + dy) * pitch + x + col * sc;
                        for (dx = 0; dx < sc; dx++) q[dx] = px;
                    }
                }
            }
            x += 32u * sc;
        }
    }
}

static char     g_line[200];
static uint32_t g_line_n;

static void ln_reset(void) { g_line_n = 0u; }
static void ln_sp(uint32_t n) { while (n--) g_line[g_line_n++] = ' '; }
static void ln_str(const char *s) { while (*s) g_line[g_line_n++] = *s++; }
static void ln_u32(uint32_t v, uint32_t digits)
{
    char b[12];
    uint32_t n = 0u, i;
    if (v == 0u) b[n++] = '0';
    while (v) { b[n++] = (char)('0' + (v % 10u)); v /= 10u; }
    while (n < digits && n < 11u) b[n++] = '0';
    for (i = 0; i < n; i++) g_line[g_line_n++] = b[n - 1u - i];
}

static void game_hud(uint32_t back, uint32_t hw_fps10, uint32_t sw_fps10, uint32_t bi_hud)
{
    volatile uint16_t *fb = (volatile uint16_t *)back;
    // Repaint the HUD text only when it actually changes (once a second), two
    // frames in a row so both back buffers get it. Drawing it every frame cost
    // ~3 ms of CPU pixel writes; while the menu is open keep it every frame.
    // HUD refreshes at 30 Hz. Every displayed value is LOCKED first and both
    // back buffers are then painted from those locked values; painting each
    // buffer from live data made the kill counter and element count flicker as
    // the two buffers alternated.
    if (g_hud_dirty == 0u && (g_hud_tick++ & 3u) == 0u) {   // 15 Hz: the CPU text repaint is the single largest frame cost
        uint32_t li, lelem = 0u, lenemy = 0u;
        for (li = 0; li < E8_MAX; li++)  if (g_e8[li].alive)  { lelem++; lenemy++; }
        for (li = 0; li < E16_MAX; li++) if (g_e16[li].alive) { lelem++; lenemy++; }
        for (li = 0; li < KN_MAX; li++)  if (g_kn[li].alive)  lelem++;
        for (li = 0; li < GEM_MAX; li++) if (g_gem[li].alive) lelem++;
        for (li = 0; li < PA_MAX; li++)  if (g_pa[li].alive)  lelem++;
        g_hud_dirty = 2u;
        g_hud_fps_shown   = hw_fps10;
        g_hud_sec_shown   = g_sec;
        g_hud_kill_shown  = g_kill;
        g_hud_lv_shown    = g_level;
        g_hud_life_shown  = g_life;
        g_hud_diff_shown  = g_diff;
        g_hud_elem_shown  = lelem + g_orb_n + 1u;
        g_hud_enemy_shown = lenemy;
    }
    if (g_state == GS_UPGRADE && g_paint == 0u && g_hud_dirty == 0u) return;
    uint32_t pitch = GSTRIDE / 2u;

    // line 3 is a static hint: draw it once per back buffer, never again
    if (!g_hud3_static[bi_hud]) {
        game_text(fb, pitch, 16u, 88u, "方向键/WASD 移动   自动攻击   P暂停   Q退出",
                  0xC618u, G_HUDBG, 1u, 3u);
        g_hud3_static[bi_hud] = 1u;
    }
    if (!g_hud_dirty) return;
    g_hud_dirty--;

    // Drawing all three lines in one frame cost 12 ms of uncached pixel writes
    // and pushed that frame past the vsync budget (measured: 20.5 ms heavy
    // frames vs 7.5 ms light ones, 42 fps under load). Lines 1 and 2 now
    // alternate, one per frame, each with its own strip wipe.
    if (g_hud_alt == 0u) {
        uint32_t dw0 = gfx_rd(G_DONE);
        gfx_fill(back + 4u * GSTRIDE, 1180u, 34u, GSTRIDE, G_HUDBG);
        while ((gfx_rd(G_DONE) - dw0) < 1u) { }
        ln_reset();
        ln_str("时间 ");
        ln_u32(g_hud_sec_shown / 60u, 2u); ln_str(":"); ln_u32(g_hud_sec_shown % 60u, 2u);
        ln_str("   击杀 "); ln_u32(g_hud_kill_shown, 4u);
        ln_str("   等级 "); ln_u32(g_hud_lv_shown, 2u);
        ln_str("   生命 "); ln_u32(g_hud_life_shown, 3u); ln_str("/150");
        g_line[g_line_n] = 0;
        // low-health warning: the whole stats line turns red at <=30% life
        game_text(fb, pitch, 16u, 8u, g_line,
                  (g_hud_life_shown <= 45u) ? 0xF800u : 0xFFFFu, G_HUDBG, 1u, 3u);
        g_hud_alt = 1u;
    } else {
        uint32_t dw0 = gfx_rd(G_DONE);
        gfx_fill(back + 44u * GSTRIDE, 1180u, 34u, GSTRIDE, G_HUDBG);
        while ((gfx_rd(G_DONE) - dw0) < 1u) { }
        ln_reset();
        ln_str("同屏 "); ln_u32(g_hud_elem_shown, 4u);
        ln_str("   敌人 "); ln_u32(g_hud_enemy_shown, 4u);
        ln_str("   难度 "); ln_u32(g_hud_diff_shown + 1u, 1u);
        ln_str("   FPS "); ln_u32(g_hud_fps_shown / 10u, 2u); ln_str("."); ln_u32(g_hud_fps_shown % 10u, 1u);
        g_line[g_line_n] = 0;
        game_text(fb, pitch, 16u, 48u, g_line, 0x07E0u, G_HUDBG, 1u, 3u);
        g_hud_alt = 0u;
    }
}

// ---------------------------------------------------------------- pools
static void game_clear_pools(void)
{
    uint32_t i;
    for (i = 0; i < E8_MAX; i++)  g_e8[i].alive = 0u;
    for (i = 0; i < E16_MAX; i++) g_e16[i].alive = 0u;
    for (i = 0; i < KN_MAX; i++)  g_kn[i].alive = 0u;
    for (i = 0; i < GEM_MAX; i++) g_gem[i].alive = 0u;
    for (i = 0; i < PA_MAX; i++)  g_pa[i].alive = 0u;
}

static void game_reset(void)
{
    g_tick = 0u;
    g_rng  = 0x5EED1234u;
    g_life = 150u;
    g_fire_lv = 1u;
    g_px = (int16_t)((GW - 64u) / 2u);
    g_py = (int16_t)((GH - 64u) / 2u);
    g_inv = 0u;
    g_kill = 0u; g_level = 1u; g_exp = 0u; g_exp_need = 5u;
    g_sec = 0u; g_diff = 0u;
    g_fire_cd = 0u;
    g_orb_n = 0u; g_orb_ang = 0u;
    g_kn_dmg = 4u; g_kn_n = 1u; g_kn_int = 12u;
    g_pmove = 8u; g_magnet = 120u;
    g_spawn_cd = 0u; g_elite_cd = 45u * 60u;
    g_banner = 0;
    g_over_cd = 0u;
    g_clear_center = 1u;
    g_opt_n = 0u; g_opt_sel = 0u;
    g_prev_dir = 0u;
    { uint32_t i; for (i = 0; i < UP_N; i++) g_upg_lv[i] = 0u; }
    game_clear_pools();
}

static void game_enter(void)
{
    game_reset();
    g_state = GS_TITLE;
    g_paint = 2u;
    bsp_printf("GAME enter (title)\r\n");
    g_rbn[0] = 0u; g_rbn[1] = 0u;
    g_bg_dirty = 2u;
    g_repaint = 0u;
}

// ---------------------------------------------------------------- spawn

static void spawn_enemy_any(uint32_t kind)
{
    uint32_t i, r;
    int32_t x, y;
    // Spawn just outside the battlefield and walk in. Sprites that are not
    // fully inside are not drawn at all (the render loop skips them), which is
    // what keeps the HUD strip and the border free of stray pixels.
    if ((g_rand() & 3u) == 0u) {
        // Ring spawn around the player: keeps local density high without
        // raising the total count, which is what makes the field look busy.
        static const int16_t RX[16] = { 64, 59, 45, 25, 0, -25, -45, -59, -64, -59, -45, -25, 0, 25, 45, 59 };
        static const int16_t RY[16] = { 0, 25, 45, 59, 64, 59, 45, 25, 0, -25, -45, -59, -64, -59, -45, -25 };
        uint32_t a = g_rand() & 15u;
        int32_t rr = 300 + (int32_t)(g_rand() % 240u);
        x = ((int32_t)g_px + 16) + ((int32_t)RX[a] * rr) / 64;
        y = ((int32_t)g_py + 16) + ((int32_t)RY[a] * rr) / 64;
        if (x < (int32_t)GX_LO) x = GX_LO;
        if (x > (int32_t)(GX_HI - 24)) x = (int32_t)(GX_HI - 24);
        if (y < (int32_t)GY_LO) y = GY_LO;
        if (y > (int32_t)(GY_HI - 24)) y = (int32_t)(GY_HI - 24);
        goto spawn_place;
    }
    r = g_rand() & 3u;
    if (r == 0u) {
        x = GX_LO - 8 + (int32_t)(g_rand() % (uint32_t)(GX_HI - GX_LO - 32));
        y = GY_LO - 8 - (int32_t)(g_rand() % 40u);
    } else if (r == 1u) {
        x = GX_LO - 8 + (int32_t)(g_rand() % (uint32_t)(GX_HI - GX_LO - 32));
        y = GY_HI - 8 + (int32_t)(g_rand() % 40u);
    } else if (r == 2u) {
        x = GX_LO - 8 - (int32_t)(g_rand() % 40u);
        y = GY_LO - 8 + (int32_t)(g_rand() % (uint32_t)(GY_HI - GY_LO - 32));
    } else {
        x = GX_HI - 8 + (int32_t)(g_rand() % 40u);
        y = GY_LO - 8 + (int32_t)(g_rand() % (uint32_t)(GY_HI - GY_LO - 32));
    }
spawn_place:

    i = 0u;
    x = (int32_t)((uint32_t)x & ~1u);
    y = (int32_t)((uint32_t)y & ~1u);
    if (kind == EN_BIG || kind == EN_ELITE) {
        for (i = 0; i < E16_MAX; i++) {
            if (!g_e16[i].alive) {
                gobj *e = &g_e16[i];
                e->alive = 1u; e->kind = (uint8_t)kind; e->acc = 0u; e->t = 0u;
                e->x = (int16_t)(x & ~1); e->y = (int16_t)(y & ~1);
                e->vx = (kind == EN_BIG) ? (int16_t)(8 + (int16_t)g_diff)
                                         : (int16_t)(11 + (int16_t)g_diff);
                e->hp = (kind == EN_BIG) ? 25u : 80u;
                return;
            }
        }
        return;
    }
    for (i = 0; i < E8_MAX; i++) {
        if (!g_e8[i].alive) {
            gobj *e = &g_e8[i];
            e->alive = 1u; e->kind = (uint8_t)kind; e->acc = 0u; e->t = 0u;
            e->x = (int16_t)(x & ~1); e->y = (int16_t)(y & ~1);
            e->hp = (kind == EN_A) ? 3u : (kind == EN_B ? 2u : 6u);
            e->vx = (kind == EN_A) ? (int16_t)(16 + (int16_t)(g_diff * 3u / 2u))
                   : (kind == EN_B ? (int16_t)(29 + (int16_t)(g_diff * 3u / 2u))
                                   : (int16_t)(13 + (int16_t)(g_diff * 3u / 2u)));
            return;
        }
    }
}

static uint32_t pick_enemy_kind(void)
{
    uint32_t r = g_rand() % 100u;
    if (g_sec >= 60u && r < 6u) return EN_BIG;
    if (g_sec >= 30u && r < 20u) return EN_C;
    if (r < 50u) return EN_A;
    return EN_B;
}

// Developer stress test (B): fill every pool at once. This is the worst case
// the renderer can face, so it lets the frame budget be checked on demand
// instead of waiting for a late-game wave.
static void spawn_stress(void)
{
    uint32_t i;
    if (!g_stress_on) return;
    for (i = 0; i < E8_MAX; i++) {
        if (!g_e8[i].alive) spawn_enemy_any((uint32_t)(EN_A + (i % 3u)));
    }
    for (i = 0; i < GEM_MAX; i++) {
        if (!g_gem[i].alive) {
            g_gem[i].alive = 1u;
            g_gem[i].kind = (uint8_t)(i & 1u);
            g_gem[i].x = (int16_t)(GX_LO + (int16_t)(g_rand() % (GW - 32u)));
            g_gem[i].y = (int16_t)(GY_LO + (int16_t)(g_rand() % (GH - GY_LO - 32u)));
            g_gem[i].vx = 0; g_gem[i].vy = 0;
        }
    }
    for (i = 0; i < PA_MAX; i++) {
        if (!g_pa[i].alive) {
            g_pa[i].alive = 1u;
            g_pa[i].kind = (uint8_t)(i & 1u);
            g_pa[i].x = (int16_t)(GX_LO + (int16_t)(g_rand() % (GW - 32u)));
            g_pa[i].y = (int16_t)(GY_LO + (int16_t)(g_rand() % (GH - GY_LO - 32u)));
            g_pa[i].vx = 2; g_pa[i].vy = 2;
            g_pa[i].t = 60u;
        }
    }
}

static void spawn_batch(void)
{
    uint32_t i, n = 2u + g_sec / 60u;   // wave size follows time directly, decoupled from the speed ramp
    if (n > 8u) n = 8u;
    for (i = 0; i < n; i++) spawn_enemy_any(pick_enemy_kind());
}

// ---------------------------------------------------------------- knife
static void knife_fire(void)
{
    static const int16_t D8X[8] = { 16, 11, 0, -11, -16, -11, 0, 11 };
    static const int16_t D8Y[8] = { 0, 11, 16, 11, 0, -11, -16, -11 };
    int32_t best = -1, bd = 0x7FFFFFFF, i, d;
    int32_t dx, dy, ax, ay;
    uint32_t dir, k;
    int32_t cx = (int32_t)g_px + 32, cy = (int32_t)g_py + 32;

    for (i = 0; i < E8_MAX; i++) {
        if (!g_e8[i].alive) continue;
        dx = (int32_t)g_e8[i].x - cx; dy = (int32_t)g_e8[i].y - cy;
        ax = dx < 0 ? -dx : dx; ay = dy < 0 ? -dy : dy;
        d = ax + ay;
        if (d < bd) { bd = d; best = i; }
    }
    for (i = 0; i < E16_MAX; i++) {
        if (!g_e16[i].alive) continue;
        dx = (int32_t)g_e16[i].x - cx; dy = (int32_t)g_e16[i].y - cy;
        ax = dx < 0 ? -dx : dx; ay = dy < 0 ? -dy : dy;
        d = ax + ay;
        if (d < bd) { bd = d; best = E8_MAX + i; }
    }
    if (best < 0) return;

    if (best < (int32_t)E8_MAX) { dx = (int32_t)g_e8[best].x - cx; dy = (int32_t)g_e8[best].y - cy; }
    else                        { dx = (int32_t)g_e16[best - (int32_t)E8_MAX].x - cx;
                                  dy = (int32_t)g_e16[best - (int32_t)E8_MAX].y - cy; }
    ax = dx < 0 ? -dx : dx; ay = dy < 0 ? -dy : dy;
    if (ax * 2 < ay)      dir = (dy >= 0) ? 2u : 6u;
    else if (ay * 2 < ax) dir = (dx >= 0) ? 0u : 4u;
    else if (dx >= 0 && dy >= 0) dir = 1u;
    else if (dx < 0 && dy >= 0)  dir = 3u;
    else if (dx < 0 && dy < 0)   dir = 5u;
    else                         dir = 7u;

    for (k = 0; k < g_kn_n; k++) {
        uint32_t i2;
        uint32_t dir2 = (g_kn_n == 1u) ? dir
                       : (g_kn_n == 2u ? (dir + ((k == 0u) ? 7u : 1u)) & 7u
                                      : (dir + ((k == 0u) ? 7u : (k == 1u ? 0u : 1u))) & 7u);
        for (i2 = 0; i2 < KN_MAX; i2++) {
            if (!g_kn[i2].alive) {
                gobj *kf = &g_kn[i2];
                kf->alive = 1u; kf->kind = 0u; kf->t = 0u; kf->acc = 0u; kf->hp = 0u;
                kf->x = (int16_t)((cx - 4) & ~1);
                kf->y = (int16_t)((cy - 4) & ~1);
                // 12 px/frame, not 26: at 26 the step is wider than the 16 px
                // hit window, so knives flew straight through enemies.
                kf->vx = (int16_t)((D8X[dir2] * 12) >> 4);
                kf->vy = (int16_t)((D8Y[dir2] * 12) >> 4);
                break;
            }
        }
    }
}

// ---------------------------------------------------------------- effects
static void spark_burst(int32_t x, int32_t y, uint32_t n)
{
    uint32_t i, j;
    for (j = 0; j < n; j++) {
        for (i = 0; i < PA_MAX; i++) {
            if (!g_pa[i].alive) {
                gobj *p = &g_pa[i];
                int32_t vx = (int32_t)(g_rand() % 17u) - 8;
                int32_t vy = (int32_t)(g_rand() % 17u) - 8;
                p->alive = 1u; p->kind = (uint8_t)(g_rand() & 1u);
                {
                    int32_t sx2 = x & ~1, sy2 = y & ~1;
                    if (sx2 < (int32_t)GX_LO) sx2 = GX_LO;
                    if (sx2 > (int32_t)(GX_HI - 6)) sx2 = (int32_t)(GX_HI - 6);
                    if (sy2 < (int32_t)GY_LO) sy2 = GY_LO;
                    if (sy2 > (int32_t)(GY_HI - 6)) sy2 = (int32_t)(GY_HI - 6);
                    p->x = (int16_t)sx2; p->y = (int16_t)sy2;
                }
                p->vx = (int16_t)vx; p->vy = (int16_t)vy;
                p->t = (uint8_t)(16u + (g_rand() % 15u));
                p->hp = p->t;
                break;
            }
        }
    }
}

static void drop_gem(int32_t x, int32_t y, uint32_t kind)
{
    uint32_t i;
    for (i = 0; i < GEM_MAX; i++) {
        if (!g_gem[i].alive) {
            g_gem[i].alive = 1u;
            g_gem[i].kind = (uint8_t)kind;
            g_gem[i].x = (int16_t)(x & ~1);
            g_gem[i].y = (int16_t)(y & ~1);
            g_gem[i].vx = 0; g_gem[i].vy = 0;
            return;
        }
    }
}

static const char *upgrade_name(uint32_t t)
{
    switch (t) {
    case UP_FIRE:   return "攻速";
    case UP_MULTI:  return "多重飞刀";
    case UP_POWER:  return "飞刀伤害";
    case UP_ORB:    return "环绕球";
    case UP_SPEED:  return "移速";
    case UP_HEAL:   return "治疗";
    default:        return "磁铁";
    }
}

static void upgrade_apply(uint32_t t)
{
    switch (t) {
    case UP_FIRE:   if (g_kn_int > 6u) g_kn_int -= 3u; break;
    case UP_MULTI:  if (g_kn_n < 3u) g_kn_n++; break;
    case UP_POWER:  g_kn_dmg += 2u; break;
    case UP_ORB:    if (g_orb_n < 6u) g_orb_n++; break;
    case UP_SPEED:  if (g_pmove < 12u) g_pmove++; break;
    case UP_HEAL:   if (g_life < 135u) g_life += 15u; else g_life = 150u; break;
    default:        if (g_magnet < 160u) g_magnet += 20u; break;
    }
    if (g_upg_lv[t] < 99u) g_upg_lv[t]++;
}

static void upgrade_open(void)
{
    uint8_t pool[UP_N];
    uint32_t i, j;
    for (i = 0; i < UP_N; i++) pool[i] = (uint8_t)i;
    for (i = 0; i < UP_N; i++) {
        j = i + (g_rand() % (UP_N - i));
        { uint8_t t = pool[i]; pool[i] = pool[j]; pool[j] = t; }
    }
    g_opt_n = 4u;
    for (i = 0; i < 4u; i++) g_opt[i] = pool[i];
    g_opt_sel = 0u;
    g_state = GS_UPGRADE;
    g_clear_left = 2u;      // start the two-buffer panel clear
    g_hud_dirty = 2u;       // the panel clear wipes the HUD text
    g_prev_dir = 0u;        // a key held while moving must not block the first edge
    g_clear_center = 1u;
    g_paint = 2u;
    bsp_printf("GAME level up -> lv=%d t=%ds\r\n", (int)g_level, (int)g_sec);
}

// ---------------------------------------------------------------- separation
// Enemies all chase the player, so without a push they collapse into one blob.
// A 16x8 cell grid (cell = 119 x 123 px) keeps the cost at a few thousand
// distance checks per frame instead of a quadratic 480*480.
#define SEP_CX       16
#define SEP_CY       8
#define SEP_CELL_MAX 16
static int16_t g_sep[SEP_CX * SEP_CY][SEP_CELL_MAX];
static uint8_t g_sepn[SEP_CX * SEP_CY];

static void sep_build(void)
{
    uint32_t i;
    for (i = 0; i < (uint32_t)(SEP_CX * SEP_CY); i++) g_sepn[i] = 0u;
    for (i = 0; i < E8_MAX; i++) {
        int32_t gx, gy, c;
        if (!g_e8[i].alive) continue;
        if (g_e8[i].x < (int16_t)GX_LO || g_e8[i].x > (int16_t)(GX_HI - 16) ||
            g_e8[i].y < (int16_t)GY_LO || g_e8[i].y > (int16_t)(GY_HI - 16)) continue;
        gx = ((int32_t)g_e8[i].x - (int32_t)GX_LO) * SEP_CX / (int32_t)(GX_HI - GX_LO);
        gy = ((int32_t)g_e8[i].y - (int32_t)GY_LO) * SEP_CY / (int32_t)(GY_HI - GY_LO);
        if (gx < 0) gx = 0;
        if (gx >= SEP_CX) gx = SEP_CX - 1;
        if (gy < 0) gy = 0;
        if (gy >= SEP_CY) gy = SEP_CY - 1;
        c = gy * SEP_CX + gx;
        if (g_sepn[c] < SEP_CELL_MAX) g_sep[c][g_sepn[c]++] = (int16_t)i;
    }
}

static void sep_apply(void)
{
    uint32_t i, k, c;
    for (i = 0; i < E8_MAX; i++) {
        int32_t gx, gy;
        if (!g_e8[i].alive) continue;
        if (g_e8[i].x < (int16_t)GX_LO || g_e8[i].x > (int16_t)(GX_HI - 16) ||
            g_e8[i].y < (int16_t)GY_LO || g_e8[i].y > (int16_t)(GY_HI - 16)) continue;
        gx = ((int32_t)g_e8[i].x - (int32_t)GX_LO) * SEP_CX / (int32_t)(GX_HI - GX_LO);
        gy = ((int32_t)g_e8[i].y - (int32_t)GY_LO) * SEP_CY / (int32_t)(GY_HI - GY_LO);
        if (gx < 0) gx = 0;
        if (gx >= SEP_CX) gx = SEP_CX - 1;
        if (gy < 0) gy = 0;
        if (gy >= SEP_CY) gy = SEP_CY - 1;
        c = (uint32_t)(gy * SEP_CX + gx);
        for (k = 0; k < g_sepn[c]; k++) {
            int32_t j = g_sep[c][k];
            int32_t dx, dy;
            if (j == (int32_t)i) continue;
            dx = (int32_t)g_e8[j].x - (int32_t)g_e8[i].x;
            if (dx <= -7 || dx >= 7) continue;
            dy = (int32_t)g_e8[j].y - (int32_t)g_e8[i].y;
            if (dy <= -7 || dy >= 7) continue;
            if (dx > 0) g_e8[i].x = (int16_t)(g_e8[i].x - 1);
            else if (dx < 0) g_e8[i].x = (int16_t)(g_e8[i].x + 1);
            if (dy > 0) g_e8[i].y = (int16_t)(g_e8[i].y - 1);
            else if (dy < 0) g_e8[i].y = (int16_t)(g_e8[i].y + 1);
            break;
        }
        if (g_e8[i].x < (int16_t)GX_LO) g_e8[i].x = GX_LO;
        if (g_e8[i].x > (int16_t)(GX_HI - 16)) g_e8[i].x = (int16_t)(GX_HI - 16);
        if (g_e8[i].y < (int16_t)GY_LO) g_e8[i].y = GY_LO;
        if (g_e8[i].y > (int16_t)(GY_HI - 16)) g_e8[i].y = (int16_t)(GY_HI - 16);
    }
}

// ---------------------------------------------------------------- physics
// One knife hit test against both enemy pools. Returns 1 when it connected
// (the caller then retires the knife).
static uint32_t knife_hit(gobj *k)
{
    int32_t j;   // used by the E16 loop below
    // Reuse the per-frame separation grid: query only the 3x3 cell block
    // around the bullet instead of scanning all 140 enemies.
    int32_t gx0 = ((int32_t)k->x - (int32_t)GX_LO) * SEP_CX / (int32_t)(GX_HI - GX_LO);
    int32_t gy0 = ((int32_t)k->y - (int32_t)GY_LO) * SEP_CY / (int32_t)(GY_HI - GY_LO);
    int32_t gy, gx;
    for (gy = gy0 - 1; gy <= gy0 + 1; gy++) {
        if (gy < 0 || gy >= SEP_CY) continue;
        for (gx = gx0 - 1; gx <= gx0 + 1; gx++) {
            uint32_t c, m;
            if (gx < 0 || gx >= SEP_CX) continue;
            c = (uint32_t)(gy * SEP_CX + gx);
            for (m = 0; m < g_sepn[c]; m++) {
                int32_t  j = g_sep[c][m];
                int32_t  dx, dy;
                gobj    *e = &g_e8[j];
                dx = (int32_t)e->x + 8 - ((int32_t)k->x + 4);
                if (dx < -12 || dx > 12) continue;
                dy = (int32_t)e->y + 8 - ((int32_t)k->y + 4);
                if (dy < -12 || dy > 12) continue;
                if (e->hp > g_kn_dmg) {
                    e->hp -= (uint8_t)g_kn_dmg;
                } else {
                    e->alive = 0u;
                    g_kill++;
                    spark_burst((int32_t)e->x, (int32_t)e->y, 3u);
                    if ((g_rand() & 3u) != 0u) drop_gem((int32_t)e->x, (int32_t)e->y, 0u);
                }
                return 1u;
            }
        }
    }
    for (j = 0; j < (int32_t)E16_MAX; j++) {
        int32_t dx, dy;
        gobj *e;
        if (!g_e16[j].alive) continue;
        e = &g_e16[j];
        dx = (int32_t)e->x + 8 - ((int32_t)k->x + 4);
        if (dx < -11 || dx > 11) continue;
        dy = (int32_t)e->y + 8 - ((int32_t)k->y + 4);
        if (dy < -11 || dy > 11) continue;
        if (e->hp > g_kn_dmg) {
            e->hp -= (uint8_t)g_kn_dmg;
        } else {
            e->alive = 0u;
            g_kill++;
            spark_burst((int32_t)e->x, (int32_t)e->y, 8u);
            drop_gem((int32_t)e->x, (int32_t)e->y, 0u);
        }
        return 1u;
    }
    return 0u;
}

static void player_hit(uint32_t dmg)
{
    if (g_inv) return;
    if (g_life > dmg) { g_life -= dmg; g_inv = 45u; }
    else {
        g_life = 0u; g_state = GS_OVER; g_over_cd = 180u; g_paint = 2u;
        if (g_sec > g_best_time) g_best_time = g_sec;
        bsp_printf("GAME over t=%ds kill=%d lv=%d\r\n",
                   (int)g_sec, (int)g_kill, (int)g_level);
    }
}

static void game_physics(const ginput *in)
{
    int32_t i, j;
    int32_t cx, cy;
    uint32_t dir = in->dir;
    int32_t mv = (int32_t)g_pmove;

    g_tick++;
    g_sec = g_tick / 60u;
    g_diff = g_sec / 45u;   // smoother ramp: one step per 45 s instead of 30 s

    // ---- player movement: 8-way, diagonal normalised by 3/4
    {
        int32_t mvx = 0, mvy = 0;
        if (dir & 1u) mvy -= mv;
        if (dir & 4u) mvy += mv;
        if (dir & 8u) mvx -= mv;
        if (dir & 2u) mvx += mv;
        if (in->step == 1u) mvy -= mv;
        if (in->step == 2u) mvx += mv;
        if (in->step == 3u) mvy += mv;
        if (in->step == 4u) mvx -= mv;
        if (mvx && mvy) { mvx = (mvx * 3) / 4; mvy = (mvy * 3) / 4; }
        g_px = (int16_t)(g_px + mvx);
        g_py = (int16_t)(g_py + mvy);
    }
    if (g_px < GX_LO) g_px = GX_LO;
    if (g_px > (int16_t)(GX_HI - 64)) g_px = (int16_t)(GX_HI - 64);
    if (g_py < GY_LO) g_py = GY_LO;
    if (g_py > (int16_t)(GY_HI - 64)) g_py = (int16_t)(GY_HI - 64);
    if (g_px & 1) g_px &= (int16_t)~1;
    if (g_py & 1) g_py &= (int16_t)~1;
    cx = (int32_t)g_px + 32; cy = (int32_t)g_py + 32;
    if (g_inv) g_inv--;

    // ---- difficulty
    if ((g_tick % 36u) == 0u) spawn_batch();
    if (g_tick >= g_elite_cd) { spawn_enemy_any(EN_ELITE); g_elite_cd += 45u * 60u; }

    // ---- knives
    if (g_fire_cd == 0u) { knife_fire(); g_fire_cd = g_kn_int; }
    g_fire_cd--;
    for (i = 0; i < KN_MAX; i++) {
        gobj *k;
        uint32_t sub;
        int32_t vx2, vy2;
        if (!g_kn[i].alive) continue;
        k = &g_kn[i];
        // Move in two half-steps and test after each: at 12 px/frame a single
        // test at the end of the step can skip an enemy whose hit window is
        // only 16 px wide.
        vx2 = k->vx / 2;
        vy2 = k->vy / 2;
        for (sub = 0; sub < 2u; sub++) {
            k->x = (int16_t)(k->x + (sub ? (k->vx - vx2) : vx2));
            k->y = (int16_t)(k->y + (sub ? (k->vy - vy2) : vy2));
            if (knife_hit(k)) { k->alive = 0u; break; }
        }
        if (!k->alive) continue;
        if (k->x < (int16_t)GX_LO || k->x > (int16_t)(GX_HI - 8) ||
            k->y < (int16_t)GY_LO || k->y > (int16_t)(GY_HI - 8)) { k->alive = 0u; }
    }

    // ---- orbs
    if (g_orb_n) {
        static const int16_t OCX[16] = { 44, 41, 31, 17, 0, -17, -31, -41, -44, -41, -31, -17, 0, 17, 31, 41 };
        static const int16_t OCY[16] = { 0, 17, 31, 41, 44, 41, 31, 17, 0, -17, -31, -41, -44, -41, -31, -17 };
        uint32_t o;
        g_orb_ang = (g_orb_ang + 1u) & 15u;
        for (o = 0; o < g_orb_n; o++) {
            uint32_t ang = (g_orb_ang + o * (16u / g_orb_n)) & 15u;
            int32_t ox = cx + OCX[ang] - 8;
            int32_t oy = cy + OCY[ang] - 8;
            for (j = 0; j < E8_MAX; j++) {
                int32_t dx, dy;
                gobj *e;
                if (!g_e8[j].alive) continue;
                e = &g_e8[j];
                dx = (int32_t)e->x + 8 - (ox + 4);
                if (dx < -13 || dx > 13) continue;
                dy = (int32_t)e->y + 8 - (oy + 4);
                if (dy < -13 || dy > 13) continue;
                if (e->t) continue;
                if (e->hp > 6u) { e->hp -= 6u; }
                else { e->alive = 0u; g_kill++; spark_burst((int32_t)e->x, (int32_t)e->y, 3u);
                       if ((g_rand() & 3u) != 0u) drop_gem((int32_t)e->x, (int32_t)e->y, 0u); }
                e->t = 12u;
            }
            // the orbs are the main close-range weapon, so they must also hit
            // the big enemies in the 16x16 pool
            for (j = 0; j < (int32_t)E16_MAX; j++) {
                int32_t dx, dy;
                gobj *e;
                if (!g_e16[j].alive) continue;
                e = &g_e16[j];
                dx = (int32_t)e->x + 8 - (ox + 4);
                if (dx < -13 || dx > 13) continue;
                dy = (int32_t)e->y + 8 - (oy + 4);
                if (dy < -13 || dy > 13) continue;
                if (e->t) continue;
                if (e->hp > 6u) { e->hp -= 6u; }
                else {
                    e->alive = 0u; g_kill++;
                    spark_burst((int32_t)e->x, (int32_t)e->y, 8u);
                    drop_gem((int32_t)e->x, (int32_t)e->y, 0u);
                }
                e->t = 12u;
            }
        }
    }

    // ---- enemies
    sep_build();
    for (i = 0; i < E8_MAX; i++) {
        gobj *e;
        int32_t dx, dy, sx, sy;
        if (!g_e8[i].alive) continue;
        e = &g_e8[i];
        dx = cx - ((int32_t)e->x + 8);
        dy = cy - ((int32_t)e->y + 8);
        sx = dx > 0 ? 1 : (dx < 0 ? -1 : 0);
        sy = dy > 0 ? 1 : (dy < 0 ? -1 : 0);
        {
            // Per-axis sub-pixel accumulation. The previous (sx*step)>>4 form
            // made diagonal movement exactly zero: step is at most 1 and the
            // diagonal scale 11 >> 4 is 0. acc holds the x fraction in the high
            // nibble and the y fraction in the low nibble.
            int32_t spd = (int32_t)e->vx;
            int32_t axm, aym, accx, accy;
            if (sx && sy) { axm = (spd * 11) >> 4; aym = axm; }
            else          { axm = sx * spd;         aym = sy * spd; }
            accx = (int32_t)(e->acc >> 4) + axm;
            accy = (int32_t)(e->acc & 15u) + aym;
            e->x = (int16_t)(e->x + (accx >> 4));
            e->y = (int16_t)(e->y + (accy >> 4));
            e->acc = (uint8_t)(((accx & 15) << 4) | (accy & 15));
        }
        if (e->t) e->t--;
        // No clamping: enemies are spawned outside the field and must be free to
        // walk in; clamping them the next frame teleported them onto the border.
        {
            int32_t ddx = cx - ((int32_t)e->x + 8);
            int32_t ddy = cy - ((int32_t)e->y + 8);
            if (ddx > -24 && ddx < 24 && ddy > -24 && ddy < 24) {
                player_hit(e->kind == EN_A ? 6u : (e->kind == EN_B ? 5u : 8u));
                if (g_state != GS_PLAY) return;
            }
        }
    }
    for (i = 0; i < E16_MAX; i++) {
        gobj *e;
        int32_t dx, dy, sx, sy;
        if (!g_e16[i].alive) continue;
        e = &g_e16[i];
        dx = cx - ((int32_t)e->x + 8);
        dy = cy - ((int32_t)e->y + 8);
        sx = dx > 0 ? 1 : (dx < 0 ? -1 : 0);
        sy = dy > 0 ? 1 : (dy < 0 ? -1 : 0);
        {
            int32_t spd = (int32_t)e->vx;
            int32_t axm, aym, accx, accy;
            if (sx && sy) { axm = (spd * 11) >> 4; aym = axm; }
            else          { axm = sx * spd;         aym = sy * spd; }
            accx = (int32_t)(e->acc >> 4) + axm;
            accy = (int32_t)(e->acc & 15u) + aym;
            e->x = (int16_t)(e->x + (accx >> 4));
            e->y = (int16_t)(e->y + (accy >> 4));
            e->acc = (uint8_t)(((accx & 15) << 4) | (accy & 15));
        }
        {
            int32_t ddx = cx - ((int32_t)e->x + 16);
            int32_t ddy = cy - ((int32_t)e->y + 16);
            if (ddx > -28 && ddx < 28 && ddy > -28 && ddy < 28) {
                player_hit(e->kind == EN_BIG ? 15u : 12u);
                if (g_state != GS_PLAY) return;
            }
        }
    }

    if ((g_tick & 1u) == 0u) sep_apply();

    // ---- gems
    for (i = 0; i < GEM_MAX; i++) {
        gobj *g;
        int32_t dx, dy, ax, ay;
        if (!g_gem[i].alive) continue;
        g = &g_gem[i];
        dx = cx - ((int32_t)g->x + 4);
        dy = cy - ((int32_t)g->y + 4);
        ax = dx < 0 ? -dx : dx; ay = dy < 0 ? -dy : dy;
        if ((uint32_t)(ax + ay) < g_magnet) {
            int32_t sp = ((ax + ay) > 100) ? 16 : 10;
            if (ax > 1) g->x = (int16_t)(g->x + (dx > 0 ? sp : -sp));
            if (ay > 1) g->y = (int16_t)(g->y + (dy > 0 ? sp : -sp));
        } else {
            /* Outside the magnet radius: drift slowly toward the player.
             * Left still, a hundred stale gems each cost an erase and a draw
             * every frame -- that was a large part of the late-game 38 fps. */
            int32_t sp = 2;
            if (ax > 1) g->x = (int16_t)(g->x + (dx > 0 ? sp : -sp));
            if (ay > 1) g->y = (int16_t)(g->y + (dy > 0 ? sp : -sp));
        }
        if (g->x < (int16_t)GX_LO) g->x = GX_LO;
        if (g->x > (int16_t)(GX_HI - 8)) g->x = (int16_t)(GX_HI - 8);
        if (g->y < (int16_t)GY_LO) g->y = GY_LO;
        if (g->y > (int16_t)(GY_HI - 8)) g->y = (int16_t)(GY_HI - 8);
        if (ax < 20 && ay < 20) {
            g->alive = 0u;
            g_exp++;
            if (g_exp >= g_exp_need) {
                g_exp -= g_exp_need;
                g_level++;
                g_fire_lv = g_level;
                g_exp_need = 5u + g_level * 4u;
                upgrade_open();
                return;
            }
        }
    }

    // ---- particles
    for (i = 0; i < PA_MAX; i++) {
        gobj *p;
        if (!g_pa[i].alive) continue;
        p = &g_pa[i];
        p->x = (int16_t)(p->x + p->vx / 2);
        p->y = (int16_t)(p->y + p->vy / 2);
        // keep sparks inside the battlefield: a 4x4 fill that crosses into the
        // HUD strip would be erased with the battlefield colour and leave a
        // permanent dark patch on the HUD
        if (p->x < (int16_t)GX_LO) p->x = GX_LO;
        if (p->x > (int16_t)(GX_HI - 6)) p->x = (int16_t)(GX_HI - 6);
        if (p->y < (int16_t)GY_LO) p->y = GY_LO;
        if (p->y > (int16_t)(GY_HI - 6)) p->y = (int16_t)(GY_HI - 6);
        if (p->t) p->t--;
        if (!p->t) p->alive = 0u;
    }

    if (g_banner > 0) {
        g_banner--;
        // the banner is drawn with flat-G_BG character cells over the gradient
        // battlefield; repaint the background once it disappears or the cells
        // stay behind as dark patches
        if (!g_banner) g_bg_dirty = 2u;
    }

    // One status line per second. The panel shows the HUD, but a serial log is
    // the only way to verify from the host that the simulation is actually
    // running (and how loaded it is) without looking at the screen.
    if ((g_tick % 60u) == 0u) {
        uint32_t e8 = 0u, e16 = 0u, kn = 0u, gem = 0u, i2;
        for (i2 = 0; i2 < E8_MAX; i2++)  if (g_e8[i2].alive)  e8++;
        for (i2 = 0; i2 < E16_MAX; i2++) if (g_e16[i2].alive) e16++;
        for (i2 = 0; i2 < KN_MAX; i2++)  if (g_kn[i2].alive)  kn++;
        for (i2 = 0; i2 < GEM_MAX; i2++) if (g_gem[i2].alive) gem++;
        bsp_printf("GAME t=%d diff=%d hp=%d kill=%d lv=%d e8=%d e16=%d kn=%d gem=%d u=%d\r\n",
                   (int)g_sec, (int)g_diff, (int)g_life, (int)g_kill, (int)g_level,
                   (int)e8, (int)e16, (int)kn, (int)gem, (int)gfx_rd(G_UNDER));
    }
}

// ---------------------------------------------------------------- render
static uint32_t game_render(uint32_t back, uint32_t b)
{
    uint32_t ncmd = 0u;
    uint32_t i;
    int32_t cx = (int32_t)g_px + 32, cy = (int32_t)g_py + 32;

    // ---- erase whatever this buffer was last given.
    // The rectangles are sorted by (row, column) and horizontally adjacent
    // rectangles of the same size are merged into one wider copy.  Every erase
    // rect is restored from the background bitmap, so each one is a DDR read
    // plus a DDR write; merging cuts both the command count and the DDR traffic
    // that the scan-out has to compete with (the flicker/underrun source).
    {
        uint32_t n = g_rbn[b], ei, ej;
        // insertion sort by (y, x) -- rbn is at most a few hundred entries
        for (ei = 1u; ei < n; ei++) {
            ritem t = g_rb[b][ei];
            ej = ei;
            while (ej > 0u) {
                ritem *p = &g_rb[b][ej - 1u];
                int32_t py = (int32_t)(int16_t)p->y;
                uint32_t px = (uint32_t)(uint16_t)p->x;
                int32_t ty = (int32_t)(int16_t)t.y;
                uint32_t tx = (uint32_t)(uint16_t)t.x;
                if (py < ty || (py == ty && px <= tx)) break;
                g_rb[b][ej] = *p;
                ej--;
            }
            g_rb[b][ej] = t;
        }
        // merge horizontally touching rects on the same row
        for (ei = 0u; ei < n; ) {
            uint32_t sz = g_rb_size(g_rb[b][ei].k);
            int32_t  ry = (int32_t)(int16_t)g_rb[b][ei].y;
            uint32_t rx = (uint32_t)(uint16_t)g_rb[b][ei].x;
            uint32_t w  = sz;
            ej = ei + 1u;
            while (ej < n
                   && (int32_t)(int16_t)g_rb[b][ej].y == ry
                   && g_rb_size(g_rb[b][ej].k) == sz
                   && (uint32_t)(uint16_t)g_rb[b][ej].x == rx + w) {
                w += sz;
                ej++;
            }
            gfx_fill(back + (uint32_t)ry * GSTRIDE + rx * 2u,
                     w, sz, GSTRIDE, G_BG);
            ncmd++;
            ei = ej;
        }
    }
    g_rbn[b] = 0u;

    if (g_clear_center) {
        // Flat fill, not a background COPY: copying the 1920x948 bitmap costs
        // ~21 ms and pushed the level-up frame to 22 ms of rend (33-50 ms wall
        // time), dropping the average fps under load to 56.8. A fill is ~10 ms
        // and only runs twice per menu open (one per back buffer).
        gfx_fill(back + 132u * GSTRIDE, GW, GH - 132u, GSTRIDE, 0x10A2u);
        g_clear_center = 0u;
        ncmd++;
    }

    // ---- draw order: gems, particles, enemies, knives, orbs, player
    // While the level-up menu is open the panel covers the arena, so nothing
    // from the battlefield may be drawn on top of it. Only the gem loop used to
    // be skipped, which left particles/enemies/knives/orbs/player printed over
    // the panel -- those were the "ghost sprites" visible on the menu.
    if (g_state == GS_UPGRADE) return ncmd;
    for (i = 0; i < GEM_MAX; i++) {
        if (!g_gem[i].alive) continue;
        g_spr(back, b, GEM8_ADDR, g_gem[i].x, g_gem[i].y, 8u);
        ncmd++;
    }
    for (i = 0; i < PA_MAX; i++) {
        uint32_t sz;
        uint16_t col;
        if (!g_pa[i].alive) continue;
        sz = (g_pa[i].kind & 1u) ? 4u : 6u;
        col = (g_pa[i].kind & 1u) ? 0xFFE0u : 0xFD20u;
        g_box(back, b, g_pa[i].x, g_pa[i].y, sz, col);
        ncmd++;
    }
    for (i = 0; i < E8_MAX; i++) {
        uint32_t spr;
        if (!g_e8[i].alive) continue;
        if (g_e8[i].x < (int16_t)GX_LO || g_e8[i].x > (int16_t)(GX_HI - 16) ||
            g_e8[i].y < (int16_t)GY_LO || g_e8[i].y > (int16_t)(GY_HI - 16)) continue;
        spr = (g_e8[i].kind == EN_A) ? A16ADDR(A16_ENEMY_A)
            : (g_e8[i].kind == EN_B) ? A16ADDR(A16_ENEMY_B) : A16ADDR(A16_ENEMY_C);
        g_spr(back, b, spr, g_e8[i].x, g_e8[i].y, 16u);
        ncmd++;
    }
    for (i = 0; i < E16_MAX; i++) {
        uint32_t spr;
        if (!g_e16[i].alive) continue;
        if (g_e16[i].x < (int16_t)GX_LO || g_e16[i].x > (int16_t)(GX_HI - 32) ||
            g_e16[i].y < (int16_t)GY_LO || g_e16[i].y > (int16_t)(GY_HI - 32)) continue;
        spr = (g_e16[i].kind == EN_BIG) ? A32ADDR(A32_ENEMY_BIG) : A32ADDR(A32_ENEMY_ELITE);
        g_spr(back, b, spr, g_e16[i].x, g_e16[i].y, 32u);
        ncmd++;
    }
    for (i = 0; i < KN_MAX; i++) {
        if (!g_kn[i].alive) continue;
        if ((i & 3u) == 0u) {              // every 4th knife is translucent
            g_rec(b, g_kn[i].x, g_kn[i].y, 1u);
            gfx_blit(KNIFE8_ADDR,
                     back + (uint32_t)g_kn[i].y * GSTRIDE + (uint32_t)g_kn[i].x * 2u,
                     8u, 8u, 16u, GSTRIDE, 128u, G_TRANS);
        } else {
            g_spr(back, b, KNIFE8_ADDR, g_kn[i].x, g_kn[i].y, 8u);
        }
        ncmd++;
    }
    if (g_orb_n) {
        static const int16_t OCX[16] = { 44, 41, 31, 17, 0, -17, -31, -41, -44, -41, -31, -17, 0, 17, 31, 41 };
        static const int16_t OCY[16] = { 0, 17, 31, 41, 44, 41, 31, 17, 0, -17, -31, -41, -44, -41, -31, -17 };
        uint32_t o;
        for (o = 0; o < g_orb_n; o++) {
            uint32_t ang = (g_orb_ang + o * (16u / g_orb_n)) & 15u;
            int32_t ox = cx + OCX[ang] - 4;
            int32_t oy = cy + OCY[ang] - 4;
            if (ox < (int32_t)GX_LO) ox = GX_LO;
            if (ox > (int32_t)(GX_HI - 16)) ox = (int32_t)(GX_HI - 16);
            if (oy < (int32_t)GY_LO) oy = GY_LO;
            if (oy > (int32_t)(GY_HI - 16)) oy = (int32_t)(GY_HI - 16);
            g_spr(back, b, ORB8_ADDR, ox, oy, 8u);
            ncmd++;
        }
    }
    if (g_state != GS_TITLE) {
        uint32_t blink = (g_inv && ((g_tick >> 2) & 1u)) ? 1u : 0u;
        uint32_t spr = blink ? A64ADDR(A64_PLAYER_HURT) : A64ADDR(A64_PLAYER);
        if (!blink) {
            g_spr(back, b, spr, g_px, g_py, 64u);
        } else {
            // the invincibility blink goes through the alpha mixer, so the
            // hardware blend path is exercised in every real game
            g_rec(b, g_px, g_py, 5u);
            gfx_blit(spr, back + (uint32_t)g_py * GSTRIDE + (uint32_t)g_px * 2u,
                     64u, 64u, 128u, GSTRIDE, 128u, G_TRANS);
        }
        ncmd++;
    }
    return ncmd;
}

// ---------------------------------------------------------------- frame
// Returns the number of engine commands issued, or -1 when the player left.
static int32_t game_frame(uint32_t back, uint32_t b, const ginput *in,
                          uint32_t hw_fps10, uint32_t sw_fps10)
{
    (void)hw_fps10;
    (void)sw_fps10;

    g_overlay_on = 0u;

    if (g_bg_dirty) {
        uint32_t nb;
        g_bg_dirty--;
        nb = game_bg(back);
        g_rbn[b] = 0u;
        g_hud_dirty = 2u;      // the fresh background has no HUD text
        return (int32_t)nb;
    }

    // ---- edge inputs
    if (in->exit) return -1;

    if (g_state == GS_UPGRADE) {
        uint32_t d = in->dir, pd = g_prev_dir;
        g_prev_dir = d;
        // Up/down selects (W/S or the arrow keys), Z/Space confirms.
        if ((d & 1u) && !(pd & 1u)) { g_opt_sel = (uint8_t)((g_opt_sel + g_opt_n - 1u) % g_opt_n); g_paint = 2u; g_dbg_edge++; }
        if ((d & 4u) && !(pd & 4u)) { g_opt_sel = (uint8_t)((g_opt_sel + 1u) % g_opt_n); g_paint = 2u; g_dbg_edge++; }
        if (in->step == 1u) { g_opt_sel = (uint8_t)((g_opt_sel + g_opt_n - 1u) % g_opt_n); g_paint = 2u; }
        if (in->step == 3u) { g_opt_sel = (uint8_t)((g_opt_sel + 1u) % g_opt_n); g_paint = 2u; }
        if (in->fire || in->start) {
            upgrade_apply(g_opt[g_opt_sel]);
            g_state = GS_PLAY;
            // The menu cleared the centre rectangle to G_BG (a flat colour).
            // Repaint the gradient background instead of leaving the flat patch:
            // the per-frame erase uses bg_col_at() gradient colours, so a flat
            // patch would collect visible coloured erase trails (diagonal
            // streaks) wherever enemies moved. g_bg_dirty repaints both back
            // buffers (one per frame).
            g_bg_dirty = 2u;
            g_clear_center = 0u;
            g_inv = 30u;
            return (int32_t)game_render(back, b);
        }
        // Redraw every frame while the menu is open. The old code repainted only
        // g_paint frames to save CPU, which froze the screen: the selection DID
        // change internally but the highlight never moved on screen, so the menu
        // looked unresponsive. One menu frame is ~15 glyphs (~15k CPU pixels,
        // about 0.45 ms), affordable at 60 fps.
        // Repaint the centre panel EVERY frame: with double buffering a single
        // g_clear_center fill only touches one back buffer, so the other buffer
        // showed the battlefield through the menu and the panel flashed as the
        // buffers alternated.
        // Repaint when the selection changed (g_paint) or while the panel buffer
        // clears are still owed. Repainting every frame cost enough CPU to hold
        // the menu at 30 fps; never repainting froze the highlight. This does
        // both: a static menu costs nothing, a key press repaints two frames.
        if (g_clear_left > 0u) { g_clear_center = 1u; g_clear_left--; g_paint = 2u; }
        if (g_paint) {
            g_paint--;
            g_overlay_on = 1u;      // only this frame draws the overlay
            return (int32_t)game_render(back, b);
        }
        return 0;
    }
    g_prev_dir = in->dir;

    if (in->start && (g_state == GS_TITLE || g_state == GS_OVER)) {
        game_reset();
        g_state = GS_PLAY;
        g_bg_dirty = 2u;     // clear title/game-over text off both buffers
        return (int32_t)game_render(back, b);
    }
    if (in->pause) {
        if (g_state == GS_PLAY) { g_state = GS_PAUSE; g_paint = 2u; }
        else if (g_state == GS_PAUSE) { g_state = GS_PLAY; g_bg_dirty = 2u; }
    }

    if (g_state == GS_TITLE) {
        if (g_paint) { g_paint--; g_overlay_on = 1u; return (int32_t)game_render(back, b); }
        return 0;
    }
    if (g_state == GS_PAUSE) {
        if (g_paint) { g_paint--; g_overlay_on = 1u; return (int32_t)game_render(back, b); }
        return 0;
    }
    if (g_state == GS_OVER) {
        if (g_over_cd) g_over_cd--;
        if (g_over_cd == 0u) {
            g_state = GS_TITLE;
            game_reset();
            g_state = GS_TITLE;
            g_paint = 2u;
            return 0;
        }
        if (g_paint) { g_paint--; g_overlay_on = 1u; return (int32_t)game_render(back, b); }
        return 0;
    }

    // ---- GS_PLAY
    if (in->stress) {              // developer mode: toggle the stress load
        g_stress_on = !g_stress_on;
        if (g_stress_on) {
            uint32_t u;
            g_level   = 99u;
            g_kn_int  = 6u;
            g_kn_dmg  = 20u;
            g_kn_n    = 5u;
            g_fire_lv = 5u;
            for (u = 0; u < UP_N; u++) g_upg_lv[u] = 5u;
        }
        bsp_printf("STRESS mode %d\r\n", (int)g_stress_on);
    }
    if (g_stress_on) spawn_stress();   // refill every frame while enabled
    if (in->dev) {                 // developer mode: force a level-up menu
        upgrade_open();
        return (int32_t)game_render(back, b);
    }
    {
        uint32_t tp = gcyc();
        game_physics(in);
        g_prof_phys = gcyc() - tp;
    }
    g_overlay_on = (g_banner > 0) ? 1u : 0u;
    {
        uint32_t tr = gcyc();
        int32_t rr = (int32_t)game_render(back, b);
        g_prof_rend = gcyc() - tr;
        return rr;
    }
}

// ---------------------------------------------------------------- overlays
// CPU-drawn text over the playfield. Called after the engine has finished and
// before the page flip, so it never races the engine for the back buffer.
// centre one line horizontally
static void game_text_c(volatile uint16_t *fb, uint32_t pitch, uint32_t y,
                        const char *s, uint16_t fg, uint16_t bg, uint32_t sc, uint32_t asc)
{
    uint32_t w = game_text_w(s, sc, asc);
    uint32_t x = (w < GW) ? ((GW - w) / 2u) : 0u;
    game_text(fb, pitch, x, y, s, fg, bg, sc, asc);
}

// CPU-drawn text over the playfield. Called after the engine has finished and
// before the page flip, so it never races the engine for the back buffer.
static void game_overlay(uint32_t back)
{
    volatile uint16_t *fb = (volatile uint16_t *)back;
    uint32_t pitch = GSTRIDE / 2u;
    char b[64];

    if (!g_overlay_on) return;

    if (g_state == GS_TITLE) {
        uint32_t mm = g_best_time / 60u, ss = g_best_time % 60u, n = 0u;
        // no demo name on the title screen (contest rule: keep it anonymous)
        game_text_c(fb, pitch, 440u, "生存", 0xFFFFu, G_BG, 2u, 3u);
        game_text_c(fb, pitch, 590u, "按 G 开始", 0xFFE0u, G_BG, 2u, 3u);
        game_text_c(fb, pitch, 710u, "方向键/WASD 移动   自动攻击", 0x8410u, G_BG, 1u, 3u);
        { const char *q = "最高 "; while (*q) b[n++] = *q++; }
        b[n++] = (char)('0' + (mm / 10u) % 10u); b[n++] = (char)('0' + mm % 10u);
        b[n++] = ':';
        b[n++] = (char)('0' + (ss / 10u) % 10u); b[n++] = (char)('0' + ss % 10u);
        b[n] = 0;
        game_text_c(fb, pitch, 810u, b, 0x07E0u, G_BG, 1u, 3u);
        game_text_c(fb, pitch, 980u, "ART BY DAWNBRINGER (CC BY 4.0)", 0x4208u, G_BG, 2u, 1u);
    } else if (g_state == GS_PAUSE) {
        game_text_c(fb, pitch, 470u, "暂停", 0xFFFFu, G_BG, 3u, 3u);
        game_text_c(fb, pitch, 660u, "按 P 继续", 0x8410u, G_BG, 2u, 3u);
    } else if (g_state == GS_OVER) {
        uint32_t mm = g_sec / 60u, ss = g_sec % 60u, n = 0u;
        game_text_c(fb, pitch, 380u, "游戏结束", 0xF800u, G_BG, 3u, 3u);
        { const char *q = "存活 "; while (*q) b[n++] = *q++; }
        b[n++] = (char)('0' + (mm / 10u) % 10u); b[n++] = (char)('0' + mm % 10u);
        b[n++] = ':';
        b[n++] = (char)('0' + (ss / 10u) % 10u); b[n++] = (char)('0' + ss % 10u);
        b[n] = 0;
        game_text_c(fb, pitch, 560u, b, 0xFFFFu, G_BG, 1u, 3u);
        {
            char k[48]; uint32_t m = 0u, j;
            const char *q = "击杀 ";
            while (*q) k[m++] = *q++;
            { char nb[12]; j = 0u; hud_num(nb, g_kill, 0u); while (nb[j] && j < 8u) k[m++] = nb[j++]; }
            q = "   等级 ";
            while (*q) k[m++] = *q++;
            { char nb[12]; j = 0u; hud_num(nb, g_level, 0u); while (nb[j] && j < 8u) k[m++] = nb[j++]; }
            k[m] = 0;
            game_text_c(fb, pitch, 660u, k, 0x07E0u, G_BG, 1u, 3u);
        }
        game_text_c(fb, pitch, 770u, "按 G 重开", 0xFFE0u, G_BG, 2u, 3u);
    } else if (g_state == GS_UPGRADE) {
        uint32_t i;
        game_text_c(fb, pitch, 190u, "升级", 0xFFE0u, G_BG, 3u, 3u);
        for (i = 0; i < g_opt_n; i++) {
            uint32_t n = 0u, y = 380u + i * 130u;
            const char *s = upgrade_name(g_opt[i]);
            uint16_t fg = (i == g_opt_sel) ? 0xFFFFu : 0x8410u;
            uint16_t bg = (i == g_opt_sel) ? 0x18E3u : G_BG;
            while (*s) b[n++] = *s++;
            b[n++] = ' '; b[n++] = ' '; b[n++] = ' '; b[n++] = ' ';
            { const char *q = "等级 "; while (*q) b[n++] = *q++; }
            b[n++] = (char)('0' + (g_upg_lv[g_opt[i]] % 10u));
            b[n] = 0;
            game_text_c(fb, pitch, y, b, fg, bg, 2u, 3u);
        }
        game_text_c(fb, pitch, 930u, "上下选择   空格确认", 0x8410u, G_BG, 1u, 3u);
    } else if (g_state == GS_PLAY && g_banner > 0) {
        game_text_c(fb, pitch, 460u, g_banner_txt, 0xFFE0u, G_BG, 2u, 3u);
    }
}

#endif // GAME_H
