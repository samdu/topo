// LD1 and ST1 (single structure) on every halfword lane, printed one line per
// instruction for GuestSimdTests (patches/ish/0015-ld1-single-h-lane.patch).
// The lane of an H element is Q:S:size<1>, so each lane is its own encoding:
// a lane read from the wrong bits lands one element over and prints
// differently. A load fills one lane of v0 (filled with 0xaa beforehand) from
// the first halfword of the input; a store writes one lane of the input to a
// buffer filled with 0xaa. Each comes plain and post-indexed by #2, and a load
// once more post-indexed by a register, and LD2 once, for its second register.
// BoringSSL's ML-KEM NTT, vectorised, gathers with LD1 {Vt.H}[1..3]: with the
// lane wrong, TLS 1.3's X25519MLKEM768 share decrypts wrong.
//
// Then a child runs LD1 {Vt.H} with size<0> set, which is unallocated, and the
// parent prints the signal it died of; another does the same post-indexed;
// last the parent runs ST1 the same way, so the program ends with status 132.
// The build and the host build are in simd.h.

#include "simd.h"

static const U8 input[16] = {
    0x34, 0x12, 0x01, 0x80, 0xff, 0x7f, 0x00, 0x00,
    0x78, 0x56, 0xcd, 0xab, 0x11, 0x22, 0x33, 0x44,
};

// A load into v0, from the address in x9 (the input).
#define LOAD(name, text) \
    static void name(U8 *out, const U8 *a, const U8 *b) { \
        (void)b; \
        __asm__ volatile("ldr q1, [%1]\nmovi v0.16b, #0xaa\nmov x9, %1\nmov x10, #2\n" text "\nstr q0, [%0]\n" \
                         : : "r"(out), "r"(a) : "v0", "v1", "v3", "v4", "x9", "x10", "memory"); \
    }

// A store from v1 (the input) to out, filled with 0xaa beforehand, through x9.
#define STORE(name, text) \
    static void name(U8 *out, const U8 *a, const U8 *b) { \
        (void)b; \
        __asm__ volatile("ldr q1, [%1]\nmovi v0.16b, #0xaa\nstr q0, [%0]\nmov x9, %0\n" text "\n" \
                         : : "r"(out), "r"(a) : "v0", "v1", "x9", "memory"); \
    }

LOAD(ld_0, "ld1 {v0.h}[0], [x9]")
LOAD(ld_1, "ld1 {v0.h}[1], [x9]")
LOAD(ld_2, "ld1 {v0.h}[2], [x9]")
LOAD(ld_3, "ld1 {v0.h}[3], [x9]")
LOAD(ld_4, "ld1 {v0.h}[4], [x9]")
LOAD(ld_5, "ld1 {v0.h}[5], [x9]")
LOAD(ld_6, "ld1 {v0.h}[6], [x9]")
LOAD(ld_7, "ld1 {v0.h}[7], [x9]")
LOAD(ld_post_1, "ld1 {v0.h}[1], [x9], #2")
LOAD(ld_post_3, "ld1 {v0.h}[3], [x9], #2")
LOAD(ld_post_5, "ld1 {v0.h}[5], [x9], #2")
LOAD(ld_post_7, "ld1 {v0.h}[7], [x9], #2")
LOAD(ld_post_reg_6, "ld1 {v0.h}[6], [x9], x10")
LOAD(ld2_5, "movi v3.16b, #0xaa\nmovi v4.16b, #0xaa\nld2 {v3.h, v4.h}[5], [x9]\nmov v0.16b, v4.16b")
STORE(st_0, "st1 {v1.h}[0], [x9]")
STORE(st_1, "st1 {v1.h}[1], [x9]")
STORE(st_2, "st1 {v1.h}[2], [x9]")
STORE(st_3, "st1 {v1.h}[3], [x9]")
STORE(st_4, "st1 {v1.h}[4], [x9]")
STORE(st_5, "st1 {v1.h}[5], [x9]")
STORE(st_6, "st1 {v1.h}[6], [x9]")
STORE(st_7, "st1 {v1.h}[7], [x9]")
STORE(st_post_3, "st1 {v1.h}[3], [x9], #2")
STORE(st_post_6, "st1 {v1.h}[6], [x9], #2")

static const struct simd_case cases[] = {
    {"ld1 h[0]", ld_0}, {"ld1 h[1]", ld_1}, {"ld1 h[2]", ld_2}, {"ld1 h[3]", ld_3},
    {"ld1 h[4]", ld_4}, {"ld1 h[5]", ld_5}, {"ld1 h[6]", ld_6}, {"ld1 h[7]", ld_7},
    {"ld1 h[1] post", ld_post_1}, {"ld1 h[3] post", ld_post_3},
    {"ld1 h[5] post", ld_post_5}, {"ld1 h[7] post", ld_post_7},
    {"ld1 h[6] post x", ld_post_reg_6}, {"ld2 h[5] second", ld2_5},
    {"st1 h[0]", st_0}, {"st1 h[1]", st_1}, {"st1 h[2]", st_2}, {"st1 h[3]", st_3},
    {"st1 h[4]", st_4}, {"st1 h[5]", st_5}, {"st1 h[6]", st_6}, {"st1 h[7]", st_7},
    {"st1 h[3] post", st_post_3}, {"st1 h[6] post", st_post_6},
};

static void report(void) { LINES(cases, input, input); }

#ifndef HOST
static void traps(void) {
    TRAP("ld1 h size 1", 0x0d404400);      // ld1 {v0.h}[0], [x0] with size 01
    TRAP("ld1 h size 1 post", 0x0ddf4400); // the same, post-indexed by #2
    __asm__ volatile(".inst 0x0d004400");  // and st1 the same: unallocated
}
#endif
