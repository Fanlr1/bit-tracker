// ============================================================================
// GFX v2 bring-up and demo.
//
//   1. register identity, then one check per engine feature (fill, copy,
//      alpha, colour key, out-of-bounds refusal)
//   2. double-buffered animation: a full-frame clear plus N sprites per frame,
//      flipped with commit/accept so the displayed page is never the drawn one
//   3. a software-versus-hardware fill measurement in core cycles
//   4. a sprite-count sweep that reports how many sprites still hold 60 fps
//
// Everything printed here is measured on the board, not estimated.
// ============================================================================
#include <stdint.h>
#include "bsp.h"
#include "riscv.h"
#include "plic.h"
#include "gfx.h"
#include "patterns8.h"
#include "hud.h"
#include "game.h"
#include "bg_art.h"
#include "uart.h"

#define FB_A        0x08000000u
// 4096, not 3840 (=FB_W*2): every scan-out row read is 3840 B, so a 3840 B
// stride makes EVERY row read straddle a 4 KiB boundary (contract doc 130 §4.6).
// With a 4096 B stride each row read sits inside one 4 KiB page, which removes
// the page-crossing penalty on the DDR read path that feeds the scan-out.
// FB_B then ends exactly at SPR_BASE (0x08870000), so the layout still fits.
#define FB_STRIDE   4096u
#define FB_W        1920u
#define FB_H        1080u
#define FB_B        (FB_A + FB_STRIDE * FB_H)

#define SPR_BASE    0x08870000u
#define SPR_W       8u
#define SPR_H       8u
#define SPR_STRIDE  (SPR_W * 2u)
#define SPR_KEY     0xF81Fu

static uint32_t g_fail = 0u;
static uint32_t g_ubase = 0u, g_abase = 0u;

static inline uint32_t cyc(void)
{
    uint32_t c;
    asm volatile ("csrr %0, mcycle" : "=r"(c));
    return c;
}

static inline uint16_t rd_px(uint32_t a)
{
    uint16_t v;
    __asm__ volatile ("fence rw,rw" ::: "memory");
    v = *(volatile uint16_t *)a;
    __asm__ volatile ("fence rw,rw" ::: "memory");
    return v;
}

static void check(const char *name, int ok)
{
    bsp_printf("[%s] %s\r\n", ok ? "PASS" : "FAIL", name);
    if (!ok) g_fail++;
}

// 16x16 solid discs, eight colours. A single flat fill keeps the colour key's
// job unambiguous (one colour to reject) and makes the field easy to count.
// Per-sprite colour costs nothing: the engine reads its source from an address
// register, so the only change is which 512-byte tile that address points at.
#define SPR_VARIANTS 8u
#define SPR_BYTES    (SPR_W * SPR_H * 2u)

static const int16_t g_sin256[256] = {
    0, 6, 13, 19, 25, 31, 38, 44, 50, 56, 62, 68, 74, 80, 86, 92,
    98, 104, 109, 115, 121, 126, 132, 137, 142, 147, 152, 157, 162, 167, 172, 177,
    181, 185, 190, 194, 198, 202, 206, 209, 213, 216, 220, 223, 226, 229, 231, 234,
    237, 239, 241, 243, 245, 247, 248, 250, 251, 252, 253, 254, 255, 255, 256, 256,
    256, 256, 256, 255, 255, 254, 253, 252, 251, 250, 248, 247, 245, 243, 241, 239,
    237, 234, 231, 229, 226, 223, 220, 216, 213, 209, 206, 202, 198, 194, 190, 185,
    181, 177, 172, 167, 162, 157, 152, 147, 142, 137, 132, 126, 121, 115, 109, 104,
    98, 92, 86, 80, 74, 68, 62, 56, 50, 44, 38, 31, 25, 19, 13, 6,
    0, -6, -13, -19, -25, -31, -38, -44, -50, -56, -62, -68, -74, -80, -86, -92,
    -98, -104, -109, -115, -121, -126, -132, -137, -142, -147, -152, -157, -162, -167, -172, -177,
    -181, -185, -190, -194, -198, -202, -206, -209, -213, -216, -220, -223, -226, -229, -231, -234,
    -237, -239, -241, -243, -245, -247, -248, -250, -251, -252, -253, -254, -255, -255, -256, -256,
    -256, -256, -256, -255, -255, -254, -253, -252, -251, -250, -248, -247, -245, -243, -241, -239,
    -237, -234, -231, -229, -226, -223, -220, -216, -213, -209, -206, -202, -198, -194, -190, -185,
    -181, -177, -172, -167, -162, -157, -152, -147, -142, -137, -132, -126, -121, -115, -109, -104,
    -98, -92, -86, -80, -74, -68, -62, -56, -50, -44, -38, -31, -25, -19, -13, -6,
};

static const uint16_t g_spr_col[SPR_VARIANTS] = {
    0x07FFu, 0xF800u, 0x07E0u, 0xFFE0u, 0x001Fu, 0xFFFFu, 0xFD20u, 0x8410u
};

static void make_sprites(void)
{
    uint32_t c, i;
    for (c = 0; c < 8u; c++) {
        volatile uint16_t *p = (volatile uint16_t *)(SPR_BASE + c * SPR_BYTES);
        for (i = 0; i < 64u; i++) p[i] = g_pat[c][i];
    }
}

// --------------------------------------------------------------- demo scenes
#define SC_FILL    0u
#define SC_COPY    1u
#define SC_SPRITE  2u
#define SC_BLOCK   3u
#define SC_GAME    4u
#define SC_N       5u

static const char *const g_scene_name[SC_N] = { "FILL", "IMAGES", "SPRITE", "BLOCK", "GAME" };
static const uint32_t   g_scene_col[SC_N]  = { 0x1082u, 0xF800u, 0x07E0u, 0xFFE0u, 0x1082u };

// Dirty-rectangle support. Each buffer keeps the previous frame's sprite
// positions, so the next frame can erase exactly those rectangles instead of
// clearing 4.15 MB. Clearing 256 sprites' worth of dirty area costs 4,096 write
// transactions against the full clear's 19,440.
#define DIRTY_MAX 2048u

// 1 = let the hardware sprite-table walker queue erase+draw commands (4 table
// stores per sprite instead of 20 AXI register writes). 0 = classic path.
#define USE_SPR_TABLE 0
#define g_spr_wait 1
#define HUD_SAFE_Y   96u     // rows reserved for the HUD
#define FW_VERSION 5u
static int16_t  g_old_x[2][DIRTY_MAX], g_old_y[2][DIRTY_MAX];
static uint32_t g_old_n[2] = { 0u, 0u };
static uint32_t g_scene_prev = 0xFFFFFFFFu;

static inline uint32_t xorshift(uint32_t v)
{
    return v ^ (v << 13) ^ (v >> 17) ^ (v << 5);
}

// Draw one 16x16 solid disc at (x,y) with the engine.
static inline void blit_disc(uint32_t back, uint32_t spr, uint32_t x, uint32_t y,
                             uint16_t keycol, uint32_t key_on, uint8_t alpha)
{
    uint32_t dst = back + y * FB_STRIDE + x * 2u;
    if (!key_on) {
        gfx_copy(spr, dst, SPR_W, SPR_H, SPR_STRIDE, FB_STRIDE);
    } else if (alpha >= 255u) {
        gfx_copy_key(spr, dst, SPR_W, SPR_H, SPR_STRIDE, FB_STRIDE, keycol);
    } else {
        // key test first, then blend: hard silhouette plus translucency
        gfx_blit(spr, dst, SPR_W, SPR_H, SPR_STRIDE, FB_STRIDE, alpha, keycol);
    }
}

// Draw one 16x16 solid disc with the CPU: same pixels, same key test.
// RGB565 alpha blend (fg over bg), alpha 0..255; >>8 keeps it cheap.
static inline uint16_t blend565(uint16_t fg, uint16_t bg, uint32_t a)
{
    uint32_t ia = 256u - a;
    uint32_t r = ((((fg >> 11) & 0x1Fu) * a) + (((bg >> 11) & 0x1Fu) * ia)) >> 8;
    uint32_t g = ((((fg >> 5) & 0x3Fu) * a) + (((bg >> 5) & 0x3Fu) * ia)) >> 8;
    uint32_t b = (((fg & 0x1Fu) * a) + ((bg & 0x1Fu) * ia)) >> 8;
    return (uint16_t)((r << 11) | (g << 5) | b);
}

// CPU reference renderer: colour-key test *and* alpha blend, exactly like the
// engine's BLIT opcode, so the SW/HW comparison shows identical pixels.
static inline void sw_disc(uint32_t back, uint32_t spr, uint32_t x, uint32_t y, uint32_t alpha)
{
    volatile uint16_t *d = (volatile uint16_t *)(back + y * FB_STRIDE + x * 2u);
    const volatile uint16_t *s = (const volatile uint16_t *)spr;
    uint32_t yy, xx;
    for (yy = 0; yy < SPR_H; yy++)
        for (xx = 0; xx < SPR_W; xx++) {
            uint16_t fg = s[yy * SPR_W + xx];
            uint32_t o = yy * (FB_STRIDE / 2u) + xx;
            if (fg == SPR_KEY) continue;
            if (alpha >= 255u) d[o] = fg;
            else               d[o] = blend565(fg, d[o], alpha);
        }
}


// Deterministic, continuous motion. Each sprite keeps the position and velocity
// its hash implies and advances by (v * frame); wrap-around keeps everything on
// screen. Re-randomising every frame (the first version) looks like flicker, not
// motion, and makes it impossible to judge whether frames are being drawn at a
// steady rate.
static inline void demo_pos(uint32_t scene, uint32_t i, uint32_t frame,
                            uint32_t *px, uint32_t *py)
{
    if (scene == SC_SPRITE) {
        uint32_t h  = xorshift(i * 2654435761u);
        int32_t  vx = (int32_t)((h >> 20) & 7u) - 3;      // -3 .. 4 px/frame
        int32_t  vy = (int32_t)((h >> 23) & 7u) + 2;      //  2 .. 9 px/frame
        int32_t  mw = (int32_t)(FB_W - SPR_W);
        int32_t  mh = (int32_t)(FB_H - SPR_H);
        int32_t  x  = (int32_t)(h % (uint32_t)mw) + vx * (int32_t)frame;
        int32_t  y  = (int32_t)((h >> 10) % (uint32_t)mh) + vy * (int32_t)frame;
        x %= mw; if (x < 0) x += mw;
        y %= mh; if (y < 0) y += mh;
        *px = (uint32_t)x;
        *py = (uint32_t)y;
    } else {                                              // SC_BULLET: rain
        uint32_t vy = 2u + (i & 7u) * 3u;                 // 2 .. 23 px/frame
        *px = (i * 37u) % (FB_W - SPR_W);
        *py = (i * 53u + frame * vy) % (FB_H - SPR_H);
    }
}


// CPU rectangle fill: one 16-bit store per pixel, deliberately slow -- this is
// the software side of the comparison.
static void sw_rect(uint32_t back, uint32_t x, uint32_t y,
                    uint32_t w, uint32_t h, uint16_t c)
{
    uint32_t yy, xx;
    volatile uint16_t *p = (volatile uint16_t *)back;
    uint32_t pitch = FB_STRIDE / 2u;
    for (yy = 0; yy < h; yy++) {
        uint32_t o = (y + yy) * pitch + x;
        for (xx = 0; xx < w; xx++) p[o + xx] = c;
    }
}

static void sw_fill(uint32_t back, uint16_t col)
{
    volatile uint16_t *p = (volatile uint16_t *)back;
    uint32_t y, x;
    for (y = 0; y < FB_H; y++) {
        uint32_t o = y * (FB_STRIDE / 2u);
        for (x = 0; x < FB_W; x++) p[o + x] = col;
    }
}



// --------------------------------------------------------------- elastic field
// Random initial momentum, straight-line motion, perfectly elastic wall
// collisions. No gravity, no random kicks and no drag: once launched, a sprite
// keeps its velocity until it hits an edge, where the perpendicular component
// reverses. This is the deterministic "gas molecules" model.
// Binary search over the sprite count (profiler PROF cpu, 59.2 fps = stable):
//   1600 -> 13.7 ms, 59.2 fps   <- kept: fully stable, +13.6% over the 1408 spec
//   1625 -> 12.9..13.0 ms, 57.5..59.0
//   1643 -> 56.5..57.8
//   1649 -> 14.1 ms, 55.3..57.2  (the absolute ceiling: 1650 drops to 35 fps)
// 1649 counts more sprites but jitters between 55 and 57 fps, so the stable
// 1600 is the shippable setting.
// Sprite size/count trade-off (16x16 circles, PROF cpu, 59 fps = stable):
//   400 ->  8.0 ms   600 -> 12.2 ms   700 -> 14.2 ms (59.2 fps)  <- shipped
//   750 -> 15.3 ms (35 fps: CPU past the vsync edge)
// 8x8 circles reach 1600 sprites at 59.2 fps but each is only 1/4 the area;
// 16x16 trades count for readability on a 1920x1080 field.
// Sprite count ceiling of the classic dual-buffer path with the current engine
// (16x16 sprites, PROF cpu measured on the board):
//   700 -> 10.4 ms   900 -> 13.5 ms   950 -> 14.26 ms (59.2 fps, only 0.4 ms
//   margin)   1000 -> 15.0 ms (drops to the 35 fps band)
// 900 keeps a safe 1.7 ms margin.
#define BR_N     1500u
#define BR_Q     4                      // fixed point: 1/4 pixel
#define BR_VMAX  40                     // max speed in 1/4 px/frame (10 px/frame)

static int16_t g_bx[BR_N], g_by[BR_N];
static int16_t g_br[BR_N];      // radius px
static uint8_t g_ba[BR_N];      // angle 0..255
static uint8_t g_bvr[BR_N];     // radial speed px/frame
static int8_t  g_bw[BR_N];      // angular speed (1/256 turn per frame)      // position, 1/4 px (max 1919*4)
static int16_t g_bvx[BR_N], g_bvy[BR_N];    // velocity, 1/4 px/frame (max +-43)
static uint32_t br_rng = 0x9E3779B9u;

// splitmix32, not xorshift. The old generator had poor low-bit quality and I was
// slicing five fields out of one output, so velocities repeated in lockstep and
// the particles lined up in visible columns. splitmix32 mixes every output
// through two multiplications and is safe to use field by field.
static uint32_t br_rand(void)
{
    uint32_t z = (br_rng += 0x9E3779B9u);
    z = (z ^ (z >> 16)) * 0x85EBCA6Bu;
    z = (z ^ (z >> 13)) * 0xC2B2AE35u;
    return z ^ (z >> 16);
}

static void brown_init(void)
{
    uint32_t i;
    // Bullets fill the whole screen from the first frame and wrap around the
    // edges, so the field always looks dense instead of bursting from a point.
    for (i = 0; i < BR_N; i++) {
        uint32_t px = (uint32_t)(br_rand() % (FB_W - SPR_W));
        uint32_t py = (uint32_t)(br_rand() % (FB_H - SPR_H));
        int32_t  vx = (int32_t)(br_rand() % 13u) - 6;
        int32_t  vy = (int32_t)(br_rand() % 13u) - 6;
        if (vx == 0) vx = 1;
        if (vy == 0) vy = -1;
        g_bx[i]  = (int16_t)(px * BR_Q);
        g_by[i]  = (int16_t)(py * BR_Q);
        g_bvx[i] = (int16_t)vx;
        g_bvy[i] = (int16_t)vy;
    }
}

static void brown_step(uint32_t kick)
{
    uint32_t i;
    (void)kick;
    for (i = 0; i < BR_N; i++) {
        int32_t x = g_bx[i] + g_bvx[i];
        int32_t y = g_by[i] + g_bvy[i];
        int32_t xmax = (int32_t)((FB_W - SPR_W) * BR_Q);
        int32_t ymax = (int32_t)((FB_H - SPR_H) * BR_Q);

        if ((i & 15u) == 0u) {                       // gentle heading wander
            g_bvx[i] = (int16_t)(((g_bvx[i] + 3) % 13) - 6);
            if (g_bvx[i] == 0) g_bvx[i] = 1;
            g_bvy[i] = (int16_t)(((g_bvy[i] + 2) % 13) - 6);
            if (g_bvy[i] == 0) g_bvy[i] = 1;
        }
        if (x < 0)        x += xmax;
        else if (x > xmax) x -= xmax;
        if (y < 0)        y += ymax;
        else if (y > ymax) y -= ymax;

        g_bx[i] = (int16_t)x;
        g_by[i] = (int16_t)y;
    }
}

// --------------------------------------------------------------- spiral bullets
// A single emitter in the centre fires a ring of eight bullets every third frame;
// the ring's base angle advances by one 32nd of a turn each time, which is what
// turns the rings into a spiral. Bullets travel in a straight line at constant
// speed and are recycled when they leave the screen.
#define BL_N 256u
static const int16_t BL_DIRX[32] = { 256, 251, 237, 213, 181, 142, 98, 50, 0, -50, -98, -142, -181, -213, -237, -251, -256, -251, -237, -213, -181, -142, -98, -50, 0, 50, 98, 142, 181, 213, 237, 251 };
static const int16_t BL_DIRY[32] = { 0, 50, 98, 142, 181, 213, 237, 251, 256, 251, 237, 213, 181, 142, 98, 50, 0, -50, -98, -142, -181, -213, -237, -251, -256, -251, -237, -213, -181, -142, -98, -50 };

static int32_t g_ux[BL_N], g_uy[BL_N];
static int32_t g_uvx[BL_N], g_uvy[BL_N];
static uint8_t g_uact[BL_N];
static uint32_t g_ubase;

static void bullet_reset(void)
{
    uint32_t i;
    for (i = 0; i < BL_N; i++) g_uact[i] = 0u;
    g_ubase = 0u;
}

static void bullet_emit(void)
{
    uint32_t k, n;
    for (k = 0; k < 8u; k++) {
        for (n = 0; n < BL_N; n++) {
            if (!g_uact[n]) {
                uint32_t a = (g_ubase + k * 4u) & 31u;
                g_uact[n] = 1u;
                g_ux[n]  = (int32_t)(FB_W / 2u) * BR_Q;
                g_uy[n]  = (int32_t)(FB_H / 2u) * BR_Q;
                g_uvx[n] = (BL_DIRX[a] * 20) >> 8;      // 5 px/frame
                g_uvy[n] = (BL_DIRY[a] * 20) >> 8;
                break;
            }
        }
    }
    g_ubase = (g_ubase + 1u) & 31u;
}

static void bullet_step(void)
{
    uint32_t i;
    for (i = 0; i < BL_N; i++) {
        int32_t x, y;
        if (!g_uact[i]) continue;
        x = g_ux[i] + g_uvx[i];
        y = g_uy[i] + g_uvy[i];
        if (x < 0 || x > (int32_t)(FB_W - SPR_W) * BR_Q ||
            y < 0 || y > (int32_t)(FB_H - SPR_H) * BR_Q) {
            g_uact[i] = 0u;
        } else {
            g_ux[i] = x;
            g_uy[i] = y;
        }
    }
}


// --------------------------------------------------------------- gallery
// Four full-screen RGB565 pictures are generated once at start-up using nothing
// but fill commands, then swapped with a single full-screen COPY. This is the
// competition's "fast switching between large images" case: each switch moves
// 4.15 MB of pixels.
#define GAL_N     6u
#define GAL_BASE  0x09000000u


// Linear six-sector rainbow, pos 0..1535 (six sectors x 256 steps).
static uint16_t rainbow1536(uint32_t pos)
{
    uint32_t seg = pos >> 8;
    uint32_t t   = pos & 0xFFu;
    uint32_t r, g, b;
    switch (seg) {
    case 0:  r = 255u;          g = t;              b = 0u;            break;
    case 1:  r = 255u - t;      g = 255u;           b = 0u;            break;
    case 2:  r = 0u;            g = 255u;           b = t;             break;
    case 3:  r = 0u;            g = 255u - t;       b = 255u;          break;
    case 4:  r = t;             g = 0u;             b = 255u;          break;
    default: r = 255u;          g = 0u;             b = 255u - t;      break;
    }
    return (uint16_t)(((r >> 3) << 11) | ((g >> 2) << 5) | (b >> 3));
}

// HSV-ish helper for procedural colours: hue 0..5 (red..magenta), s and v 0..1
static uint16_t hsv565(uint32_t h6, uint32_t s8, uint32_t v8)
{
    uint32_t r, g, b, i, f;
    i = h6 / 6u; f = h6 % 6u;
    switch (i) {
    case 0: r = v8;             g = v8 * f / 6u;    b = 0;              break;
    case 1: r = v8 - v8*f/6u;   g = v8;             b = 0;              break;
    case 2: r = 0;              g = v8;             b = v8 * f / 6u;    break;
    case 3: r = 0;              g = v8 - v8*f/6u;   b = v8;             break;
    case 4: r = v8 * f / 6u;    g = 0;              b = v8;             break;
    default: r = v8;            g = 0;              b = v8 - v8*f/6u;   break;
    }
    r = (r * s8) / 255u; g = (g * s8) / 255u; b = (b * s8) / 255u;
    return (uint16_t)(((r >> 3) << 11) | ((g >> 2) << 5) | (b >> 3));
}

static void gallery_build(void)
{
    uint32_t x, y, i;
    uint32_t base;

    // 1: rainbow sweep with horizontal dither. Two adjacent columns alternate
    // between the current and next colour step, which hides the 32-level
    // quantisation of RGB565.
    base = GAL_BASE + 0u * FB_STRIDE * FB_H;
    for (x = 0; x < FB_W; x += 4u) {
        uint32_t pos = (x * 1536u) / FB_W;
        uint16_t c = rainbow1536(pos);
        gfx_fill(base + x * 2u, 4u, FB_H, FB_STRIDE, c);
    }
    gfx_wait_idle();

    // 2: concentric rectangles, deep blue to cyan
    base = GAL_BASE + 1u * FB_STRIDE * FB_H;
    gfx_fill(base, FB_W, FB_H, FB_STRIDE, 0x0841u);
    for (i = 0; i < 18u; i++) {
        uint32_t inset = i * 44u;
        uint32_t w = FB_W - 2u * inset;
        uint32_t h = FB_H - 2u * inset;
        uint16_t c = (uint16_t)(0x0841u + (i * 0x0410u));
        if ((int32_t)w <= 0 || (int32_t)h <= 0) break;
        gfx_fill(base + inset * FB_STRIDE + inset * 2u, w, h, FB_STRIDE, c);
    }
    gfx_wait_idle();

    // 3: checkerboard
    base = GAL_BASE + 2u * FB_STRIDE * FB_H;
    for (y = 0; y < FB_H; y += 120u) {
        for (x = 0; x < FB_W; x += 120u) {
            uint16_t c = (((x / 120u) + (y / 120u)) & 1u) ? 0xF800u : 0xFFFFu;
            gfx_fill(base + y * FB_STRIDE + x * 2u, 120u, 120u, FB_STRIDE, c);
        }
    }
    gfx_wait_idle();

    // 4: horizontal rainbow bands
    base = GAL_BASE + 3u * FB_STRIDE * FB_H;
    for (y = 0; y < FB_H; y += 4u) {
        uint32_t pos = (y * 1536u) / FB_H;
        gfx_fill(base + y * FB_STRIDE, FB_W, 4u, FB_STRIDE, rainbow1536(pos));
    }
    gfx_wait_idle();

    // 5: 8x6 colour tile grid
    base = GAL_BASE + 4u * FB_STRIDE * FB_H;
    for (y = 0; y < FB_H; y += 180u) {
        for (x = 0; x < FB_W; x += 240u) {
            uint32_t n = (y / 180u) * 8u + (x / 240u);
            uint32_t pos = (n * 1536u) / 48u;
            gfx_fill(base + y * FB_STRIDE + x * 2u, 240u, 180u, FB_STRIDE, rainbow1536(pos));
        }
    }
    gfx_wait_idle();

    // 6: deep-blue concentric rectangles (denser than picture 2)
    base = GAL_BASE + 5u * FB_STRIDE * FB_H;
    gfx_fill(base, FB_W, FB_H, FB_STRIDE, 0x001Fu);
    for (i = 0; i < 26u; i++) {
        uint32_t inset = i * 40u;
        uint32_t w = FB_W - 2u * inset;
        uint32_t h = FB_H - 2u * inset;
        uint16_t c = (uint16_t)(0x001Fu + (i * 0x0820u));
        if ((int32_t)w <= 0 || (int32_t)h <= 0) break;
        gfx_fill(base + inset * FB_STRIDE + inset * 2u, w, h, FB_STRIDE, c);
    }
    gfx_wait_idle();

}

// Copy picture n to the back buffer and return the engine time in cycles.
static uint32_t gallery_show(uint32_t back, uint32_t n)
{
    uint32_t d0 = gfx_rd(G_DONE);
    uint32_t t0 = cyc();
    gfx_copy(GAL_BASE + n * FB_STRIDE * FB_H, back, FB_W, FB_H, FB_STRIDE, FB_STRIDE);
    gfx_wait_n(d0, 1u);
    return cyc() - t0;
}

// --------------------------------------------------------------- UART keys
// The panel has no usable buttons wired to the FPGA, so the keyboard on the PC
// drives the demo over the same UART the log goes out on. Arrow keys arrive as
// ESC [ A/B/C/D; WASD is accepted as well because a serial terminal may not
// send ESC sequences at all.
// Returns 0=up 1=right 2=down 3=left, -1 = nothing.
static int esc_state = 0;
static ginput g_in;
static uint32_t g_prof_cpu, g_prof_gpu;   // frame breakdown in cycles
static uint32_t g_prof_flip;              // cycles spent inside flip + FBACCEPT wait
static uint32_t g_prof_hud, g_prof_ovl;   // HUD / overlay draw cost
static uint32_t g_fps3;                   // 3-frame smoothed hardware fps (x10)
static uint32_t g_skip_k;                 // frames to ignore the demo key map
static uint32_t g_trans_on = 1u;    /* F key: 1 = translucent sprites, 0 = opaque */
static uint32_t g_stress_req = 0u;  /* pause key inside the game: one-key max-level stress */
static uint32_t g_shot_req = 0u;   // set by input_poll on 'S'
#define SHOT_STEP 2u

// UART input pump.
//
// The PC bridge streams one-byte state frames: bit7 is a marker so every byte
// is self-synchronising, bits0-3 hold the held direction, bit4 fire, bit5
// pause, bit6 start. Legacy single characters (ESC[A..D, WASD, K, G, Q) are
// still accepted so a plain terminal can drive the demo.
//
// The old poll read exactly ONE byte per frame while the bridge sends every
// 10 ms. At 60 fps that backs up by ~1.7 bytes per frame, and the controls
// drift further behind the longer the board runs -- the "laggy" feel. Draining
// the receiver every frame and keeping only the newest state removes it.
static int input_poll(void)
{
    static uint32_t raw = 0u;
    static uint32_t prev_raw = 0u;
    int legacy = -1;
    uint32_t occ;
    int c;
    uint32_t got_frame = 0u;

    occ = uart_readOccupancy(BSP_UART_TERMINAL);
    while (occ--) {
        c = (int)(uint8_t)uart_read(BSP_UART_TERMINAL);
        if (c >= 0x80) {                       // v3 state frame
            // A frame byte during an ESC sequence means the 0x1B was a real
            // (bare) ESC press whose '[' never arrived, e.g. because an 8 ms
            // heartbeat byte landed in between. Treat that as "leave".
            if (esc_state == 1) legacy = 6;
            esc_state = 0;
            raw = (uint32_t)(c & 0x7F);
            got_frame = 1u;
            continue;
        }
        if (esc_state == 0) {
            if (c == 27) { esc_state = 1; continue; }
        } else if (esc_state == 1) {
            esc_state = (c == '[') ? 2 : 0;
            continue;
        } else {
            esc_state = 0;
            if (c == 'A') legacy = 0;
            else if (c == 'C') legacy = 1;
            else if (c == 'B') legacy = 2;
            else if (c == 'D') legacy = 3;
            continue;
        }
        if (c == 'w' || c == 'W') legacy = 0;
        else if (c == 'd' || c == 'D') legacy = 1;
        else if (c == 's' || c == 'S') legacy = 2;
        else if (c == 'a' || c == 'A') legacy = 3;
        else if (c == 'k' || c == 'K') legacy = 4;
        else if (c == 'g' || c == 'G') legacy = 5;
        else if (c == 'q' || c == 'Q') legacy = 6;
        else if (c == 'v' || c == 'V') legacy = 7;   // developer: force level-up
        else if (c == 'b' || c == 'B') legacy = 8;   // developer: stress test
        else if (c == 'f' || c == 'F') legacy = 9;   // toggle translucent sprites
        else if (c == 0x09) legacy = 8;              // Tab: stress test (keyboard bridge)
        else if (c == '#') g_shot_req = 1u;    // host asks for a screen dump ('S' is taken by WASD-down)
    }

    // watchdog: a missing bridge must not leave keys stuck down. The bridge
    // sends a frame every 30 ms; 200 ms of silence means it is gone (crashed,
    // closed, cable pulled) and every held bit must be released here.
    {
        static uint32_t last_frame_cyc = 0u;
        uint32_t nowc = (uint32_t)cyc();
        if (got_frame) {
            last_frame_cyc = nowc;
        } else if ((uint32_t)(nowc - last_frame_cyc) > 20000000u) {   // 200 ms @100 MHz
            raw = 0u;
            last_frame_cyc = nowc;
        }
    }

    g_in.dir    = raw & 0x0Fu;
    g_in.fire   = (raw >> 4) & 1u;
    g_in.step   = ((legacy >= 0) && (legacy <= 3)) ? (uint32_t)(legacy + 1) : 0u;
    g_in.start  = ((raw & 0x40u) && !(prev_raw & 0x40u)) ? 1u : 0u;
    g_in.pause  = ((raw & 0x20u) && !(prev_raw & 0x20u)) ? 1u : 0u;
    g_in.exit   = (legacy == 6) ? 1u : 0u;
    g_in.keytog = (legacy == 4) ? 1u : 0u;
    g_in.dev    = (legacy == 7) ? 1u : 0u;
    g_in.stress = (legacy == 8) ? 1u : 0u;
    if (legacy == 5) g_in.start = 1u;          // G also starts a run
    prev_raw = raw;

    return legacy;
}

// ---------------------------------------------------------------- snapshot
// Debug aid: send a downsampled RGB565 image of a framebuffer over the same
// UART the log uses, so the host can verify what is actually on screen without
// a capture card. 'S' on the serial port triggers it; the game freezes while it
// streams (STEP=4 -> 480x270, ~260 KB, about 23 s at 115200).

static void fb_snapshot(uint32_t base, uint32_t step)
{
    uint32_t x, y;
    uint32_t w = FB_W / step, h = FB_H / step;
    bsp_printf("\r\nSHOT %d %d %d\r\n", (int)w, (int)h, (int)step);
    for (y = 0; y < FB_H; y += step) {
        const volatile uint16_t *p = (const volatile uint16_t *)(base + y * FB_STRIDE);
        for (x = 0; x < FB_W; x += step) {
            uint16_t v = p[x];
            uart_write(BSP_UART_TERMINAL, (char)(v & 0xFFu));
            uart_write(BSP_UART_TERMINAL, (char)((v >> 8) & 0xFFu));
        }
    }
    bsp_printf("\r\nSHOT-END\r\n");
}

void main(void)
{
    uint32_t t0, t1, id;

    bsp_init();
    bsp_printf("\r\n=== GFX v2 engine ===\r\n");
    bsp_printf("firmware build V%d\r\n", (int)FW_VERSION);

    id = gfx_rd(G_ID);
    bsp_printf("id=%x status=%x\r\n", id, gfx_rd(G_STATUS));
    if (id != GFX_ID_VALUE) {
        bsp_printf("engine not responding, halt\r\n");
        while (1) { }
    }
    check("id", id == GFX_ID_VALUE);

    // ---------------------------------------------------------------- 1. fill
    gfx_fill(FB_A, 64u, 64u, FB_STRIDE, 0xF800u);
    if (gfx_wait_idle() < 0) { bsp_printf("fill timeout dbg=%x st=%x\r\n", gfx_rd(G_DBG), gfx_rd(G_STATUS)); g_fail++; }
    check("fill", rd_px(FB_A) == 0xF800u &&
                  rd_px(FB_A + 63u * 2u) == 0xF800u &&
                  rd_px(FB_A + 63u * FB_STRIDE) == 0xF800u);

    // ---------------------------------------------------------------- 2. copy
    gfx_fill(FB_A + 0x40000u, 32u, 32u, FB_STRIDE, 0x07E0u);
    gfx_wait_idle();
    bsp_printf("f2: done=%d st=%x dst=%x size=%x ds=%x\r\n",
               (int)gfx_rd(G_DONE), (int)gfx_rd(G_STATUS),
               (int)gfx_rd(G_DST), (int)gfx_rd(G_SIZE), (int)gfx_rd(G_DS));
    gfx_fill(FB_A + 0x70000u, 32u, 32u, FB_STRIDE, 0x0F0Fu);
    gfx_wait_idle();
    bsp_printf("f2 view: fbA0=%x f4=%x f7=%x f7b=%x\r\n",
               rd_px(FB_A), rd_px(FB_A + 0x40000u),
               rd_px(FB_A + 0x70000u), rd_px(FB_A + 0x70000u + 31u * FB_STRIDE));
    gfx_copy(FB_A + 0x40000u, FB_A + 0x50004u, 32u, 32u, FB_STRIDE, FB_STRIDE);
    gfx_wait_idle();
    bsp_printf("copy: src0=%x src31=%x dst0=%x dst2=%x dstlast=%x\r\n",
               rd_px(FB_A + 0x40000u), rd_px(FB_A + 0x40000u + 31u * 2u),
               rd_px(FB_A + 0x50004u), rd_px(FB_A + 0x50006u),
               rd_px(FB_A + 0x50004u + 31u * FB_STRIDE));
    check("copy", rd_px(FB_A + 0x50004u) == 0x07E0u &&
                  rd_px(FB_A + 0x50004u + 31u * 2u) == 0x07E0u &&
                  rd_px(FB_A + 0x50004u + 31u * FB_STRIDE) == 0x07E0u);

    // -------------------------------------------------------------- 3. blend
    // red 0xF800 over green 0x07E0 at alpha 128 -> 0x83E0 (see tb_gfx_engine)
    gfx_fill(FB_A + 0x20000u, 16u, 16u, FB_STRIDE, 0x07E0u);
    gfx_fill(FB_A + 0x30000u, 16u, 16u, FB_STRIDE, 0xF800u);
    gfx_wait_idle();
    gfx_blit(FB_A + 0x30000u, FB_A + 0x20000u, 16u, 16u, FB_STRIDE, FB_STRIDE, 128u, 0xFFFFu);
    gfx_wait_idle();
    bsp_printf("blend: got=%x\r\n", rd_px(FB_A + 0x20000u));
    check("blend", rd_px(FB_A + 0x20000u) == 0x83E0u &&
                   rd_px(FB_A + 0x20000u + 15u * 2u) == 0x83E0u);

    // ---------------------------------------------------------------- 4. key
    {
        volatile uint16_t *s = (volatile uint16_t *)(FB_A + 0x40000u);
        for (uint32_t i = 0; i < 8u; i++)
            s[i] = (i < 4u) ? SPR_KEY : 0x001Fu;
        __asm__ volatile ("fence rw,rw" ::: "memory");
        bsp_printf("key src: %x %x %x %x\r\n", s[0], s[1], s[3], s[4]);
        gfx_fill(FB_A + 0x48000u, 8u, 1u, FB_STRIDE, 0x07E0u);
        gfx_wait_idle();
        gfx_copy_key(FB_A + 0x40000u, FB_A + 0x48000u, 8u, 1u, 16u, FB_STRIDE, SPR_KEY);
        gfx_wait_idle();
        bsp_printf("key dst: %x %x %x\r\n",
                   rd_px(FB_A + 0x48000u), rd_px(FB_A + 0x48002u),
                   rd_px(FB_A + 0x48008u));
        check("key", rd_px(FB_A + 0x48000u) == 0x07E0u &&
                     rd_px(FB_A + 0x48000u + 8u) == 0x001Fu);
    }

    // ---------------------------------------------------------------- 5. oob
    gfx_fill(0x07000000u, 16u, 16u, 64u, 0x1234u);
    gfx_wait_idle();
    check("oob-refused", (gfx_rd(G_STATUS) & ST_CLIPPED) != 0u);

    // ------------------------------------------------------- display + sprite
    make_sprites();
    game_assets_upload();
    gfx_fb(FB_A, FB_STRIDE, FB_W, FB_H);
    {
        // The first frames after enable run with empty line banks; that is
        // expected, so the health baseline is taken once the pipeline is full.
        uint32_t tw = cyc();
        while ((cyc() - tw) < 10000000u) { }
        g_ubase = gfx_rd(G_UNDER);
        g_abase = gfx_rd(G_AXIERR);
    }
    bsp_printf("display on\r\n");

    // ---------------------------------------------------- software fill timing
    {
        volatile uint16_t *p = (volatile uint16_t *)FB_B;
        t0 = cyc();
        for (uint32_t y = 0; y < FB_H; y++) {
            uint32_t o = y * (FB_STRIDE / 2u);
            for (uint32_t x = 0; x < FB_W; x++) p[o + x] = 0x1084u;
        }
        t1 = cyc();
        bsp_printf("sw fill: %d cycles\r\n", (int)(t1 - t0));
    }

    // ------------------------------------------------------ hardware fill timing
    {
        uint32_t d0, d1;
        d0 = gfx_rd(G_DONE);
        t0 = cyc();
        gfx_fill(FB_B, FB_W, FB_H, FB_STRIDE, 0x1084u);
        if (gfx_wait_n(d0, 1u) < 0) { bsp_printf("hw fill timeout dbg=%x st=%x\r\n", gfx_rd(G_DBG), gfx_rd(G_STATUS)); g_fail++; }
        t1 = cyc();
        d1 = gfx_rd(G_DONE);
        bsp_printf("hw fill: %d cycles (%d done)\r\n", (int)(t1 - t0), (int)(d1 - d0));
    }

    // Control experiment: let the display run for one second with the engine
    // completely idle. Any underrun here is the scan path itself; underruns that
    // only appear while drawing are bus contention from the engine.
    {
        uint32_t ua, ub, fa, fb, t0;
        ua = gfx_rd(G_UNDER); fa = gfx_rd(G_FRAMES);
        t0 = cyc();
        while ((cyc() - t0) < 100000000u) { }
        ub = gfx_rd(G_UNDER); fb = gfx_rd(G_FRAMES);
        {
            uint32_t r10 = (fb != fa) ? (((ub - ua) * 10u) / (fb - fa)) : 0u;
            bsp_printf("idle scan: under+%d frames+%d rows/frame=%d.%d first=%d dbg2=%08x\r\n",
                       (int)(ub - ua), (int)(fb - fa),
                       (int)(r10 / 10u), (int)(r10 % 10u),
                       (int)gfx_rd(G_FUROW), (unsigned)gfx_rd(G_DBG2));
        }
        bsp_printf("pf: cnt=%d stall=%d\r\n",
                   (int)(gfx_rd(G_DBG3) >> 16), (int)(gfx_rd(G_DBG3) & 0xFFFFu));
        {
            /* Diagnostic: total cycles spent inside line reads of the last
             * frame. avg = sum/1080; the scan-out keeps up at 60 fps only if
             * a line takes < 754 cycles (7.54 us). */
            uint32_t rc = gfx_rd(G_DBG4);
            bsp_printf("scan rdcyc=%d avg=%d (keep-up needs <754)\r\n",
                       (int)rc, (int)(rc / 1080u));
        }
    }

    // ------------------------------------------------------------- live demo
    //
    // Four scenes, two renderers, driven by the PC keyboard over UART:
    //   up / down    next / previous scene
    //   left / right CPU renderer / engine
    // The HUD names the scene and the renderer and shows the measured frame rate,
    // so the panel itself answers the competition's "compare software against
    // hardware" requirement without a serial capture.
    {
        uint32_t front = FB_A, back = FB_B, seq = 0u;
        uint32_t scene = SC_SPRITE;     // demo scenes are the main entry
        uint32_t mode  = 1u;            // 1 = engine, 0 = CPU
        uint32_t fps10 = 0u;
        uint32_t fps_avg = 0u;      // display fps, x10 (scan-out based)
        uint32_t hw_fps  = 0u;      // last hardware-render fps, x10
        uint32_t sw_fps  = 0u;      // last software-render fps, x10
        uint32_t sh_frames0 = 0u;   // scan-out frame counter at last sample
        uint32_t sh_t0 = 0u;        // cycle timestamp of last sample
        uint32_t frame_no = 0u;
        uint32_t prev_t = cyc();
        uint32_t key_on = 1u;          // colour key enabled
        uint32_t t_log = cyc();
        uint32_t render_us = 0u;
        uint32_t g_full_clear = 2u;
        uint8_t  g_hud_static[2] = { 0u, 0u };   // per buffer
        uint32_t g_mode_prev = 0xFFFFFFFFu;
        uint32_t gal_idx = 0u, gal_last = 0u, gal_cyc = 0u;
        uint32_t gal_pending = 0u;
        uint32_t g_hud_hold = 0u;   // frames to suppress the HUD after a wipe

        // Measure DDR-write speed: the sprite-table approach needs CPU stores
        // into DDR to be far cheaper than AXI register writes.
        {
            uint32_t ti, t0, dt;
            volatile uint32_t *tp = (volatile uint32_t *)0x0B900000u;  // free DDR window
            t0 = cyc();
            for (ti = 0; ti < 1400u; ti++) tp[ti] = ti;
            dt = cyc() - t0;
            bsp_printf("DDW 1400 words = %d cycles = %d us\r\n", (int)dt, (int)(dt / 100u));
        }
        gallery_build();
        brown_init();
        bg_build_art();      //精细背景位图 -> DDR (一次性)
        gfx_fb(front, FB_STRIDE, FB_W, FB_H);
        { uint32_t tw = cyc(); while ((cyc() - tw) < 10000000u) { } }

        bsp_printf("=== DEMO: up/down scene, left/right engine/CPU, K key, G game ===\r\n");
    {
        uint32_t t0, t1, k;
        t0 = (uint32_t)cyc();
        for (k = 0; k < 1000u; k++) gfx_wr(0x08u, k);   /* read-only reg: no side effect */
        t1 = (uint32_t)cyc();
        bsp_printf("AXI wr x1000 = %d cycles\r\n", (int)(t1 - t0));
        t0 = (uint32_t)cyc();
        for (k = 0; k < 1000u; k++) (void)gfx_rd(0x08u);
        t1 = (uint32_t)cyc();
        bsp_printf("AXI rd x1000 = %d cycles\r\n", (int)(t1 - t0));
    }

        for (;;) {
            uint32_t t0 = cyc();
            uint32_t i;
            uint16_t keycol;
            int k = input_poll();
            if (g_skip_k) { g_skip_k--; k = -1; }

            // Frame rate is the FULL period, not the draw time. Measuring it
            // before the vsync wait reported the draw cost alone (68 fps) and
            // hid the fact that presentation was already locked to 60 Hz.
            {
                uint32_t dt = t0 - prev_t;
                if (dt) fps10 = 1000000000u / dt;
                // smoothing: a single frame's jitter should not make the HUD
                // flicker between 59.9 and 60.0
                if (fps_avg == 0u) fps_avg = fps10;
                else               fps_avg = (fps_avg * 31u + fps10) / 32u;
            }
            prev_t = t0;

            // Remember the frame rate of whichever renderer is active, so both
            // numbers can be displayed together: that is the side-by-side
            // comparison the competition asks for.
            if (mode) {
                // 3-frame smoothing (was a 32-frame average that hid stutters);
                // both the game HUD and the demo HUD read this value
                g_fps3 = (g_fps3 == 0u) ? fps10 : (g_fps3 * 2u + fps10) / 3u;
                hw_fps = g_fps3;
            } else {
                if (fps10) sw_fps = (sw_fps == 0u) ? fps10 : (sw_fps * 3u + fps10) / 4u;
            }

            // display fps: count how many frames the scan-out actually showed
            {
                uint32_t now = t0;
                uint32_t fr  = gfx_rd(G_FRAMES);
                if (sh_t0 == 0u) { sh_t0 = now; sh_frames0 = fr; }
                else {
                    uint32_t dtc = now - sh_t0;
                    if (dtc >= 50000000u) {          // every 0.5 s
                        uint32_t df = fr - sh_frames0;
                        uint32_t f  = (dtc != 0u) ? (uint32_t)(((uint64_t)df * 1000000000u) / dtc) : 0u;
                        if (f > 0u && f < 2000u) {
                            fps_avg = (fps_avg == 0u) ? f : (fps_avg * 7u + f) / 8u;
                        }
                        sh_t0 = now;
                        sh_frames0 = fr;
                    }
                }
            }

            if (scene == SC_GAME) {
                // The game owns its own state machine (title/play/pause/upgrade/
                // over) and reads g_in directly; Q / ESC still leaves for the
                // demo so the scene switch stays uniform.
                if (k == 6) {
                    // Q / ESC leaves the game for the 1408-sprite test scene and
                    // rebuilds it. Returning to the FILL scene left a dark blue
                    // screen that looked like a black hang.
                    scene = SC_SPRITE;
                    g_scene_prev = scene;
                    g_in.exit = 0u;
                    brown_init();
                    g_old_n[0] = 0u; g_old_n[1] = 0u;
                    g_hud_static[0] = 0u; g_hud_static[1] = 0u;
                    g_full_clear = 2u;
                    g_skip_k = 2u;
                }
            } else {
                // The v3 pad's start button also enters the game, so the PC
                // keyboard bridge alone can drive everything. The arrow keys
                // arrive as direction bits in g_in, not as characters, so they
                // are edge-detected here as well (UP/DOWN scene, LEFT/RIGHT
                // engine-CPU) -- without this the arrow keys did nothing on the
                // demo screens.
                static uint32_t demo_dir_prev;
                uint32_t dd = g_in.dir;
                uint32_t du = (dd & 1u) && !(demo_dir_prev & 1u);
                uint32_t ddn = (dd & 4u) && !(demo_dir_prev & 4u);
                uint32_t dl = (dd & 8u) && !(demo_dir_prev & 8u);
                uint32_t dr = (dd & 2u) && !(demo_dir_prev & 2u);
                demo_dir_prev = dd;
                if (g_in.pause) {   /* pause key: alpha toggle outside the game, */
                    if (scene == SC_GAME) {
                        /* one-key max-level stress, same as the B key path */
                        g_stress_on = g_stress_on ? 0u : 1u;
                        if (g_stress_on) {
                            g_level = 99u; g_kn_int = 6u; g_kn_dmg = 20u;
                            g_kn_n = 5u;   g_fire_lv = 5u;
                        }
                    } else {
                        g_trans_on ^= 1u;
                    }
                }
                if (g_in.start) { scene = SC_GAME; game_enter(); }
                else if (k == 0 || du) { scene = (scene + 1u) % 4u; }        // FILL/COPY/SPRITE only
                else if (k == 2 || ddn) { scene = (scene + 4u - 1u) % 4u; }
                else if (k == 1 || dr) mode = 1u;
                else if (k == 3 || dl) mode = 0u;
                else if (k == 4) {
                    key_on ^= 1u;
                    g_hud_static[0] = 0u; g_hud_static[1] = 0u;
                }
                else if (k == 5) { scene = SC_GAME; game_enter(); }
                else if (k == 9) { g_trans_on ^= 1u; }   /* F: translucent <-> opaque */
            }

            keycol = key_on ? SPR_KEY : 0xFFFFu;

            // physics advances every frame regardless of who draws it
            if (scene == SC_SPRITE) {
                brown_step((frame_no & 1u) == 0u);
            }

            if (mode || scene == SC_GAME) {
                uint32_t d0 = gfx_rd(G_DONE);
                uint32_t ncmd = 0u;
                uint32_t bi = (back == FB_A) ? 0u : 1u;

                if (mode != g_mode_prev) {
                    g_mode_prev = mode;
                    g_old_n[0] = 0u; g_old_n[1] = 0u;
                    g_full_clear = 2u;
                }
                if (scene != g_scene_prev) {
                    if (scene == SC_BLOCK) { }
                    // both buffers still hold the previous scene
                    g_old_n[0] = 0u; g_old_n[1] = 0u;
                    g_hud_static[0] = 0u; g_hud_static[1] = 0u;
                    g_scene_prev = scene;
                    g_full_clear = 2u;
                }

                if (g_full_clear && scene != SC_GAME) {
                    g_full_clear--;
                    // The wipe is an asynchronous engine fill that executes one
                    // frame later, so suppress the HUD for two frames and only
                    // then force the cached text to repaint.
                    g_hud_hold = 2u;
                    g_hud_static[0] = 1u; g_hud_static[1] = 1u;
                    for (i = 0; i < 4u; i++) {
                        gfx_fill(back + i * (FB_H / 4u) * FB_STRIDE,
                                 FB_W, FB_H / 4u, FB_STRIDE, 0x1082u);
                        ncmd++;
                    }
                }
                uint32_t t_cpu0_all = cyc();
                switch (scene) {
                case SC_FILL:
                    // Static picture: fill every other frame. Both buffers end up
                    // holding the same colour and the displayed content does not
                    // change, but the DDR write traffic halves -- the write and the
                    // scan-out read were adding up to exactly one frame's worth.
                    if ((frame_no & 1u) == 0u) {
                        for (i = 0; i < 4u; i++) {
                            gfx_fill(back + i * (FB_H / 4u) * FB_STRIDE,
                                     FB_W, FB_H / 4u, FB_STRIDE, g_scene_col[scene]);
                            ncmd++;
                        }
                    }
                    break;
                case SC_COPY:
                    // IMAGES: one full-screen COPY swaps the picture; that is the
                    // "fast switching between large images" case.
                    if ((frame_no - gal_last) >= 240u) {
                        gal_idx = (gal_idx + 1u) % GAL_N;
                        gal_cyc = gallery_show(back, gal_idx);
                        gal_last = frame_no;
                        gal_pending = 1u;          // the other buffer still needs it
                        ncmd = 1u;
                    } else if (gal_pending) {
                        // second half of the switch: after the flip this buffer is
                        // the one that still holds the old picture
                        gallery_show(back, gal_idx);
                        g_hud_static[0] = 0u; g_hud_static[1] = 0u;
                        gal_pending = 0u;
                        ncmd = 1u;
                    }
                    break;
                case SC_SPRITE:
#if USE_SPR_TABLE
                {
                    // Fill the 16-byte table entries once per frame and let the
                    // walker queue erase+draw for all sprites. Only the table
                    // words cross the bus: 4 stores per sprite instead of the
                    // 20 AXI register writes the per-sprite path needs.
                    volatile uint32_t *tab = (volatile uint32_t *)SPRTAB_BASE;
                    for (i = 0; i < BR_N; i++) {
                        int16_t px = (int16_t)(g_bx[i] / BR_Q);
                        int16_t py = (int16_t)(g_by[i] / BR_Q);
                        uint32_t e = i * 4u;
                        tab[e + 0u] = (uint32_t)(uint16_t)g_old_x[bi][i]
                                    | ((uint32_t)(uint16_t)g_old_y[bi][i] << 16);
                        tab[e + 1u] = (uint32_t)(uint16_t)px
                                    | ((uint32_t)(uint16_t)py << 16);
                        tab[e + 2u] = SPR_BASE;
                        tab[e + 3u] = 0u;
                        g_old_x[bi][i] = px;
                        g_old_y[bi][i] = py;
                    }
                    g_old_n[bi] = BR_N;
                    gfx_wr(G_SPRTAB, SPRTAB_BASE);
                    gfx_wr(G_SPRCTL, 0u);                               // clear START
                    gfx_wr(G_SPRCTL, (uint32_t)BR_N | (1u << 16));      // rising edge
                    // DIAGNOSTIC: optionally skip the drain wait to measure the
                    // steady-state pipeline instead of the walker drain time.
                    if (g_spr_wait) ncmd = (uint32_t)BR_N * 2u;
                    else             ncmd = 0u;
                }
#else
                {
                    uint32_t tr = (uint32_t)cyc();
                    // Erase: first fill programs size/stride/colour, the rest only
                    // rewrite dst (the engine keeps its parameter registers).
                    for (i = 0; i < g_old_n[bi]; i++) {
                        uint32_t dst = back + (uint32_t)g_old_y[bi][i] * FB_STRIDE
                                            + (uint32_t)g_old_x[bi][i] * 2u;
                        if (i == 0u) gfx_fill(dst, SPR_W, SPR_H, FB_STRIDE, 0x1082u);
                        else        gfx_fill_fast(dst);
                        ncmd++;
                    }
                    // Draw: same trick, first blit programs size/stride/key.
                    for (i = 0; i < BR_N; i++) {
                        int16_t px = (int16_t)(g_bx[i] / BR_Q);
                        int16_t py = (int16_t)(g_by[i] / BR_Q);
                        {
                            uint32_t pat   = i & 7u;
                            uint32_t trans = ((i & 2u) == 0u) ? 1u : 0u;
                            uint32_t spr = SPR_BASE + pat * SPR_BYTES;
                            uint32_t dst = back + (uint32_t)py * FB_STRIDE
                                                + (uint32_t)px * 2u;
                            if (trans) {
                                /* translucent showcase: engine BLIT with alpha */
                                gfx_blit(spr, dst, SPR_W, SPR_H,
                                         SPR_STRIDE, FB_STRIDE,
                                         g_trans_on ? 64u : 255u, keycol);
                            } else if (i == 0u) {
                                gfx_copy_key(spr, dst, SPR_W, SPR_H,
                                             SPR_STRIDE, FB_STRIDE, keycol);
                            } else {
                                gfx_copy_key_fast(spr, dst);
                            }
                        }
                        g_old_x[bi][i] = px;
                        g_old_y[bi][i] = py;
                        ncmd++;
                    }
                    g_old_n[bi] = BR_N;
                    g_prof_rend = (uint32_t)cyc() - tr;
                }
#endif
                    break;
                case SC_BLOCK:
                    /* Block Copy demo: flat background, then eight 240x240 blocks
                       cut out of the IMAGES picture and pasted into an orderly
                       2x4 grid. Shows arbitrary-size block movement clearly. */
                    gfx_fill(back, FB_W, FB_H, FB_STRIDE, 0x1082u);
                    ncmd++;
                    {
                        uint32_t bi2, bn2 = 0u;
                        uint32_t src2 = GAL_BASE + (gal_idx % GAL_N) * FB_STRIDE * FB_H;
                        uint32_t d02 = gfx_rd(G_DONE);
                        for (bi2 = 0; bi2 < 8u; bi2++) {
                            uint32_t col2 = bi2 % 4u;
                            uint32_t row2 = bi2 / 4u;
                            uint32_t sx2 = col2 * 480u;
                            uint32_t sy2 = row2 * 540u;
                            uint32_t dx2 = col2 * 480u + 60u;
                            uint32_t dy2 = row2 * 480u + 120u;
                            gfx_copy(src2 + sy2 * FB_STRIDE + sx2 * 2u,
                                     back + dy2 * FB_STRIDE + dx2 * 2u,
                                     240u, 240u, FB_STRIDE, FB_STRIDE);
                            bn2++;
                        }
                        gfx_wait_n(d02, bn2);
                        ncmd += bn2;
                    }
                    break;
                case 99u:
                    {
                        uint32_t bn = 0u;
                        for (i = 0; i < BL_N; i++) {
                            int16_t px, py;
                            if (!g_uact[i]) continue;
                            px = (int16_t)(g_ux[i] / BR_Q);
                            py = (int16_t)(g_uy[i] / BR_Q);
                            blit_disc(back, SPR_BASE, (uint32_t)px, (uint32_t)py, keycol, key_on, 128u);
                            g_old_x[bi][bn] = px;
                            g_old_y[bi][bn] = py;
                            bn++;
                            ncmd++;
                        }
                        g_old_n[bi] = bn;
                    }
                    break;
                default: {      // SC_GAME
                    int32_t rc = game_frame(back, bi, &g_in, fps_avg, sw_fps);
                    if (rc < 0) {
                        // Back to the 1408-sprite test scene, fully rebuilt: the
                        // sprites must be re-seeded and the scene forced, or the
                        // board ends up on whatever scene happened to be left
                        // over (a fill colour looked like a black screen).
                        scene = SC_SPRITE;
                        g_scene_prev = scene;
                        brown_init();
                        g_old_n[0] = 0u; g_old_n[1] = 0u;
                        g_hud_static[0] = 0u; g_hud_static[1] = 0u;
                        g_full_clear = 2u;
                        ncmd = 0u;
                        g_skip_k = 2u;
                    } else {
                        ncmd = (uint32_t)rc;
                    }
                    break;
                }
                }
                g_prof_cpu = cyc() - t_cpu0_all;
                {
                    uint32_t tw0 = cyc();
                    gfx_wait_n(d0, ncmd);
                    g_prof_gpu = cyc() - tw0;
                    {
                        static uint32_t prof_div;
                        if ((++prof_div % 20u) == 0u) {
                            // scan-out liveness: frames must keep incrementing if the
                            // display pipeline is actually running
                            bsp_printf("SCAN frames=");
                            bsp_printf_d((int)gfx_rd(0x70u));
                            bsp_printf(" under=");
                            bsp_printf_d((int)gfx_rd(0x64u));
                            bsp_printf(" shown=");
                            bsp_printf_d((int)gfx_rd(0x68u));
                            bsp_printf(" status=");
                            bsp_printf_d((int)gfx_rd(0x60u));
                            bsp_printf("PROF cpu=");
                            bsp_printf_d((int)(g_prof_cpu / 100u));
                            bsp_printf(" phys=");
                            bsp_printf_d((int)(g_prof_phys / 100u));
                            bsp_printf(" rend=");
                            bsp_printf_d((int)(g_prof_rend / 100u));
                            bsp_printf(" gpu=");
                            bsp_printf_d((int)(g_prof_gpu / 100u));
                            bsp_printf(" rdw=");
                            bsp_printf_d((int)gfx_rd(0x88u));   // engine read-stall cycles, last command
                            bsp_printf("\r\n");
                        }
                    }
                }
            } else {
                uint32_t bi = (back == FB_A) ? 0u : 1u;
                // CPU renderer doing exactly the engine's work: erase the
                // previous positions, draw with alpha, remember the new ones.
                // (No full-screen clear -- the engine does not get one either,
                // so this is the fair comparison.)
                if (scene == SC_FILL) {
                    sw_rect(back, 0u, 0u, FB_W, FB_H, g_scene_col[SC_FILL]);
                } else if (scene == SC_SPRITE) {
                    for (i = 0; i < g_old_n[bi]; i++)
                        sw_rect(back, (uint32_t)g_old_x[bi][i], (uint32_t)g_old_y[bi][i],
                                SPR_W, SPR_H, 0x1082u);
                    for (i = 0; i < BR_N; i++) {
                        uint32_t px  = (uint32_t)(g_bx[i] / BR_Q);
                        uint32_t py  = (uint32_t)(g_by[i] / BR_Q);
                        uint32_t pat   = i & 7u;   /* same rotation as the engine */
                        uint32_t trans = ((i & 2u) == 0u) ? 1u : 0u;
                        sw_disc(back, SPR_BASE + pat * SPR_BYTES, px, py,
                                (trans && g_trans_on) ? 64u : 255u);
                        g_old_x[bi][i] = (int16_t)px; g_old_y[bi][i] = (int16_t)py;
                    }
                    g_old_n[bi] = BR_N;
                } else if (scene == SC_BLOCK) {
                    for (i = 0; i < BL_N; i++)
                        if (g_uact[i])
                            sw_disc(back, SPR_BASE,
                                    (uint32_t)(g_ux[i] / BR_Q), (uint32_t)(g_uy[i] / BR_Q), 255u);
                } else if (scene == SC_COPY) {
                    // IMAGES on the CPU: copy every fourth scanline of the same
                    // picture. A full pixel-exact copy is two seconds per frame,
                    // which just looks frozen; this is about half a second, still
                    // an order of magnitude behind the engine.
                    volatile uint16_t *dp = (volatile uint16_t *)back;
                    volatile uint16_t *sp =
                        (volatile uint16_t *)(GAL_BASE + gal_idx * FB_STRIDE * FB_H);
                    uint32_t row_px = FB_STRIDE / 2u;
                    uint32_t y;
                    for (y = 0; y < FB_H; y += 4u) {
                        uint32_t yy;
                        for (yy = 0; yy < 4u && (y + yy) < FB_H; yy++) {
                            uint32_t o = (y + yy) * row_px;
                            uint32_t j;
                            for (j = 0; j < FB_W; j++) dp[o + j] = sp[o + j];
                        }
                    }
                }
            }

            if (g_hud_hold) {
                if (--g_hud_hold == 0u) { g_hud_static[0] = 0u; g_hud_static[1] = 0u; }
            } else if (scene == SC_GAME) {
                // HUD must be drawn EVERY frame: game_render clears the HUD
                // strip every frame, so skipping a frame wiped the text and made
                // the HUD flash. The 3 ms cost has to be removed a different way.
                { uint32_t th = cyc(); game_hud(back, g_fps3, sw_fps, (back == FB_A) ? 0u : 1u); g_prof_hud = cyc() - th; }
                { uint32_t to = cyc(); game_overlay(back); g_prof_ovl = cyc() - to; }
            } else
            {
                char line[80];
                int n = 0;
                const char *q;
                volatile uint16_t *vp = (volatile uint16_t *)back;
                uint32_t px_count;
                uint32_t bi_hud = (back == FB_A) ? 0u : 1u;
                if (scene == SC_SPRITE)      px_count = BR_N;
                else if (scene == SC_BLOCK) px_count = 8u;
                else if (scene == SC_COPY)   px_count = 64u;
                else                         px_count = 1u;

                // ---- line 1 + line 3: static text, redrawn once per buffer ----
                // (or when the scene/mode/key state changes, which clears the
                // flags). Wiping 1180x36 pixels every frame cost 4-6 ms of CPU
                // time and pushed the frame over the vsync budget.
                {
                    for (q = "1920X1080  "; *q; q++) line[n++] = *q;
                    for (q = g_scene_name[scene]; *q; q++) line[n++] = *q;
                    for (q = mode ? "  HW" : "  SW"; *q; q++) line[n++] = *q;
                    for (q = key_on ? "  KEY ON" : "  KEY OFF"; *q; q++) line[n++] = *q;
                    line[n] = 0;
                    // Engine fill, then WAIT before the CPU draws the glyphs:
                    // an unwritten fill would land later and clip them, while
                    // clearing with CPU stores was far too slow (120k writes).
                    {
                        uint32_t dw0 = gfx_rd(G_DONE);
                        gfx_fill(back + 4u * FB_STRIDE, 260u, 36u, FB_STRIDE, 0x10A2u);
                        while ((gfx_rd(G_DONE) - dw0) < 1u) { }
                    }
                    hud_text(vp, FB_STRIDE / 2u, 16u, 8u, line, 0xFFFFu, 0x10A2u);
                    hud_text(vp, FB_STRIDE / 2u, 16u, 72u,
                             "UP/DOWN SCENE  LEFT/RIGHT ENGINE/CPU  K KEY",
                             0x8410u, 0x10A2u);
                }

                // ---- dynamic line: element count and frame rate ----
                n = 0;
                for (q = "ELEM "; *q; q++) line[n++] = *q;
                { char nb[12]; uint32_t j = 0u;
                  hud_num(nb, px_count, 0u);
                  while (nb[j]) line[n++] = nb[j++]; }
                for (q = "   HW "; *q; q++) line[n++] = *q;
                { char nb[12]; uint32_t j = 0u;
                  hud_num(nb, hw_fps, 1u);
                  while (nb[j]) line[n++] = nb[j++]; }
                for (q = "  SW "; *q; q++) line[n++] = *q;
                { char nb[12]; uint32_t j = 0u;
                  hud_num(nb, sw_fps, 1u);
                  while (nb[j]) line[n++] = nb[j++]; }
                for (q = g_trans_on ? "  A64" : "  A255"; *q; q++) line[n++] = *q;
                line[n] = 0;
                hud_text(vp, FB_STRIDE / 2u, 16u, 40u, line,
                         mode ? 0x07E0u : 0xFD20u, 0x10A2u);
            }

            if ((cyc() - t_log) >= 100000000u) {
                char lb[48];
                int ln = 0;
                const char *lq;
                t_log = cyc();
                for (lq = "PERF "; *lq; lq++) lb[ln++] = *lq;
                for (lq = g_scene_name[scene]; *lq; lq++) lb[ln++] = *lq;
                for (lq = mode ? " HW fps " : " SW fps "; *lq; lq++) lb[ln++] = *lq;
                { char nb[12]; uint32_t j = 0u;
                  hud_num(nb, fps_avg, 1u);
                  while (nb[j]) lb[ln++] = nb[j++]; }
                for (lq = " rx500="; *lq; lq++) lb[ln++] = *lq;
                { char nb[12]; uint32_t j = 0u;
                  hud_num(nb, render_us / 500u, 0u);
                  while (nb[j]) lb[ln++] = nb[j++]; }
                lb[ln] = 0;
                bsp_printf("%s\r\n", lb);
            }

            { uint32_t dt = cyc() - t0; if (dt) render_us = dt; }

            if (g_shot_req) {
                g_shot_req = 0u;
                fb_snapshot(back, SHOT_STEP);   // back is the fully drawn frame
            }

            seq++;
            { uint32_t fw0 = cyc();
              gfx_flip(back, seq);
              { uint32_t spin = 0u;
                while (gfx_rd(G_FBACCEPT) != seq && spin < 400000000u) spin++; }
              g_prof_flip = cyc() - fw0; }
            { uint32_t tmp = front; front = back; back = tmp; }
            frame_no++;
        }
    }

    bsp_printf("failures: %d\r\n", (int)g_fail);
    bsp_printf("=== demo complete ===\r\n");
    while (1) { }
}

// Exceptions land here. Report once over UART and stop: continuing after an
// exception in a bare-metal application only produces a second, less useful
// fault, and the first one is the evidence.
void trap(void)
{
    uint32_t mcause, mepc;
    asm volatile ("csrr %0, mcause" : "=r"(mcause));
    asm volatile ("csrr %0, mepc"   : "=r"(mepc));
    bsp_printf("\r\n*** TRAP mcause=%x mepc=%x ***\r\n", mcause, mepc);
    while (1) { }
}

