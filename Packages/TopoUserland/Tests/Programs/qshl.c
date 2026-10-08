// SQSHLU and UQSHL (vector, by immediate) on every arrangement, at a shift of
// nothing, one bit, half the element and all but one bit of it. The input
// holds, at every element size, a negative element (SQSHLU's zero), a small
// one that a short shift leaves unsaturated and a large one that saturates, in
// both halves of the vector. Claude Code's pixel conversion reaches SQSHLU
// .8h and its Adler-32 UQSHL .4s. Then children run each instruction's 1D
// arrangement, which is unallocated, and the parent prints the signal each
// died of. The build and the host build are in simd.h.

#include "simd.h"

static const U8 input[16] = {
    0x01, 0x00, 0x00, 0x00, 0xff, 0x7f, 0x80, 0x03,
    0x00, 0x00, 0x00, 0x80, 0x05, 0x00, 0x00, 0x80,
};

#define SHIFTS(X, op) \
    X(op, 8b, 0) X(op, 8b, 1) X(op, 8b, 4) X(op, 8b, 7) \
    X(op, 16b, 0) X(op, 16b, 1) X(op, 16b, 4) X(op, 16b, 7) \
    X(op, 4h, 0) X(op, 4h, 1) X(op, 4h, 8) X(op, 4h, 15) \
    X(op, 8h, 0) X(op, 8h, 1) X(op, 8h, 8) X(op, 8h, 15) \
    X(op, 2s, 0) X(op, 2s, 1) X(op, 2s, 16) X(op, 2s, 31) \
    X(op, 4s, 0) X(op, 4s, 1) X(op, 4s, 6) X(op, 4s, 31) \
    X(op, 2d, 0) X(op, 2d, 1) X(op, 2d, 32) X(op, 2d, 63)

#define DEFINE(op, arr, n) CASE(op##_##arr##_##n, #op " v0." #arr ", v1." #arr ", #" #n)
#define ENTRY(op, arr, n) {#op " " #arr " #" #n, op##_##arr##_##n},

SHIFTS(DEFINE, sqshlu)
SHIFTS(DEFINE, uqshl)
// The destination is the source, as the binary has it.
CASE(sqshlu_8h_8_in_place, "mov v0.16b, v1.16b\nsqshlu v0.8h, v0.8h, #8")
CASE(uqshl_4s_6_in_place, "mov v0.16b, v1.16b\nuqshl v0.4s, v0.4s, #6")

static const struct simd_case cases[] = {
    SHIFTS(ENTRY, sqshlu)
    {"sqshlu 8h #8 in place", sqshlu_8h_8_in_place},
    SHIFTS(ENTRY, uqshl)
    {"uqshl 4s #6 in place", uqshl_4s_6_in_place},
};

static void report(void) { LINES(cases, input, input); }

#ifndef HOST
static void traps(void) {
    TRAP("sqshlu 1d", 0x2f406400); // sqshlu v0.1d, v0.1d, #0
    TRAP("uqshl 1d", 0x2f407400);  // uqshl v0.1d, v0.1d, #0
}
#endif
