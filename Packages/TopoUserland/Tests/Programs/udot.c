// UDOT (vector) on both arrangements: each 32-bit element of the destination
// gains the sum of four byte products. The inputs hold 0xff against 0xff, the
// largest product, in both halves, and the destination starts at 0xaa in every
// byte, then at all ones, so a sum wraps, then as one of the sources. Claude
// Code's Adler-32 has UDOT .4s behind the dot-product feature. Then a child
// runs the encoding with 8-bit sums, which is unallocated, and the parent
// prints the signal it died of; last the parent runs the one with 64-bit sums,
// unallocated too, so the program ends with status 132. The build and the host
// build are in simd.h.

#include "simd.h"

static const U8 a[16] = {
    0xff, 0xff, 0xff, 0xff, 0x01, 0x02, 0x03, 0x04,
    0x80, 0x00, 0x7f, 0xff, 0xff, 0xff, 0xff, 0xff,
};
static const U8 b[16] = {
    0xff, 0xff, 0xff, 0xff, 0x05, 0x06, 0x07, 0x08,
    0x80, 0xff, 0x02, 0x01, 0xff, 0x00, 0xff, 0x10,
};

#define DOT ".arch_extension dotprod\n"
CASE(udot_2s, DOT "udot v0.2s, v1.8b, v2.8b")
CASE(udot_4s, DOT "udot v0.4s, v1.16b, v2.16b")
CASE(udot_2s_wraps, DOT "movi v0.2d, #0xffffffffffffffff\nudot v0.2s, v1.8b, v2.8b")
CASE(udot_4s_wraps, DOT "movi v0.2d, #0xffffffffffffffff\nudot v0.4s, v1.16b, v2.16b")
CASE(udot_4s_onto_n, DOT "mov v0.16b, v1.16b\nudot v0.4s, v0.16b, v2.16b")
CASE(udot_4s_onto_m, DOT "mov v0.16b, v2.16b\nudot v0.4s, v1.16b, v0.16b")

static const struct simd_case cases[] = {
    {"udot 2s", udot_2s}, {"udot 4s", udot_4s},
    {"udot 2s wraps", udot_2s_wraps}, {"udot 4s wraps", udot_4s_wraps},
    {"udot 4s onto n", udot_4s_onto_n}, {"udot 4s onto m", udot_4s_onto_m},
};

static void report(void) { LINES(cases, a, b); }

#ifndef HOST
static void traps(void) {
    TRAP("udot size 0", 0x6e029420);      // udot's encoding with size 00
    __asm__ volatile(".inst 0x6ec29420"); // and with size 11: unallocated
}
#endif
