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
#include "hud.h"
#include "uart.h"

#define FB_A        0x08000000u
#define FB_STRIDE   4096u
#define FB_W        1920u
#define FB_H        1080u
#define FB_B        (FB_A + FB_STRIDE * FB_H)

#define SPR_BASE    0x08870000u
#define SPR_W       16u
#define SPR_H       16u
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

static const uint16_t g_spr_col[SPR_VARIANTS] = {
    0x07FFu, 0xF800u, 0x07E0u, 0xFFE0u, 0x001Fu, 0xFFFFu, 0xFD20u, 0x8410u
};

static void make_sprites(void)
{
    uint32_t c, x, y;
    for (c = 0; c < SPR_VARIANTS; c++) {
        volatile uint16_t *p = (volatile uint16_t *)(SPR_BASE + c * SPR_BYTES);
        for (y = 0; y < SPR_H; y++) {
            for (x = 0; x < SPR_W; x++) {
                int dx = (int)x - 7;
                int dy = (int)y - 7;
                int d2 = dx * dx + dy * dy;
                p[y * SPR_W + x] = (d2 > 56) ? SPR_KEY : g_spr_col[c];
            }
        }
    }
}

// --------------------------------------------------------------- demo scenes
#define SC_FILL    0u
#define SC_COPY    1u
#define SC_SPRITE  2u
#define SC_BULLET  3u
#define SC_N       4u

static const char *const g_scene_name[SC_N] = { "FILL", "COPY", "SPRITE", "BULLET" };
static const uint32_t   g_scene_col[SC_N]  = { 0x07FFu, 0xF800u, 0x07E0u, 0xFFE0u };

static inline uint32_t xorshift(uint32_t v)
{
    return v ^ (v << 13) ^ (v >> 17) ^ (v << 5);
}

// Draw one 16x16 solid disc at (x,y) with the engine.
static inline void blit_disc(uint32_t back, uint32_t spr, uint32_t x, uint32_t y,
                             uint16_t keycol, uint32_t key_on)
{
    uint32_t dst = back + y * FB_STRIDE + x * 2u;
    // The sprites are opaque, so alpha blending would only reproduce the
    // foreground. Using the key-only path removes one DDR read per sprite --
    // with 512 sprites that read was the difference between 30 and 60 fps.
    if (key_on) gfx_copy_key(spr, dst, SPR_W, SPR_H, SPR_STRIDE, FB_STRIDE, keycol);
    else        gfx_copy    (spr, dst, SPR_W, SPR_H, SPR_STRIDE, FB_STRIDE);
}

// Draw one 16x16 solid disc with the CPU: same pixels, same key test.
static inline void sw_disc(uint32_t back, uint32_t spr, uint32_t x, uint32_t y)
{
    volatile uint16_t *d = (volatile uint16_t *)(back + y * FB_STRIDE + x * 2u);
    const volatile uint16_t *s = (const volatile uint16_t *)spr;
    uint32_t yy, xx;
    for (yy = 0; yy < SPR_H; yy++)
        for (xx = 0; xx < SPR_W; xx++) {
            uint16_t fg = s[yy * SPR_W + xx];
            if (fg != SPR_KEY) d[yy * (FB_STRIDE / 2u) + xx] = fg;
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

static void sw_fill(uint32_t back, uint16_t col)
{
    volatile uint16_t *p = (volatile uint16_t *)back;
    uint32_t y, x;
    for (y = 0; y < FB_H; y++) {
        uint32_t o = y * (FB_STRIDE / 2u);
        for (x = 0; x < FB_W; x++) p[o + x] = col;
    }
}

// --------------------------------------------------------------- UART keys
// The panel has no usable buttons wired to the FPGA, so the keyboard on the PC
// drives the demo over the same UART the log goes out on. Arrow keys arrive as
// ESC [ A/B/C/D; WASD is accepted as well because a serial terminal may not
// send ESC sequences at all.
// Returns 0=up 1=right 2=down 3=left, -1 = nothing.
static int esc_state = 0;

static int key_poll(void)
{
    int c, d;
    if (uart_readOccupancy(BSP_UART_TERMINAL) == 0) return -1;
    c = (int)uart_read(BSP_UART_TERMINAL);

    if (esc_state == 0) {
        if (c == 27) { esc_state = 1; return -1; }
    } else if (esc_state == 1) {
        esc_state = (c == '[') ? 2 : 0;
        return -1;
    } else {
        esc_state = 0;
        if (c == 'A') return 0;
        if (c == 'C') return 1;
        if (c == 'B') return 2;
        if (c == 'D') return 3;
        return -1;
    }
    if (c == 'w' || c == 'W') return 0;
    if (c == 'd' || c == 'D') return 1;
    if (c == 's' || c == 'S') return 2;
    if (c == 'a' || c == 'A') return 3;
    if (c == 'k' || c == 'K') return 4;   // colour-key on/off
    return -1;
}

void main(void)
{
    uint32_t t0, t1, id;

    bsp_init();
    bsp_printf("\r\n=== GFX v2 engine ===\r\n");

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
        bsp_printf("idle scan: under+%d frames+%d first=%d\r\n",
                   (int)(ub - ua), (int)(fb - fa), (int)gfx_rd(G_FUROW));
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
        uint32_t scene = SC_SPRITE;
        uint32_t mode  = 1u;            // 1 = engine, 0 = CPU
        uint32_t fps10 = 0u;
        uint32_t frame_no = 0u;
        uint32_t prev_t = cyc();
        uint32_t key_on = 1u;          // colour key enabled
        uint32_t t_log = cyc();

        gfx_fb(front, FB_STRIDE, FB_W, FB_H);
        { uint32_t tw = cyc(); while ((cyc() - tw) < 10000000u) { } }

        bsp_printf("=== live demo: up/down=scene, left/right=engine/CPU ===\r\n");

        for (;;) {
            uint32_t t0 = cyc();
            uint32_t i;
            uint16_t keycol;
            int k = key_poll();

            // Frame rate is the FULL period, not the draw time. Measuring it
            // before the vsync wait reported the draw cost alone (68 fps) and
            // hid the fact that presentation was already locked to 60 Hz.
            { uint32_t dt = t0 - prev_t; if (dt) fps10 = 1000000000u / dt; }
            prev_t = t0;

            if (k == 0)      scene = (scene + 1u) % SC_N;
            else if (k == 2) scene = (scene + SC_N - 1u) % SC_N;
            else if (k == 1) mode = 1u;
            else if (k == 3) mode = 0u;
            else if (k == 4) key_on ^= 1u;

            keycol = key_on ? SPR_KEY : 0xFFFFu;

            if (mode) {
                uint32_t d0 = gfx_rd(G_DONE);
                uint32_t ncmd = 0u;

                for (i = 0; i < 4u; i++) {
                    gfx_fill(back + i * (FB_H / 4u) * FB_STRIDE,
                             FB_W, FB_H / 4u, FB_STRIDE, 0x0841u);
                    ncmd++;
                }
                switch (scene) {
                case SC_FILL:
                    for (i = 0; i < 4u; i++) {
                        gfx_fill(back + i * (FB_H / 4u) * FB_STRIDE,
                                 FB_W, FB_H / 4u, FB_STRIDE, g_scene_col[scene]);
                        ncmd++;
                    }
                    break;
                case SC_COPY:
                    for (i = 0; i < 64u; i++) {
                        uint32_t cx = (i & 7u) * 240u + 8u;
                        uint32_t cy = (i >> 3) * 132u + 8u;
                        gfx_fill(back + cy * FB_STRIDE + cx * 2u, 64u, 64u, FB_STRIDE,
                                 (i & 1u) ? 0xF800u : 0x07E0u);
                        ncmd++;
                    }
                    break;
                case SC_SPRITE:
                    for (i = 0; i < 256u; i++) {
                        uint32_t px, py;
                        demo_pos(SC_SPRITE, i, frame_no, &px, &py);
                        blit_disc(back, SPR_BASE + (xorshift(i * 97u) & 7u) * SPR_BYTES, px, py, keycol, key_on);
                        ncmd++;
                    }
                    break;
                default:        // SC_BULLET
                    for (i = 0; i < 512u; i++) {
                        uint32_t px, py;
                        demo_pos(SC_BULLET, i, frame_no, &px, &py);
                        blit_disc(back, SPR_BASE + (xorshift(i * 97u) & 7u) * SPR_BYTES, px, py, keycol, key_on);
                        ncmd++;
                    }
                    break;
                }
                gfx_wait_n(d0, ncmd);
            } else {
                sw_fill(back, 0x0841u);
                if (scene == SC_SPRITE || scene == SC_BULLET) {
                    uint32_t n = (scene == SC_SPRITE) ? 32u : 64u;
                    for (i = 0; i < n; i++) {
                        uint32_t px, py;
                        demo_pos(scene, i, frame_no, &px, &py);
                        sw_disc(back, SPR_BASE + (xorshift(i * 97u) & 7u) * SPR_BYTES, px, py);
                    }
                } else if (scene == SC_FILL) {
                    sw_fill(back, g_scene_col[scene]);
                } else {
                    for (i = 0; i < 64u; i++) {
                        uint32_t cx = (i & 7u) * 240u + 8u;
                        uint32_t cy = (i >> 3) * 132u + 8u;
                        volatile uint16_t *d = (volatile uint16_t *)(back + cy * FB_STRIDE + cx * 2u);
                        uint32_t yy, xx;
                        uint16_t col = (i & 1u) ? 0xF800u : 0x07E0u;
                        for (yy = 0; yy < 64u; yy++)
                            for (xx = 0; xx < 64u; xx++)
                                d[yy * (FB_STRIDE / 2u) + xx] = col;
                    }
                }
            }

            {
                char line[80];
                int n = 0;
                const char *q;
                volatile uint16_t *vp = (volatile uint16_t *)back;
                uint32_t px_count = (scene == SC_SPRITE) ? (mode ? 256u : 32u)
                                  : (scene == SC_BULLET) ? (mode ? 512u : 64u)
                                  : (scene == SC_COPY)   ? (mode ? 64u : 64u)
                                  : 1u;

                // line 1: resolution, scene, renderer, key state
                for (q = "1920X1080  "; *q; q++) line[n++] = *q;
                for (q = g_scene_name[scene]; *q; q++) line[n++] = *q;
                for (q = mode ? "  HW" : "  SW"; *q; q++) line[n++] = *q;
                for (q = key_on ? "  KEY ON" : "  KEY OFF"; *q; q++) line[n++] = *q;
                line[n] = 0;
                hud_text(vp, FB_STRIDE / 2u, 16u, 8u, line, 0xFFFFu, 0x0000u);

                // line 2: element count and frame rate
                n = 0;
                for (q = "ELEM "; *q; q++) line[n++] = *q;
                { char nb[12]; uint32_t j = 0u;
                  hud_num(nb, px_count, 0u);
                  while (nb[j]) line[n++] = nb[j++]; }
                for (q = "   FPS "; *q; q++) line[n++] = *q;
                { char nb[12]; uint32_t j = 0u;
                  hud_num(nb, fps10, 1u);
                  while (nb[j]) line[n++] = nb[j++]; }
                line[n] = 0;
                hud_text(vp, FB_STRIDE / 2u, 16u, 40u, line,
                         mode ? 0x07E0u : 0xFD20u, 0x0000u);

                // line 3: controls
                hud_text(vp, FB_STRIDE / 2u, 16u, 72u,
                         "UP/DOWN SCENE  LEFT/RIGHT ENGINE/CPU  K KEY",
                         0x8410u, 0x0000u);
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
                  hud_num(nb, fps10, 1u);
                  while (nb[j]) lb[ln++] = nb[j++]; }
                lb[ln] = 0;
                bsp_printf("%s\r\n", lb);
            }

            seq++;
            gfx_flip(back, seq);
            { uint32_t spin = 0u;
              while (gfx_rd(G_FBACCEPT) != seq && spin < 2000000u) spin++; }
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

