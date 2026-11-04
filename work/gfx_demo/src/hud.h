// hud.h -- on-screen text for the demo.
//
// A 5x7 dot-matrix font drawn by the CPU straight into the back buffer.
// Deliberately not drawn with engine commands: one glyph would be dozens of
// fills, while the CPU can write a whole line in tens of microseconds. The HUD
// is also the only place the CPU writes pixels at all, so it is a fair test of
// "CPU can still do useful work while the engine draws".
#ifndef HUD_H
#define HUD_H

#include <stdint.h>

#define HUD_S    2u                 // dot scale: 5x7 becomes 10x14 pixels
#define HUD_CW   (6u * HUD_S)       // character cell, includes one dot gap
#define HUD_CH   (8u * HUD_S)

// Column-major 5x7 glyphs. Each byte is one column, bit 0 is the top row.
static const uint8_t HUD_DIG[10][5] = {
    {0x3E,0x51,0x49,0x45,0x3E}, {0x00,0x42,0x7F,0x40,0x00},
    {0x42,0x61,0x51,0x49,0x46}, {0x21,0x41,0x45,0x4B,0x31},
    {0x18,0x14,0x12,0x7F,0x10}, {0x27,0x45,0x45,0x45,0x39},
    {0x3C,0x4A,0x49,0x49,0x30}, {0x01,0x71,0x09,0x05,0x03},
    {0x36,0x49,0x49,0x49,0x36}, {0x06,0x49,0x49,0x29,0x1E}
};

static const uint8_t HUD_LET[26][5] = {
    {0x7E,0x11,0x11,0x11,0x7E}, {0x7F,0x49,0x49,0x49,0x36},  // A B
    {0x3E,0x41,0x41,0x41,0x22}, {0x7F,0x41,0x41,0x22,0x1C},  // C D
    {0x7F,0x49,0x49,0x49,0x41}, {0x7F,0x09,0x09,0x09,0x01},  // E F
    {0x3E,0x41,0x49,0x49,0x7A}, {0x7F,0x08,0x08,0x08,0x7F},  // G H
    {0x00,0x41,0x7F,0x41,0x00}, {0x20,0x40,0x41,0x3F,0x01},  // I J
    {0x7F,0x08,0x14,0x22,0x41}, {0x7F,0x40,0x40,0x40,0x40},  // K L
    {0x7F,0x02,0x0C,0x02,0x7F}, {0x7F,0x04,0x08,0x10,0x7F},  // M N
    {0x3E,0x41,0x41,0x41,0x3E}, {0x7F,0x09,0x09,0x09,0x06},  // O P
    {0x3E,0x41,0x51,0x21,0x5E}, {0x7F,0x09,0x19,0x29,0x46},  // Q R
    {0x46,0x49,0x49,0x49,0x31}, {0x01,0x01,0x7F,0x01,0x01},  // S T
    {0x3F,0x40,0x40,0x40,0x3F}, {0x1F,0x20,0x40,0x20,0x1F},  // U V
    {0x3F,0x40,0x38,0x40,0x3F}, {0x63,0x14,0x08,0x14,0x63},  // W X
    {0x07,0x08,0x70,0x08,0x07}, {0x61,0x51,0x49,0x45,0x43}   // Y Z
};

static const uint8_t *hud_glyph(char c)
{
    static const uint8_t sp[5] = {0,0,0,0,0};
    static const uint8_t co[5] = {0x00,0x36,0x36,0x00,0x00};
    static const uint8_t dt[5] = {0x00,0x60,0x60,0x00,0x00};
    static const uint8_t sl[5] = {0x20,0x10,0x08,0x04,0x02};
    static const uint8_t ds[5] = {0x08,0x08,0x08,0x08,0x08};
    static const uint8_t pc[5] = {0x00,0x00,0x5F,0x00,0x00};
    static const uint8_t pl[5] = {0x08,0x08,0x08,0x08,0x08};
    if (c >= '0' && c <= '9') return HUD_DIG[c - '0'];
    if (c >= 'A' && c <= 'Z') return HUD_LET[c - 'A'];
    if (c >= 'a' && c <= 'z') return HUD_LET[c - 'a'];
    switch (c) {
    case ':':  return co;
    case '.':  return dt;
    case '/':  return sl;
    case '-':  return ds;
    case '+':  return pl;
    case ' ':  return sp;
    default:   return pc;      // unknown characters become a visible box
    }
}

// One character at (x,y) in pixels, cell HUD_CW x HUD_CH.
static inline void hud_char(volatile uint16_t *fb, uint32_t pitch_px,
                            uint32_t x, uint32_t y, char c,
                            uint16_t fg, uint16_t bg)
{
    const uint8_t *g = hud_glyph(c);
    uint32_t col, row, dx, dy;
    for (col = 0; col < 6u; col++) {
        uint8_t bits = (col < 5u) ? g[col] : 0u;
        for (row = 0; row < 8u; row++) {
            uint16_t px = ((bits >> row) & 1u) ? fg : bg;
            for (dy = 0; dy < HUD_S; dy++) {
                volatile uint16_t *p = fb + (y + row * HUD_S + dy) * pitch_px
                                          + (x + col * HUD_S);
                for (dx = 0; dx < HUD_S; dx++) p[dx] = px;
            }
        }
    }
}

static inline void hud_text(volatile uint16_t *fb, uint32_t pitch_px,
                            uint32_t x, uint32_t y, const char *s,
                            uint16_t fg, uint16_t bg)
{
    while (*s) {
        hud_char(fb, pitch_px, x, y, *s++, fg, bg);
        x += HUD_CW;
    }
}

// Unsigned decimal with two optional fraction digits: v is value*10^frac.
static inline void hud_num(char *out, uint32_t v, uint32_t frac)
{
    uint32_t div = 1u, i = 0u;
    if (frac == 1u) div = 10u;
    if (frac == 2u) div = 100u;
    if (frac == 3u) div = 1000u;
    if (v >= div * 1000u) {
        out[i++] = (char)('0' + (v / (div * 1000u)) % 10u);
        out[i++] = (char)('0' + (v / (div * 100u)) % 10u);
        out[i++] = (char)('0' + (v / (div * 10u)) % 10u);
    } else if (v >= div * 100u) {
        out[i++] = (char)('0' + (v / (div * 100u)) % 10u);
        out[i++] = (char)('0' + (v / (div * 10u)) % 10u);
    } else if (v >= div * 10u) {
        out[i++] = (char)('0' + (v / (div * 10u)) % 10u);
    }
    out[i++] = (char)('0' + (v / div) % 10u);
    if (frac) {
        out[i++] = '.';
        if (frac >= 1u) out[i++] = (char)('0' + (v / (div / 10u)) % 10u);
        if (frac >= 2u) out[i++] = (char)('0' + (v % 10u));
    }
    out[i] = 0;
}

#endif
