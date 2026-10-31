// LD1–LD4 and ST1–ST4 (single structure) on halfword lanes, printed one line
// per instruction for GuestSimdTests (patches/ish/0015-ld1-single-h-lane.patch).
// The lane of an H element is Q:S:size<1>, so each lane is its own encoding:
// a lane read from the wrong bits lands one element over and prints
// differently. The input's eight halfwords are all different.
//
// A load fills one lane of v0 (filled with 0xaa beforehand) from the input's
// first halfword; a store writes one lane of the input to a buffer filled with
// 0xaa. Every lane comes plain, post-indexed by #2 and post-indexed by a
// register holding 2. A post-indexed case then goes through the address it
// wrote back, once more, four lanes over: a load takes the second halfword,
// a store writes the lane four over at the second, so an address not
// advanced puts the first halfword there instead. LD2–LD4 put each register's
// lane in a lane of v0; ST2–ST4 store from four rotations of the input.
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

// A load into v0 (and v3..v6 for LD2–LD4), from x9, the input; x10 holds 2.
#define LOAD(name, text) \
    static void name(U8 *out, const U8 *a, const U8 *b) { \
        (void)b; \
        __asm__ volatile("movi v0.16b, #0xaa\nmovi v3.16b, #0xaa\nmovi v4.16b, #0xaa\n" \
                         "movi v5.16b, #0xaa\nmovi v6.16b, #0xaa\nmov x9, %1\nmov x10, #2\n" \
                         text "\nstr q0, [%0]\n" \
                         : : "r"(out), "r"(a) : "v0", "v3", "v4", "v5", "v6", "x9", "x10", "memory"); \
    }

// A store to out, filled with 0xaa beforehand, through x9; v1 is the input and
// v3..v6 its rotations by 0, 2, 4 and 6 bytes; x10 holds 2.
#define STORE(name, text) \
    static void name(U8 *out, const U8 *a, const U8 *b) { \
        (void)b; \
        __asm__ volatile("ldr q1, [%1]\nmov v3.16b, v1.16b\next v4.16b, v1.16b, v1.16b, #2\n" \
                         "ext v5.16b, v1.16b, v1.16b, #4\next v6.16b, v1.16b, v1.16b, #6\n" \
                         "movi v0.16b, #0xaa\nstr q0, [%0]\nmov x9, %0\nmov x10, #2\n" text "\n" \
                         : : "r"(out), "r"(a) : "v0", "v1", "v3", "v4", "v5", "v6", "x9", "x10", "memory"); \
    }

LOAD(ld_0, "ld1 {v0.h}[0], [x9]")
LOAD(ld_1, "ld1 {v0.h}[1], [x9]")
LOAD(ld_2, "ld1 {v0.h}[2], [x9]")
LOAD(ld_3, "ld1 {v0.h}[3], [x9]")
LOAD(ld_4, "ld1 {v0.h}[4], [x9]")
LOAD(ld_5, "ld1 {v0.h}[5], [x9]")
LOAD(ld_6, "ld1 {v0.h}[6], [x9]")
LOAD(ld_7, "ld1 {v0.h}[7], [x9]")
LOAD(ld_post_0, "ld1 {v0.h}[0], [x9], #2\nld1 {v0.h}[4], [x9]")
LOAD(ld_post_1, "ld1 {v0.h}[1], [x9], #2\nld1 {v0.h}[5], [x9]")
LOAD(ld_post_2, "ld1 {v0.h}[2], [x9], #2\nld1 {v0.h}[6], [x9]")
LOAD(ld_post_3, "ld1 {v0.h}[3], [x9], #2\nld1 {v0.h}[7], [x9]")
LOAD(ld_post_4, "ld1 {v0.h}[4], [x9], #2\nld1 {v0.h}[0], [x9]")
LOAD(ld_post_5, "ld1 {v0.h}[5], [x9], #2\nld1 {v0.h}[1], [x9]")
LOAD(ld_post_6, "ld1 {v0.h}[6], [x9], #2\nld1 {v0.h}[2], [x9]")
LOAD(ld_post_7, "ld1 {v0.h}[7], [x9], #2\nld1 {v0.h}[3], [x9]")
LOAD(ld_reg_0, "ld1 {v0.h}[0], [x9], x10\nld1 {v0.h}[4], [x9]")
LOAD(ld_reg_1, "ld1 {v0.h}[1], [x9], x10\nld1 {v0.h}[5], [x9]")
LOAD(ld_reg_2, "ld1 {v0.h}[2], [x9], x10\nld1 {v0.h}[6], [x9]")
LOAD(ld_reg_3, "ld1 {v0.h}[3], [x9], x10\nld1 {v0.h}[7], [x9]")
LOAD(ld_reg_4, "ld1 {v0.h}[4], [x9], x10\nld1 {v0.h}[0], [x9]")
LOAD(ld_reg_5, "ld1 {v0.h}[5], [x9], x10\nld1 {v0.h}[1], [x9]")
LOAD(ld_reg_6, "ld1 {v0.h}[6], [x9], x10\nld1 {v0.h}[2], [x9]")
LOAD(ld_reg_7, "ld1 {v0.h}[7], [x9], x10\nld1 {v0.h}[3], [x9]")
LOAD(ld2_5, "ld2 {v3.h, v4.h}[5], [x9]\nmov v0.h[0], v3.h[5]\nmov v0.h[1], v4.h[5]")
LOAD(ld3_3, "ld3 {v3.h, v4.h, v5.h}[3], [x9]\nmov v0.h[0], v3.h[3]\nmov v0.h[1], v4.h[3]\nmov v0.h[2], v5.h[3]")
LOAD(ld4_7, "ld4 {v3.h, v4.h, v5.h, v6.h}[7], [x9]\nmov v0.h[0], v3.h[7]\nmov v0.h[1], v4.h[7]\nmov v0.h[2], v5.h[7]\nmov v0.h[3], v6.h[7]")
LOAD(ld2_0, "ld2 {v3.h, v4.h}[0], [x9]\nmov v0.h[0], v3.h[0]\nmov v0.h[1], v4.h[0]")
LOAD(ld3_6, "ld3 {v3.h, v4.h, v5.h}[6], [x9]\nmov v0.h[0], v3.h[6]\nmov v0.h[1], v4.h[6]\nmov v0.h[2], v5.h[6]")
LOAD(ld4_1, "ld4 {v3.h, v4.h, v5.h, v6.h}[1], [x9]\nmov v0.h[0], v3.h[1]\nmov v0.h[1], v4.h[1]\nmov v0.h[2], v5.h[1]\nmov v0.h[3], v6.h[1]")
STORE(st_0, "st1 {v1.h}[0], [x9]")
STORE(st_1, "st1 {v1.h}[1], [x9]")
STORE(st_2, "st1 {v1.h}[2], [x9]")
STORE(st_3, "st1 {v1.h}[3], [x9]")
STORE(st_4, "st1 {v1.h}[4], [x9]")
STORE(st_5, "st1 {v1.h}[5], [x9]")
STORE(st_6, "st1 {v1.h}[6], [x9]")
STORE(st_7, "st1 {v1.h}[7], [x9]")
STORE(st_post_0, "st1 {v1.h}[0], [x9], #2\nst1 {v1.h}[4], [x9]")
STORE(st_post_1, "st1 {v1.h}[1], [x9], #2\nst1 {v1.h}[5], [x9]")
STORE(st_post_2, "st1 {v1.h}[2], [x9], #2\nst1 {v1.h}[6], [x9]")
STORE(st_post_3, "st1 {v1.h}[3], [x9], #2\nst1 {v1.h}[7], [x9]")
STORE(st_post_4, "st1 {v1.h}[4], [x9], #2\nst1 {v1.h}[0], [x9]")
STORE(st_post_5, "st1 {v1.h}[5], [x9], #2\nst1 {v1.h}[1], [x9]")
STORE(st_post_6, "st1 {v1.h}[6], [x9], #2\nst1 {v1.h}[2], [x9]")
STORE(st_post_7, "st1 {v1.h}[7], [x9], #2\nst1 {v1.h}[3], [x9]")
STORE(st_reg_0, "st1 {v1.h}[0], [x9], x10\nst1 {v1.h}[4], [x9]")
STORE(st_reg_1, "st1 {v1.h}[1], [x9], x10\nst1 {v1.h}[5], [x9]")
STORE(st_reg_2, "st1 {v1.h}[2], [x9], x10\nst1 {v1.h}[6], [x9]")
STORE(st_reg_3, "st1 {v1.h}[3], [x9], x10\nst1 {v1.h}[7], [x9]")
STORE(st_reg_4, "st1 {v1.h}[4], [x9], x10\nst1 {v1.h}[0], [x9]")
STORE(st_reg_5, "st1 {v1.h}[5], [x9], x10\nst1 {v1.h}[1], [x9]")
STORE(st_reg_6, "st1 {v1.h}[6], [x9], x10\nst1 {v1.h}[2], [x9]")
STORE(st_reg_7, "st1 {v1.h}[7], [x9], x10\nst1 {v1.h}[3], [x9]")
STORE(st2_1, "st2 {v3.h, v4.h}[1], [x9]")
STORE(st3_6, "st3 {v3.h, v4.h, v5.h}[6], [x9]")
STORE(st4_3, "st4 {v3.h, v4.h, v5.h, v6.h}[3], [x9]")
STORE(st2_4, "st2 {v3.h, v4.h}[4], [x9]")
STORE(st3_2, "st3 {v3.h, v4.h, v5.h}[2], [x9]")
STORE(st4_7, "st4 {v3.h, v4.h, v5.h, v6.h}[7], [x9]")
LOAD(ld4_post_5, "ld4 {v3.h, v4.h, v5.h, v6.h}[5], [x9], #8\nld1 {v0.h}[4], [x9]\nmov v0.h[0], v3.h[5]\nmov v0.h[1], v4.h[5]\nmov v0.h[2], v5.h[5]\nmov v0.h[3], v6.h[5]")
STORE(st3_post_7, "st3 {v3.h, v4.h, v5.h}[7], [x9], #6\nst1 {v1.h}[0], [x9]")

static const struct simd_case cases[] = {
    {"ld1 h[0]", ld_0},
    {"ld1 h[1]", ld_1},
    {"ld1 h[2]", ld_2},
    {"ld1 h[3]", ld_3},
    {"ld1 h[4]", ld_4},
    {"ld1 h[5]", ld_5},
    {"ld1 h[6]", ld_6},
    {"ld1 h[7]", ld_7},
    {"ld1 h[0] post", ld_post_0},
    {"ld1 h[1] post", ld_post_1},
    {"ld1 h[2] post", ld_post_2},
    {"ld1 h[3] post", ld_post_3},
    {"ld1 h[4] post", ld_post_4},
    {"ld1 h[5] post", ld_post_5},
    {"ld1 h[6] post", ld_post_6},
    {"ld1 h[7] post", ld_post_7},
    {"ld1 h[0] post x", ld_reg_0},
    {"ld1 h[1] post x", ld_reg_1},
    {"ld1 h[2] post x", ld_reg_2},
    {"ld1 h[3] post x", ld_reg_3},
    {"ld1 h[4] post x", ld_reg_4},
    {"ld1 h[5] post x", ld_reg_5},
    {"ld1 h[6] post x", ld_reg_6},
    {"ld1 h[7] post x", ld_reg_7},
    {"ld2 h[5]", ld2_5},
    {"ld3 h[3]", ld3_3},
    {"ld4 h[7]", ld4_7},
    {"ld2 h[0]", ld2_0},
    {"ld3 h[6]", ld3_6},
    {"ld4 h[1]", ld4_1},
    {"st1 h[0]", st_0},
    {"st1 h[1]", st_1},
    {"st1 h[2]", st_2},
    {"st1 h[3]", st_3},
    {"st1 h[4]", st_4},
    {"st1 h[5]", st_5},
    {"st1 h[6]", st_6},
    {"st1 h[7]", st_7},
    {"st1 h[0] post", st_post_0},
    {"st1 h[1] post", st_post_1},
    {"st1 h[2] post", st_post_2},
    {"st1 h[3] post", st_post_3},
    {"st1 h[4] post", st_post_4},
    {"st1 h[5] post", st_post_5},
    {"st1 h[6] post", st_post_6},
    {"st1 h[7] post", st_post_7},
    {"st1 h[0] post x", st_reg_0},
    {"st1 h[1] post x", st_reg_1},
    {"st1 h[2] post x", st_reg_2},
    {"st1 h[3] post x", st_reg_3},
    {"st1 h[4] post x", st_reg_4},
    {"st1 h[5] post x", st_reg_5},
    {"st1 h[6] post x", st_reg_6},
    {"st1 h[7] post x", st_reg_7},
    {"st2 h[1]", st2_1},
    {"st3 h[6]", st3_6},
    {"st4 h[3]", st4_3},
    {"st2 h[4]", st2_4},
    {"st3 h[2]", st3_2},
    {"st4 h[7]", st4_7},
    {"ld4 h[5] post", ld4_post_5},
    {"st3 h[7] post", st3_post_7},
};

static void report(void) { LINES(cases, input, input); }

#ifndef HOST
static void traps(void) {
    TRAP("ld1 h size 1", 0x0d404400);      // ld1 {v0.h}[0], [x0] with size 01
    TRAP("ld1 h size 1 post", 0x0ddf4400); // the same, post-indexed by #2
    __asm__ volatile(".inst 0x0d004400");  // and st1 the same: unallocated
}
#endif
