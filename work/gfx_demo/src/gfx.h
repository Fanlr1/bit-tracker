// gfx.h -- driver for the v2 GFX engine (registers 0x00..0x88 at 0xE1000000).
//
// Design rules that matter to the caller:
//   * A command is snapshotted into an 8-deep FIFO by the START write, so the
//     CPU may program the next command while the current one runs. Wait once
//     per frame, not once per command.
//   * DONE_CNT is free running; comparing it before and after a batch is the
//     only reliable completion test.
//   * The engine never touches memory outside [0x08000000, 0x0C000000); a
//     destination outside it is refused and flagged, not written.
#ifndef GFX_H
#define GFX_H

#include <stdint.h>

#define GFX_BASE        0xE1000000u

#define G_ID            0x00u
#define G_CTRL          0x04u
#define G_STATUS        0x08u
#define G_OP            0x0Cu
#define G_SRC           0x10u
#define G_DST           0x14u
#define G_SIZE          0x18u
#define G_SS            0x1Cu
#define G_DS            0x20u
#define G_COLOR         0x24u
#define G_ALPHA         0x28u
#define G_KEY           0x2Cu
#define G_CLIPX         0x30u
#define G_CLIPY         0x34u
#define G_DONE          0x38u
// Sprite table (v1): CPU writes 16-byte entries into a 16 KB window at
// 0xE1008000, then SPR_CTL = count | (1<<16) starts the table walker, which
// queues erase+draw commands by itself.
#define G_SPRTAB        0x78u
#define G_SPRCTL        0x7Cu
#define G_SPRDONE       0x80u
#define SPRTAB_BASE     0xE1008000u
#define SPRTAB_ENTRY    16u
#define G_ERRADDR       0x3Cu
#define G_FBBASE        0x40u
#define G_FBSTRIDE      0x44u
#define G_FBSIZE        0x48u
#define G_FBCFG         0x4Cu
#define G_FBNEXT        0x50u
#define G_FBSEQ         0x54u
#define G_FBCOMMIT      0x58u
#define G_FBACCEPT      0x5Cu
#define G_SCANST        0x60u
#define G_UNDER         0x64u
#define G_SHOWN         0x68u
#define G_AXIERR        0x6Cu
#define G_FRAMES        0x70u
#define G_LINES         0x74u
#define G_PIXCNT        0x84u
#define G_DBG           0x88u
#define G_DBG2          0x90u
#define G_DBG4          0x98u   // total line-read cycles in the last frame (divide by 1080 for cycles/line)
#define G_DBG3          0x94u   // [31:16] prefetch requests per frame, [15:0] longest prefetch stall   // [31:16] scan read-wait max, [15:0] burst-gap max
#define G_FUROW         0x8Cu

#define GFX_ID_VALUE    0x47465801u

#define GFX_OP_FILL     0u
#define GFX_OP_COPY     1u
#define GFX_OP_BLEND    2u
#define GFX_OP_KEY      3u
#define GFX_OP_BLIT     4u
#define GFX_OP_COPY_KEY 5u

#define ST_BUSY         (1u << 0)
#define ST_DONE         (1u << 1)
#define ST_ERROR        (1u << 2)
#define ST_CLIPPED      (1u << 3)
#define ST_FIFO_FULL    (1u << 4)

static inline void gfx_wr(uint32_t off, uint32_t v)
{
    *(volatile uint32_t *)(GFX_BASE + off) = v;
}

static inline uint32_t gfx_rd(uint32_t off)
{
    return *(volatile uint32_t *)(GFX_BASE + off);
}

// Order memory against the engine. The Sapphire core caches ordinary loads, so
// a framebuffer word the engine has just written can still be served from the
// CPU's copy until the fence retires.
static inline void gfx_fence(void)
{
    __asm__ volatile ("fence rw,rw" ::: "memory");
}

// Block only while the command FIFO is full. This is the one place the driver
// reads a register in a loop, and it returns immediately in steady state.
static inline void gfx_slot(void)
{
    // Check before EVERY command. Polling every second command is unsafe: the
    // 8-deep FIFO can already be full after the skipped one, the engine then
    // silently drops a START, and gfx_wait_n waits forever for a DONE count it
    // can never reach. This was the regression that took the 1408-sprite demo
    // from 60 fps to 48.8 fps (2026-10-31).
    while (gfx_rd(G_STATUS) & ST_FIFO_FULL) { }
}

// A read between two writes forces the first one to complete before the CPU
// retires the next store. Without it the AXI interconnect can deliver the ten
// parameter writes out of order, and the FIFO then snapshots a half-old,
// half-new parameter set -- measured on the board as a fill that used the NEXT
// command's destination address.
// Cleared: measurement showed the barriers did not change any result but did add
// about 2500 CPU register reads per frame, which competed with scan-out for the
// read channel. Re-enable only if a parameter mix-up ever reappears.
#define GFX_BARRIER() do { } while (0)

static inline void gfx_push(uint32_t op, uint32_t src, uint32_t dst,
                            uint32_t w, uint32_t h,
                            uint32_t ss, uint32_t ds,
                            uint32_t color, uint32_t alpha, uint32_t key)
{
    gfx_slot();
    gfx_wr(G_OP,    op);    GFX_BARRIER();
    gfx_wr(G_SRC,   src);   GFX_BARRIER();
    gfx_wr(G_DST,   dst);   GFX_BARRIER();
    gfx_wr(G_SIZE,  (h << 16) | (w & 0xFFFFu)); GFX_BARRIER();
    gfx_wr(G_SS,    ss);    GFX_BARRIER();
    gfx_wr(G_DS,    ds);    GFX_BARRIER();
    gfx_wr(G_COLOR, color); GFX_BARRIER();
    gfx_wr(G_ALPHA, alpha & 0xFFu); GFX_BARRIER();
    gfx_wr(G_KEY,   key & 0xFFFFu); GFX_BARRIER();
    gfx_wr(G_CTRL,  1u);
}

// Fast variants: the engine snapshots its command registers on G_CTRL, so any
// field that is not rewritten keeps its previous value. These helpers assume
// the caller has already programmed the invariant fields once (first command of
// a scene goes through the full gfx_push path).
static inline void gfx_fill_fast(uint32_t dst)
{
    gfx_slot();
    gfx_wr(G_OP,   GFX_OP_FILL);
    gfx_wr(G_DST,  dst);
    gfx_wr(G_CTRL, 1u);
}

static inline void gfx_copy_key_fast(uint32_t src, uint32_t dst)
{
    gfx_slot();
    gfx_wr(G_OP,   GFX_OP_COPY_KEY);
    gfx_wr(G_SRC,  src);
    gfx_wr(G_DST,  dst);
    gfx_wr(G_CTRL, 1u);
}

static inline void gfx_fill(uint32_t dst, uint32_t w, uint32_t h,
                            uint32_t ds, uint32_t color)
{
    gfx_push(GFX_OP_FILL, 0u, dst, w, h, 0u, ds, color, 255u, 0u);
}

static inline void gfx_copy(uint32_t src, uint32_t dst, uint32_t w, uint32_t h,
                            uint32_t ss, uint32_t ds)
{
    gfx_push(GFX_OP_COPY, src, dst, w, h, ss, ds, 0u, 255u, 0u);
}

static inline void gfx_copy_key(uint32_t src, uint32_t dst, uint32_t w, uint32_t h,
                                uint32_t ss, uint32_t ds, uint32_t key)
{
    gfx_push(GFX_OP_COPY_KEY, src, dst, w, h, ss, ds, 0u, 255u, key);
}

static inline void gfx_blit(uint32_t src, uint32_t dst, uint32_t w, uint32_t h,
                            uint32_t ss, uint32_t ds, uint32_t alpha, uint32_t key)
{
    gfx_push(GFX_OP_BLIT, src, dst, w, h, ss, ds, 0u, alpha, key);
}

// Wait until DONE_CNT has advanced by "n" from "before". Returns 0, or -1 if
// the bounded spin expired (a hang is then reported instead of a silent stall).
static inline int gfx_wait_n(uint32_t before, uint32_t n)
{
    uint32_t spin = 0u;
    while ((gfx_rd(G_DONE) - before) < n) {
        if (++spin > 4000000u) return -1;
    }
    gfx_fence();
    return 0;
}

static inline int gfx_wait_idle(void)
{
    uint32_t spin = 0u;
    while (gfx_rd(G_STATUS) & ST_BUSY) {
        if (++spin > 4000000u) return -1;
    }
    gfx_fence();
    return 0;
}

static inline void gfx_fb(uint32_t base, uint32_t stride, uint32_t w, uint32_t h)
{
    gfx_wr(G_FBBASE,   base);
    gfx_wr(G_FBSTRIDE, stride);
    gfx_wr(G_FBSIZE,   (h << 16) | (w & 0xFFFFu));
    gfx_wr(G_FBCFG,    1u);
}

// Queue a page flip. The scan-out applies it at the next frame start, so the
// caller must not draw into that page until FB_ACCEPTED equals seq.
static inline void gfx_flip(uint32_t base, uint32_t seq)
{
    gfx_wr(G_FBNEXT,   base);
    gfx_wr(G_FBSEQ,    seq);
    gfx_wr(G_FBCOMMIT, 1u);
}

#endif
