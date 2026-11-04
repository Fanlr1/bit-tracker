// ============================================================================
// bg_art.h -- 「夜之废墟广场」暗黑邪典背景生成器（RGB565，一次性写进 DDR）
//
// 统一空间构图（替换旧版「星空 + 石砖」两套互相矛盾的图层）：
//
//   地平线  y = BA_HOR = 450  (屏幕 42%)        消失点 (960, 450)
//
//   远 | 夜空竖向渐变 + 薄云 + 血月（月食辉）+ 稀疏星点      y 132..449
//   中 | 远景废墟天际线（贴地平线）/ 左右框景断墙 + 中央残门
//   近 | 透视石砖广场：砖行深度等比，行高与砖宽 = K / 深度   y 450..1079
//   前 | 地平线雾带（中景底部与远地面糅在一起）+ 暗角 + 底部地面雾
//
//   中央战斗区 (x 400..1520, y 200..900) 的细节对比压到 ~40%，不干扰精灵
//
// 大气透视：远处颜色趋近地平线雾色（低对比、低饱和），近处更暗更冷更实。
// 全部整数/定点：无浮点、无 libm、无 64 位除法、无动态内存。
// bss 占用 0 B（旧版 1250 B；只有 4 B 的 rng 种子在 .data），
// 启动耗时估算 ≈0.3 s @100 MHz（按 2.07 M 像素写 + 约 31 M 周期估）。
//
// 主机自测：本文件自带 _MSC_VER 分支，可用 MSVC 把 bg_art.h 编进一个小 harness
// 直接导出 RGB565 位图看效果（不用烧板），改一版看一眼。 
//
// 接入方式不变（lead 无需改动 main.c）：
//   main.c 已 #include "game.h"（提供 BG_BASE / BG_STRIDE），下一行
//   #include "bg_art.h"，启动时调用一次 bg_build_art()。
//   主机自测可用 -DBG_ART_BASE=.../-DBG_ART_STRIDE=... 覆盖。
//
// 注意：HUD 区（y<132）写平色 0x2104（= G_HUDBG），128..131 行保留
// G_ACC（0x5AEB）分隔线，与 game_hud 的文字底 cell 一致。
// ============================================================================
#ifndef BG_ART_H
#define BG_ART_H

#include <stdint.h>

#ifndef BG_ART_BASE
#define BG_ART_BASE BG_BASE
#endif
#ifndef BG_ART_STRIDE
#define BG_ART_STRIDE BG_STRIDE
#endif

#if defined(_MSC_VER)
#define BA_INLINE static __inline
#else
#define BA_INLINE static inline
#endif

// ---------------------------------------------------------------- geometry
#define BA_W        1920
#define BA_H        1080
#define BA_HUD_H    132
#define BA_HOR      450           // 地平线行（0.42 * 1080）
#define BA_VPX      960           // 消失点 x

#define BA_HUDC     0x2104        // = G_HUDBG
#define BA_ACCC     0x5AEB        // = G_ACC

#define BA_ROW_W(y) ((volatile uint16_t *)(uintptr_t)((uintptr_t)BG_ART_BASE + \
                     (uint32_t)(y) * (uint32_t)BG_ART_STRIDE))

// ---- 地面透视常量 ------------------------------------------------------
// 屏幕纵向偏移（相对地平线）  y_off = BA_KY256 / D
//   D 是深度，单位 1/256 世界单位（D=256 <=> 近端 1.0）
//   D=256 时 y_off = 630 -> 最底行正好填满 450..1080
// 砖宽在屏幕上的步长 = BA_CW256 / D（同样的 1/深度 缩放 => 列线收敛于消失点）
#define BA_KY256    161280         /* 630 * 256 */
#define BA_DSTEP    72             /* 每行深度增量 = 0.281 世界单位 */
#define BA_CW256    38430          /* 一砖宽的屏幕分子 = 630 * 0.238 */
#define BA_CELL256  9838080        /* BA_CW256 * 256（求 1/256 px 步长） */

// ---- 调色板（暗黑邪典：深紫 / 暗红 / 骨白 / 墨绿，禁止明亮鲜艳色）------
#define BA_FOGR     68             // 地平线雾色（远景统一趋近色）
#define BA_FOGG     45
#define BA_FOGB     62

#define BA_QUIET_X0 400            // 中央战斗区（低对比）
#define BA_QUIET_X1 1520
#define BA_QUIET_Y0 200
#define BA_QUIET_Y1 900

// ---------------------------------------------------------------- helpers
BA_INLINE int ba_clamp(int v, int lo, int hi)
{
    return v < lo ? lo : (v > hi ? hi : v);
}

BA_INLINE int ba_mix(int a, int b, int w)      // w: 0..256
{
    return a + (((b - a) * w) >> 8);
}

BA_INLINE uint16_t ba_rgb(int r, int g, int b)
{
    r = ba_clamp(r, 0, 255);
    g = ba_clamp(g, 0, 255);
    b = ba_clamp(b, 0, 255);
    return (uint16_t)((((uint32_t)r & 0xF8u) << 8) |
                      (((uint32_t)g & 0xFCu) << 3) |
                      ((uint32_t)b >> 3));
}

BA_INLINE uint16_t ba_dark(uint16_t c, int mul)   // mul: 0..256
{
    int r = (int)((c >> 11) & 31u);
    int g = (int)((c >> 5) & 63u);
    int b = (int)(c & 31u);
    r = (r * mul) >> 8;
    g = (g * mul) >> 8;
    b = (b * mul) >> 8;
    return (uint16_t)(((uint32_t)r << 11) | ((uint32_t)g << 5) | (uint32_t)b);
}

// 暗角：中心 256，左右边缘 ~200，四角 ~170（乘法分离，省一次开方）
BA_INLINE int ba_vig(int x, int y)
{
    int dx = x - BA_VPX;
    int dy = y - 520;
    if (dx < 0) dx = -dx;
    if (dy < 0) dy = -dy;
    dx = 256 - ((dx * dx) >> 14);
    dy = 256 - ((dy * dy) >> 13);
    dx = (dx * dy) >> 8;
    return dx < 96 ? 96 : dx;
}

// 中央战斗区权重：0 = 正常细节，256 = 完全安静（边缘 96 px 平滑过渡）
BA_INLINE int ba_quiet(int x, int y)
{
    int qx, qy, d;
    if (x <= BA_QUIET_X0 || x >= BA_QUIET_X1) {
        qx = 0;
    } else {
        d = x - BA_QUIET_X0;
        if (BA_QUIET_X1 - x < d) d = BA_QUIET_X1 - x;
        if (d > 96) d = 96;
        qx = (d * 8) / 3;
    }
    if (y <= BA_QUIET_Y0 || y >= BA_QUIET_Y1) {
        qy = 0;
    } else {
        d = y - BA_QUIET_Y0;
        if (BA_QUIET_Y1 - y < d) d = BA_QUIET_Y1 - y;
        if (d > 96) d = 96;
        qy = (d * 8) / 3;
    }
    return (qx * qy) >> 8;
}

// 4x4 Bayer 有序抖动：RGB565 的蓝通道只有 5 bit，暗色天空渐变如果不抖动
// 会出现 4~5 条明显色带
static const uint8_t ba_bay[16] = {
    0u, 8u, 2u, 10u, 12u, 4u, 14u, 6u, 3u, 11u, 1u, 9u, 15u, 7u, 13u, 5u
};

BA_INLINE int ba_dither(int x, int y)
{
    return (int)ba_bay[((y & 3) << 2) | (x & 3)] - 8;
}

// ---------------------------------------------------------------- PRNG
static uint32_t ba_rng_state = 0x5EED1234u;

BA_INLINE uint32_t ba_rand(void)
{
    uint32_t x = ba_rng_state;
    x ^= x << 13;
    x ^= x >> 17;
    x ^= x << 5;
    ba_rng_state = x;
    return x;
}

BA_INLINE int ba_rnd(int n)                    // 0 .. n-1
{
    return (int)(((ba_rand() >> 16) * (uint32_t)n) >> 16);
}

static uint32_t ba_hash(uint32_t a)
{
    a ^= 0x9E3779B9u;
    a ^= a >> 16;
    a *= 0x85EBCA6Bu;
    a ^= a >> 13;
    a *= 0xC2B2AE35u;
    a ^= a >> 16;
    return a;
}

BA_INLINE int ba_hc(uint32_t x, uint32_t y)     // 值噪声格点 0..255
{
    return (int)((ba_hash((x * 73856093u) ^ (y * 19349663u)) >> 24) & 255u);
}

// 双线性值噪声，格子 2^shx x 2^shy 像素（shx/shy <= 8）
BA_INLINE int ba_noise(int x, int y, int shx, int shy)
{
    int cx = x >> shx;
    int cy = y >> shy;
    int fx = (x & ((1 << shx) - 1)) << (8 - shx);
    int fy = (y & ((1 << shy) - 1)) << (8 - shy);
    int v00 = ba_hc((uint32_t)cx, (uint32_t)cy);
    int v10 = ba_hc((uint32_t)(cx + 1), (uint32_t)cy);
    int v01 = ba_hc((uint32_t)cx, (uint32_t)(cy + 1));
    int v11 = ba_hc((uint32_t)(cx + 1), (uint32_t)(cy + 1));
    int a = v00 + (((v10 - v00) * fx) >> 8);
    int b = v01 + (((v11 - v01) * fx) >> 8);
    return a + (((b - a) * fy) >> 8);
}

static uint32_t ba_isqrt(uint32_t v)            // 整数平方根（无除法）
{
    uint32_t r = 0u;
    uint32_t b = 1u << 30;
    while (b > v) b >>= 2;
    while (b) {
        if (v >= r + b) { v -= r + b; r = (r >> 1) + b; }
        else r >>= 1;
        b >>= 2;
    }
    return r;
}

// ---------------------------------------------------------------- 天空色带
// 7 个色标，全部落在同一套「夜晚废墟」色域：深靛 -> 深紫 -> 暗红霭
static const int16_t ba_sky_y[7] = { 132, 190, 250, 312, 368, 414, 450 };
static const uint8_t ba_sky_c[7][3] = {
    { 14, 11, 34 },      // 天顶：深靛（不是纯黑，RGB565 暗部才有层次）
    { 19, 16, 42 },
    { 25, 18, 46 },
    { 34, 22, 50 },      // 深紫
    { 46, 28, 54 },
    { 58, 36, 58 },      // 暗红霭
    { BA_FOGR, BA_FOGG, BA_FOGB }   // 地平线雾：与地面远端同色，天/地无缝
};

static void ba_sky_at(int y, int *pr, int *pg, int *pb)
{
    int i = 0, t, d;
    while (i < 5 && y > (int)ba_sky_y[i + 1]) i++;
    t = y - (int)ba_sky_y[i];
    d = (int)ba_sky_y[i + 1] - (int)ba_sky_y[i];
    if (d < 1) d = 1;
    *pr = (int)ba_sky_c[i][0] + ((int)ba_sky_c[i + 1][0] - (int)ba_sky_c[i][0]) * t / d;
    *pg = (int)ba_sky_c[i][1] + ((int)ba_sky_c[i + 1][1] - (int)ba_sky_c[i][1]) * t / d;
    *pb = (int)ba_sky_c[i][2] + ((int)ba_sky_c[i + 1][2] - (int)ba_sky_c[i][2]) * t / d;
}

// ---------------------------------------------------------------- HUD 带
static void ba_hud(void)
{
    int y, x;
    for (y = 0; y < BA_HUD_H; y++) {
        volatile uint16_t *row = BA_ROW_W(y);
        for (x = 0; x < BA_W; x++) row[x] = BA_HUDC;
    }
    for (y = BA_HUD_H - 4; y < BA_HUD_H; y++) {
        volatile uint16_t *row = BA_ROW_W(y);
        for (x = 0; x < BA_W; x++) row[x] = BA_ACCC;
    }
}

// ---------------------------------------------------------------- 夜空
// 逐行流式：每行算 121 个采样点（步长 16 px），再水平插值到 1920 px。
// 云只有一层横向拉伸的值噪声（64x32 格），压在天顶与地平线之间。
static void ba_sky(void)
{
    int y;
    for (y = BA_HUD_H; y < BA_HOR; y++) {
        int sr, sg, sb, pr, pg, pb;
        int i, x;
        volatile uint16_t *row = BA_ROW_W(y);

        ba_sky_at(y, &sr, &sg, &sb);

        // 地平线霭光：越贴地平线越亮，给中景剪影一个背光
        if (y > 396) {
            int t = y - 396;
            int gl = (t * t) >> 5;
            sr += gl >> 2;
            sg += (gl * 3) >> 4;
            sb += gl >> 2;
        }

        pr = -1; pg = -1; pb = -1;
        for (i = 0; i <= (int)(BA_W / 16); i++) {
            int sx = i << 4;
            int r = sr, g = sg, b = sb;
            int v;

            // 薄云
            if (y > 214 && y < 392) {
                int n = ba_noise(sx, y << 1, 6, 5);
                int dy = (y > 306) ? (y - 306) : (306 - y);
                int band = 256 - ((dy * 256) / 92);
                int q = ba_quiet(sx, y);
                int d;
                if (band < 0) band = 0;
                d = n - 126;
                if (d > 0) {
                    d = (d * band) >> 8;
                    d = (d * (256 - ((q * 170) >> 8))) >> 8;
                    r += (d * 24) >> 8;
                    g += (d * 16) >> 8;
                    b += (d * 32) >> 8;
                }
            }

            // 暗角
            v = ba_vig(sx > BA_W - 1 ? BA_W - 1 : sx, y);
            r = (r * v) >> 8;
            g = (g * v) >> 8;
            b = (b * v) >> 8;

            if (pr >= 0) {
                int x0 = sx - 16;
                int x1 = sx;
                if (x0 < 0) x0 = 0;
                if (x1 > BA_W) x1 = BA_W;
                for (x = x0; x < x1; x++) {
                    int k = x & 15;
                    int dv = ba_dither(x, y);
                    int rr = pr + (((r - pr) * k) >> 4) + dv;
                    int gg = pg + (((g - pg) * k) >> 4) + dv;
                    int bb = pb + (((b - pb) * k) >> 4) + dv;
                    row[x] = ba_rgb(rr, gg, bb);
                }
            }
            pr = r; pg = g; pb = b;
        }
    }
}

// ---------------------------------------------------------------- 血月
// 暗红月盘 + 月食式的亮边缘 + 外侧红色辉光：中心亮度只有 ~45/255，是画面
// 焦点而不是干扰源。
#define BA_MX    1300
#define BA_MY    236
#define BA_MR    104
#define BA_MHALO 236

static void ba_moon(void)
{
    int y, x;
    int r2 = BA_MR * BA_MR;
    int h2 = BA_MHALO * BA_MHALO;
    for (y = BA_MY - BA_MHALO; y <= BA_MY + BA_MHALO; y++) {
        int dy, d2y;
        volatile uint16_t *row;
        if (y < BA_HUD_H || y >= BA_HOR) continue;
        dy = y - BA_MY;
        d2y = dy * dy;
        row = BA_ROW_W(y);
        for (x = BA_MX - BA_MHALO; x <= BA_MX + BA_MHALO; x++) {
            int dx, d2, c, r, g, b, v;
            if (x < 0 || x >= BA_W) continue;
            dx = x - BA_MX;
            d2 = dx * dx + d2y;
            if (d2 > h2) continue;
            c = (int)row[x];
            r = (c >> 11) & 31;
            g = (c >> 5) & 63;
            b = c & 31;
            v = ba_vig(x, y);
            if (d2 <= r2) {
                // 月盘：中心偏暗、边缘更亮（血月/月食的红色亮边）
                int bt = (r2 - d2) >> 6;             // 169（中心）.. 0（边缘）
                int cr = 96 - ((bt * 78) >> 8);
                int cg = 38 - ((bt * 30) >> 8);
                int cb = 38 - ((bt * 26) >> 8);
                int ddx, ddy;
                ddx = dx + 34; ddy = dy + 26;
                if (ddx * ddx + ddy * ddy < 26 * 26) { cr -= 12; cg -= 5; cb -= 5; }
                ddx = dx - 24; ddy = dy - 16;
                if (ddx * ddx + ddy * ddy < 34 * 34) { cr -= 9; cg -= 4; cb -= 4; }
                ddx = dx + 6; ddy = dy - 52;
                if (ddx * ddx + ddy * ddy < 17 * 17) { cr -= 14; cg -= 6; cb -= 6; }
                r = (cr * v) >> 8;
                g = (cg * v) >> 8;
                b = (cb * v) >> 8;
                r = ba_clamp(r + ba_dither(x, y), 0, 255) >> 3;
                g = ba_clamp(g + ba_dither(x, y), 0, 255) >> 2;
                b = ba_clamp(b + ba_dither(x, y), 0, 255) >> 3;
                row[x] = (uint16_t)(((uint32_t)r << 11) | ((uint32_t)g << 5) | (uint32_t)b);
            } else {
                // 外侧辉光（加法混合，二次衰减）
                int t = d2 - r2;
                int a = 255 - ((t * 3) >> 9);
                if (a <= 0) continue;
                a = (a * a) >> 8;
                r += (a * 16) >> 11;
                g += (a * 6) >> 11;
                b += (a * 8) >> 11;
                if (r > 31) r = 31;
                if (g > 63) g = 63;
                if (b > 31) b = 31;
                row[x] = (uint16_t)(((uint32_t)r << 11) | ((uint32_t)g << 5) | (uint32_t)b);
            }
        }
    }
}

// ---------------------------------------------------------------- 星点
// 只在天空、避开月盘，中央战斗区大幅压暗；亮度整体压得很低（暗夜，不是太空）
static void ba_stars(void)
{
    int i;
    for (i = 0; i < 520; i++) {
        int x = ba_rnd(BA_W);
        int y = BA_HUD_H + 4 + ba_rnd(BA_HOR - BA_HUD_H - 12);
        uint32_t h = ba_rand();
        int bb = (int)((h >> 24) & 255u);
        int br = 14 + ((bb * bb) >> 9);
        int q = ba_quiet(x, y);
        int v, dx, dy, r, g, bl;
        if (x < 2 || x > BA_W - 3) continue;
        dx = x - BA_MX;
        dy = y - BA_MY;
        if (dx * dx + dy * dy < (BA_MHALO * BA_MHALO) / 2) continue;
        br -= (br * q * 110) >> 16;
        v = ba_vig(x, y);
        br = (br * v) >> 8;
        if (br < 4) continue;
        r = (br * 216) >> 8;
        g = (br * 232) >> 8;
        bl = br;
        BA_ROW_W(y)[x] = ba_rgb(r, g, bl);
        if ((h & 255u) > 236u) {
            uint16_t c = ba_rgb(r >> 2, g >> 2, bl >> 2);
            BA_ROW_W(y)[x - 1] = c;
            BA_ROW_W(y)[x + 1] = c;
            if (y > BA_HUD_H + 1) BA_ROW_W(y - 1)[x] = c;
            if (y < BA_HOR - 1) BA_ROW_W(y + 1)[x] = c;
        }
    }
}


// ---------------------------------------------------------------- 透视石砖地面
// 一行 = 一个深度 D。屏幕行高与砖宽都按 1/D 缩放，所以近大远小、
// 列线严格收敛于消失点 (960,450)。
// 雾权重：0（近，看得清石头）.. 244（远，几乎全是雾色）。
// 二次衰减：线性衰减会让屏幕下半部整片发白，近暗远亮的层次就没有了。
BA_INLINE int ba_fogw(int dym)
{
    int k = 560 - dym;
    int w;
    if (k < 0) k = 0;
    if (k > 560) k = 560;
    w = (((k * k) >> 8) * k) / 2400;                /* 三次方，0..285 */
    return w > 250 ? 250 : w;
}

// 石头本地色 -> 暗角 -> 大气雾。混雾必须放在最后一步：
// 否则远景砖缝/苔藓会保留 (1-fog) 的对比度，地平线附近糊成一片网格噪点。
BA_INLINE uint16_t ba_stone(int r, int g, int b, int v, int fogw)
{
    r = ba_clamp((r * v) >> 8, 0, 255);
    g = ba_clamp((g * v) >> 8, 0, 255);
    b = ba_clamp((b * v) >> 8, 0, 255);
    return ba_rgb(ba_mix(r, BA_FOGR, fogw),
                  ba_mix(g, BA_FOGG, fogw),
                  ba_mix(b, BA_FOGB, fogw));
}

static void ba_gnd_row(int k, int D, int ytop, int ybot)
{
    int step = (int)(BA_CELL256 / (uint32_t)D);     /* 每砖的 1/256 px 步长 */
    int ymid = (ytop + ybot) >> 1;
    int dym = ymid - BA_HOR;
    int fogw = ba_fogw(dym);
    int jw = (step > 3072) ? 2 : 1;                 /* 砖宽 >12px 才用 2px 缝 */
    int sr, sg, sb;
    int nleft, x256, i, x0, x1, y, x;
    volatile uint16_t *rp;

    nleft = (245760 / step) + 1;                    /* 960*256 = 245760 */
    x256 = 245760 - nleft * step;
    for (i = -nleft; i <= nleft; i++) {
        int xc, h, sh, q, v, dv, xa, xe, nv, qw;
        uint16_t cbody, cjoint, cedge;

        x0 = x256 >> 8;
        x256 += step;
        x1 = x256 >> 8;
        if (x0 >= BA_W) break;
        if (x1 <= 0) continue;
        xa = (x0 < 0) ? 0 : x0;
        xe = (x1 > BA_W) ? BA_W : x1;
        if (xe <= xa) continue;

        xc = (xa + xe) >> 1;
        h = (int)(ba_hash((uint32_t)(k * 7283 + 17) * 2654435761u ^
                          (uint32_t)(i + 4096) * 40503u) & 0x7FFFFFFFu);
        q = ba_quiet(xc, ymid);
        v = ba_vig(xc, ymid);
        qw = 256 - ((q * 150) >> 8);                /* 中央战斗区压对比 */

        /* 大尺度脏污/磨损（两层值噪声）：地面层次靠这个出，
           而不是靠单砖随机明暗（那会变成棋盘格） */
        nv = ba_noise(xc, ymid, 7, 6) - 128;
        nv = (nv * 3 + (ba_noise(xc + 90, ymid + 40, 8, 7) - 128) * 2) >> 7;
        nv = (nv * qw) >> 8;

        sh = ((int)((uint32_t)h & 7u) - 4) * 3 / 4;  /* 单块砖 +-2 */
        sh = (sh * qw) >> 8;
        dv = (int)((h >> 4) & 7u) - 3;              /* 逐砖微抖动（哈希，不要用 Bayer） */

        sr = 38 + sh + nv + dv;
        sg = 40 + (sh * 8) / 10 + (nv * 10) / 12 + dv;
        sb = 52 + (sh * 11) / 10 + nv + dv;
        /* 潮湿处（低频噪声低洼区）掺一点墨绿，比画苔藓色块自然 */
        if (nv < 0) {
            sr += nv / 3;
            sg -= nv / 5;
            sb += nv / 3;
        }
        cbody = ba_stone(sr, sg, sb, v, fogw);
        cjoint = ba_stone((sr * 148) >> 8, (sg * 146) >> 8, (sb * 160) >> 8, v, fogw);
        cedge = ba_stone(sr + 9, sg + 9, sb + 8, v, fogw);   /* 砖面上沿受光 */

        for (y = ytop; y < ybot; y++) {
            rp = BA_ROW_W(y);
            if (y == ytop && ybot - ytop > 2) {
                for (x = xa; x < xe; x++) rp[x] = cjoint;      /* 远处砖缝 */
            } else {
                uint16_t cb2 = (y == ytop + 1 && ybot - ytop > 4) ? cedge : cbody;
                for (x = xa + jw; x < xe; x++) rp[x] = cb2;
                for (x = xa; x < xa + jw && x < xe; x++) rp[x] = cjoint;
            }
        }

        /* 裂缝（暗线 + 一点点高光边） */
        if (xe - xa > 26 && ybot - ytop > 18 && ((h >> 5) & 15u) == 0u) {
            int ln = ybot - ytop - 6;
            int sx = xa + 3 + (int)(((uint32_t)(h >> 11)) % (uint32_t)(xe - xa - 10));
            for (y = 0; y < ln; y++) {
                int py = ytop + 3 + y;
                int px = sx + (y >> 1);
                if (px + 1 >= xe || py >= ybot - 2) break;
                rp = BA_ROW_W(py);
                rp[px] = cjoint;
                rp[px + 1] = ba_stone((sr * 180) >> 8, (sg * 180) >> 8, (sb * 195) >> 8, v, fogw);
            }
        }
    }
}

// 地平线附近的纯雾过渡区（砖格已经小到看不见，避免条纹噪声）
static void ba_gnd_far(int ybot)
{
    int y, x;
    for (y = BA_HOR; y < ybot; y++) {
        int dy = y - BA_HOR;
        int fogw = ba_fogw(dy);
        volatile uint16_t *row = BA_ROW_W(y);
        for (x = 0; x < BA_W; x++) {
            int dv = ba_dither(x, y);
            int v = ba_vig(x, y);
            row[x] = ba_stone(38 + dv, 40 + dv, 52 + dv, v, fogw);
        }
    }
}

static void ba_ground(void)
{
    int ybot = BA_HOR + (int)(BA_KY256 / 256);
    int k;
    for (k = 0; k < 300; k++) {
        int Dn = 256 + BA_DSTEP * (k + 1);
        int ytop = BA_HOR + (int)((uint32_t)BA_KY256 / (uint32_t)Dn);
        if (ytop >= ybot) continue;
        if (ytop < BA_HOR + 34) {
            ba_gnd_row(k, 256 + BA_DSTEP * k, BA_HOR + 34, ybot);
            ybot = BA_HOR + 34;
            break;
        }
        ba_gnd_row(k, 256 + BA_DSTEP * k, ytop, ybot);
        ybot = ytop;
    }
    ba_gnd_far(ybot);
}

// ---------------------------------------------------------------- 剪影工具
BA_INLINE void ba_fill(int x0, int y0, int x1, int y1, uint16_t c)
{
    int y, x;
    if (x0 < 0) x0 = 0;
    if (x1 > BA_W) x1 = BA_W;
    if (y0 < BA_HUD_H) y0 = BA_HUD_H;
    if (y1 > BA_H) y1 = BA_H;
    if (x1 <= x0 || y1 <= y0) return;
    for (y = y0; y < y1; y++) {
        volatile uint16_t *row = BA_ROW_W(y);
        for (x = x0; x < x1; x++) row[x] = c;
    }
}

BA_INLINE void ba_rimtop(int x0, int y0, int x1, uint16_t c)
{
    int x;
    if (y0 < BA_HUD_H || y0 >= BA_H) return;
    if (x0 < 0) x0 = 0;
    if (x1 > BA_W) x1 = BA_W;
    for (x = x0; x < x1; x++) BA_ROW_W(y0)[x] = c;
}

static void ba_tri(int cx, int ytip, int halfw, int ybase, uint16_t c)
{
    int y, span = ybase - ytip;
    if (span <= 0) return;
    for (y = ytip; y < ybase; y++) {
        int hw = (int)(((int32_t)(y - ytip) * halfw) / span);
        ba_fill(cx - hw, y, cx + hw + 1, y + 1, c);
    }
}

// 拱形开口：露出被压暗的天空（背光），让墙体有厚度
static void ba_arch(int cx, int ytop, int r, int ybot, int mul)
{
    int y;
    for (y = ytop - r; y < ybot && y < BA_HOR; y++) {
        int half, x;
        int sr, sg, sb;
        uint16_t c;
        volatile uint16_t *row;
        if (y < BA_HUD_H) continue;
        if (y < ytop) {
            int d = ytop - y;
            half = (int)ba_isqrt((uint32_t)(r * r - d * d));
        } else {
            half = r;
        }
        ba_sky_at(y, &sr, &sg, &sb);
        c = ba_rgb((sr * mul) >> 8, (sg * mul) >> 8, (sb * mul) >> 8);
        row = BA_ROW_W(y);
        for (x = cx - half; x <= cx + half; x++) {
            if (x < 0) continue;
            if (x >= BA_W) break;
            row[x] = c;
        }
    }
}

// ---------------------------------------------------------------- 远景废墟天际线
// 贴地平线的一层碎石矮墙 / 塔尖，颜色只比雾色暗一档（大气透视）
static void ba_far_skyline(void)
{
    uint16_t body = ba_rgb(36, 26, 34);
    uint16_t rim = ba_rgb(48, 36, 42);
    uint16_t dark = ba_rgb(30, 22, 29);
    int x = -24;
    ba_rng_state = 0x71A9C3u;
    while (x < BA_W) {
        int bw = 14 + ba_rnd(78);
        int bh = 7 + ba_rnd(24);
        int top;
        uint32_t r;
        ba_rand();
        r = ba_rand();
        if ((r & 31u) < 5u) bh += 26 + (int)((r >> 9) & 55u);   /* 少量高塔 */
        top = BA_HOR - bh;
        ba_fill(x, top, x + bw, BA_HOR + 2, body);
        /* 顶部锯齿：把塔顶削成残破的台阶，避免平顶*/ 
        if (bw > 20) {
            int k2;
            int cut = 2 + (int)((r >> 21) & 7u);
            for (k2 = 0; k2 < cut; k2++) {
                int cw = 4 + (int)((r >> (k2 + 3)) & 11u);
                int cx = x + 2 + (int)((r >> (k2 * 3 + 5)) % (uint32_t)(bw - 6));
                ba_fill(cx, top, cx + cw, top + 3 + (int)((r >> (k2 + 9)) & 7u), dark);
            }
        }
        if ((r & 3u) == 0u && bw > 26) {
            int cx;
            for (cx = x + 3; cx < x + bw - 5; cx += 12)
                ba_fill(cx, top - 7, cx + 6, top, body);
        } else if ((r & 7u) == 1u) {
            int tw = 5 + (int)((r >> 8) & 7u);
            int th = 16 + (int)((r >> 12) & 31u);
            int tx = x + 3 + (int)((r >> 16) % (uint32_t)(bw > 12 ? bw - 10 : 1));
            ba_fill(tx, top - th, tx + tw, top + 1, body);
            ba_tri(tx + tw / 2, top - th - th / 2, tw / 2 + 2, top - th, body);
        } else if ((r & 7u) == 2u) {
            int g = 4 + (int)((r >> 9) & 15u);
            ba_fill(x + g, top + 8, x + g + 8 + (int)((r >> 14) & 15u), BA_HOR + 2, dark);
        }
        ba_rimtop(x, top, x + bw, rim);
        x += bw + (int)((r >> 20) & 15u) - 5;
    }
}

// ---------------------------------------------------------------- 中景废墟（左右框景）
static void ba_mid_ruins(void)
{
    uint16_t body = ba_rgb(10,  8, 14);
    uint16_t rim = ba_rgb(30, 23, 31);
    uint16_t dark = ba_rgb(6,  5,  9);
    int i;

    // ---- 左侧：断墙 + 主塔 + 拱廊
    ba_fill(0, 214, 46, BA_HOR + 2, body);
    ba_fill(46, 236, 132, BA_HOR + 2, body);
    ba_fill(96, 150, 214, BA_HOR + 2, body);      /* 主塔 */
    ba_tri(155, 92, 44, 150, body);               /* 塔尖 */
    ba_fill(214, 288, 330, BA_HOR + 2, body);
    ba_fill(330, 352, 396, BA_HOR + 2, body);
    ba_rimtop(96, 150, 214, rim);
    ba_rimtop(46, 236, 132, rim);
    ba_rimtop(214, 288, 330, rim);
    ba_rimtop(330, 352, 396, rim);
    for (i = 100; i < 210; i += 16) ba_fill(i, 142, i + 7, 150, body);   /* 城垛 */
    ba_fill(0, 214, 46, BA_HOR + 2, body);

    // ---- 右侧：低墙 + 塔 + 高尖塔
    ba_fill(1528, 330, 1680, BA_HOR + 2, body);
    ba_fill(1680, 196, 1792, BA_HOR + 2, body);
    ba_fill(1792, 262, BA_W, BA_HOR + 2, body);
    ba_fill(1848, 118, 1892, BA_HOR + 2, body);
    ba_tri(1870, 70, 22, 118, body);
    ba_rimtop(1528, 330, 1680, rim);
    ba_rimtop(1680, 196, 1792, rim);
    ba_rimtop(1792, 262, BA_W, rim);
    ba_rimtop(1848, 118, 1892, rim);
    for (i = 1684; i < 1788; i += 16) ba_fill(i, 188, i + 7, 196, body);

    // ---- 破口（让轮廓不是一条直线）
    ba_fill(48, 236, 66, 250, dark);
    ba_fill(1700, 196, 1722, 212, dark);
    ba_fill(1806, 262, 1830, 278, dark);
    ba_fill(300, 288, 320, 300, dark);

    // ---- 拱窗（露出压暗的天空）
    ba_arch(250, 344, 26, BA_HOR + 2, 190);
    ba_arch(306, 352, 22, BA_HOR + 2, 180);
    ba_arch(155, 246, 14, 330, 205);
    ba_arch(166, 300, 9, 352, 205);
    ba_arch(1580, 388, 22, BA_HOR + 2, 180);
    ba_arch(1740, 318, 16, BA_HOR + 2, 195);
    ba_arch(1868, 190, 9, 250, 210);

    // ---- 塔底的碎石堆
    ba_rng_state = 0xBEEF77u;
    for (i = 0; i < 22; i++) {
        int bx = -10 + ba_rnd(BA_W + 20);
        int bw = 12 + ba_rnd(38);
        int bh = 2 + ba_rnd(9);
        ba_fill(bx, BA_HOR - bh, bx + bw, BA_HOR + 2, body);
    }
}

// ---------------------------------------------------------------- 中央残门（消失点）
static void ba_center_gate(void)
{
    uint16_t body = ba_rgb(26, 19, 26);
    uint16_t rim = ba_rgb(38, 29, 36);
    ba_fill(872, 398, 924, BA_HOR + 2, body);
    ba_fill(996, 398, 1048, BA_HOR + 2, body);
    ba_fill(924, 390, 996, 402, body);
    ba_fill(940, 382, 980, 390, body);
    ba_rimtop(872, 398, 924, rim);
    ba_rimtop(996, 398, 1048, rim);
    ba_rimtop(924, 390, 996, rim);
    ba_rimtop(940, 382, 980, rim);
    /* 缺口：让残门看起来是断的 */
    ba_fill(956, 382, 964, 402, ba_rgb(52, 36, 46));
}

// ---------------------------------------------------------------- 地平线雾带
// 把中景底部、远景天际线和远地面糅在一起（大气透视的核心）
static void ba_haze_band(void)
{
    int y, x;
    int fr = BA_FOGR >> 3;
    int fg = BA_FOGG >> 2;
    int fb = BA_FOGB >> 3;
    for (y = 402; y < 506; y++) {
        int d = (y > 452) ? (y - 452) : (452 - y);
        int w;
        volatile uint16_t *row;
        if (d >= 50) continue;
        w = (50 - d) * 2;
        row = BA_ROW_W(y);
        for (x = 0; x < BA_W; x++) {
            uint16_t c = row[x];
            int r = (int)((c >> 11) & 31u);
            int g = (int)((c >> 5) & 63u);
            int b = (int)(c & 31u);
            r += ((fr - r) * w) >> 8;
            g += ((fg - g) * w) >> 8;
            b += ((fb - b) * w) >> 8;
            row[x] = (uint16_t)(((uint32_t)r << 11) | ((uint32_t)g << 5) | (uint32_t)b);
        }
    }
}

// ---------------------------------------------------------------- main entry
static void bg_build_art(void)
{
    /* Flat single-colour background, written by the CPU (engine commands are
       not reliable this early in boot). Same colour the erase FILL uses. */
    {
        uint32_t yy;
        volatile uint16_t *base = (volatile uint16_t *)BG_ART_BASE;
        for (yy = 0; yy < GH; yy++) {
            volatile uint16_t *row = base + yy * (BG_STRIDE / 2u);
            uint32_t xx;
            for (xx = 0; xx < GW; xx++) row[xx] = G_BG;
        }
    }
    return;

    ba_rng_state = 0x5EED1234u;

    ba_hud();            /* HUD 平色带 + 分隔线 */
    ba_sky();            /* 夜空渐变 + 薄云（含地平线霭光） */
    ba_moon();           /* 血月 */
    ba_stars();          /* 星点 */
    ba_ground();         /* 透视石砖广场 */
    ba_far_skyline();    /* 远景废墟天际线 */
    ba_center_gate();    /* 消失点上的残门 */
    ba_mid_ruins();      /* 左右框景断墙 + 拱窗 */
    ba_haze_band();      /* 地平线雾：把天地糅在一起 */
}

#endif // BG_ART_H
