// SCVTF and UCVTF (vector, fixed-point) on the single- and double-precision
// arrangements, at one fractional bit, at some in the middle and at as many as
// the element has bits. The input's elements each take more bits than their
// result's mantissa holds, so every conversion rounds, and they are positive
// and negative at both sizes, so the two instructions differ. Claude Code
// reaches SCVTF .2d #15 and UCVTF .2d #16. Then a child runs SCVTF with an
// 8-bit element, which is unallocated, and the parent prints the signal it
// died of; last the parent runs UCVTF on the 1D arrangement, unallocated too,
// so the program ends with status 132. The build and the host build are in
// simd.h.

#include "simd.h"

static const U8 input[16] = {
    0x03, 0x00, 0x00, 0x00, 0xff, 0xff, 0xff, 0x7f,
    0x81, 0xff, 0xff, 0xff, 0x01, 0x00, 0x00, 0x80,
};

#define FBITS(X, op) \
    X(op, 2s, 1) X(op, 2s, 16) X(op, 2s, 32) \
    X(op, 4s, 1) X(op, 4s, 16) X(op, 4s, 32) \
    X(op, 2d, 1) X(op, 2d, 15) X(op, 2d, 16) X(op, 2d, 33) X(op, 2d, 64)

#define DEFINE(op, arr, n) CASE(op##_##arr##_##n, #op " v0." #arr ", v1." #arr ", #" #n)
#define ENTRY(op, arr, n) {#op " " #arr " #" #n, op##_##arr##_##n},

FBITS(DEFINE, scvtf)
FBITS(DEFINE, ucvtf)

static const struct simd_case cases[] = { FBITS(ENTRY, scvtf) FBITS(ENTRY, ucvtf) };

static void report(void) { LINES(cases, input, input); }

#ifndef HOST
static void traps(void) {
    TRAP("scvtf 8b", 0x0f0fe400);          // immh 0001: no 8-bit floating point
    __asm__ volatile(".inst 0x2f40e400"); // ucvtf v0.1d, v0.1d, #64: unallocated
}
#endif
