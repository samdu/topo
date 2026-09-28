// SQABS and SQNEG (vector) on every arrangement, printed one line per
// instruction for GuestSimdTests: the destination's 16 bytes in hex, with the
// destination filled with 0xaa beforehand, so a 64-bit form shows its upper
// half zeroed. The input holds 0, 1, -1 and the byte, halfword, word and
// doubleword minimums (each saturates to its maximum). ugrep's line numbering
// reaches SQABS. Last it runs SQABS on the 1D arrangement, which is
// unallocated and must raise SIGILL, so the program ends with status 132.
//
// Freestanding and static, so it runs on the bare minirootfs. `sqabs` beside
// this file is its build, made with Homebrew's llvm and lld:
//
//   llvm=$(brew --prefix llvm)/bin
//   $llvm/clang --target=aarch64-linux-gnu -O1 -ffreestanding -nostdlib -static \
//     -fno-stack-protector -fuse-ld=lld --ld-path=$(brew --prefix lld)/bin/ld.lld \
//     -o sqabs sqabs.c && $llvm/llvm-strip sqabs
//
// Built for the host with -DHOST (`clang -DHOST -O1 -o sqabs-host sqabs.c`) it
// prints the same lines from the Mac's own NEON, which is where the test's
// expected output comes from.

typedef long L;
typedef unsigned char U8;

static const U8 input[16] = {
    0x00, 0x01, 0xff, 0x80, 0x7f, 0x81, 0xff, 0xff,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x80,
};

#define CASE(name, text) \
    static void name(U8 *out) { \
        __asm__ volatile("ldr q1, [%1]\nmovi v0.16b, #0xaa\n" text "\nstr q0, [%0]\n" \
                         : : "r"(out), "r"(input) : "v0", "v1", "memory"); \
    }

CASE(sqabs_8b, "sqabs v0.8b, v1.8b")
CASE(sqabs_16b, "sqabs v0.16b, v1.16b")
CASE(sqabs_4h, "sqabs v0.4h, v1.4h")
CASE(sqabs_8h, "sqabs v0.8h, v1.8h")
CASE(sqabs_2s, "sqabs v0.2s, v1.2s")
CASE(sqabs_4s, "sqabs v0.4s, v1.4s")
CASE(sqabs_2d, "sqabs v0.2d, v1.2d")
CASE(sqneg_8b, "sqneg v0.8b, v1.8b")
CASE(sqneg_16b, "sqneg v0.16b, v1.16b")
CASE(sqneg_4h, "sqneg v0.4h, v1.4h")
CASE(sqneg_8h, "sqneg v0.8h, v1.8h")
CASE(sqneg_2s, "sqneg v0.2s, v1.2s")
CASE(sqneg_4s, "sqneg v0.4s, v1.4s")
CASE(sqneg_2d, "sqneg v0.2d, v1.2d")

static const struct { const char *name; void (*run)(U8 *); } cases[] = {
    {"sqabs 8b", sqabs_8b}, {"sqabs 16b", sqabs_16b}, {"sqabs 4h", sqabs_4h},
    {"sqabs 8h", sqabs_8h}, {"sqabs 2s", sqabs_2s}, {"sqabs 4s", sqabs_4s},
    {"sqabs 2d", sqabs_2d}, {"sqneg 8b", sqneg_8b}, {"sqneg 16b", sqneg_16b},
    {"sqneg 4h", sqneg_4h}, {"sqneg 8h", sqneg_8h}, {"sqneg 2s", sqneg_2s},
    {"sqneg 4s", sqneg_4s}, {"sqneg 2d", sqneg_2d},
};

#ifdef HOST
#include <unistd.h>
static void out(const char *s, L n) { write(1, s, n); }
#else
static void out(const char *s, L n) {
    register L x8 __asm__("x8") = 64; // write
    register L x0 __asm__("x0") = 1;
    register L x1 __asm__("x1") = (L)s;
    register L x2 __asm__("x2") = n;
    __asm__ volatile("svc 0" : "+r"(x0) : "r"(x8), "r"(x1), "r"(x2) : "memory");
}
static void leave(void) {
    register L x8 __asm__("x8") = 94; // exit_group
    register L x0 __asm__("x0") = 0;
    __asm__ volatile("svc 0" : : "r"(x8), "r"(x0));
    for (;;) {}
}
#endif

static void line(const char *name, const U8 *v) {
    static const char hex[] = "0123456789abcdef";
    char b[64];
    L n = 0;
    while (name[n]) { b[n] = name[n]; n++; }
    b[n++] = ' ';
    for (int i = 0; i < 16; i++) { b[n++] = hex[v[i] >> 4]; b[n++] = hex[v[i] & 15]; }
    b[n++] = '\n';
    out(b, n);
}

static void report(void) {
    for (unsigned i = 0; i < sizeof(cases) / sizeof(cases[0]); i++) {
        U8 v[16];
        cases[i].run(v);
        line(cases[i].name, v);
    }
}

#ifdef HOST
int main(void) { report(); return 0; }
#else
void _start(void) {
    report();
    __asm__ volatile(".inst 0x0ee07800"); // sqabs v0.1d, v0.1d: unallocated
    leave();
}
#endif
