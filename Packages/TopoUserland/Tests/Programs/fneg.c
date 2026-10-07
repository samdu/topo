// FNEG (vector, half-precision) on both arrangements: the sign bit of each
// 16-bit element flipped and nothing else, whatever the element holds. The
// input has both zeros, both infinities, a quiet and a signalling NaN and two
// ordinary numbers. Claude Code reaches FNEG .8h to build a constant, in code
// compiled for half-precision floating point. Neither arrangement has an
// unallocated form. The build and the host build are in simd.h.

#include "simd.h"

static const U8 input[16] = {
    0x00, 0x00, 0x00, 0x80, 0x00, 0x7c, 0x00, 0xfc,
    0x01, 0x7e, 0x01, 0xfc, 0x81, 0x00, 0x34, 0xb2,
};

#define FP16 ".arch_extension fp16\n"
CASE(fneg_4h, FP16 "fneg v0.4h, v1.4h")
CASE(fneg_8h, FP16 "fneg v0.8h, v1.8h")
CASE(fneg_8h_in_place, FP16 "mov v0.16b, v1.16b\nfneg v0.8h, v0.8h")

static const struct simd_case cases[] = {
    {"fneg 4h", fneg_4h}, {"fneg 8h", fneg_8h}, {"fneg 8h in place", fneg_8h_in_place},
};

static void report(void) { LINES(cases, input, input); }

#ifndef HOST
static void traps(void) {}
#endif
