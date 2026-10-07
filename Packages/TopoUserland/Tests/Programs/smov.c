// SMOV (to general) on every element size and both register widths, printed
// one line per instruction for GuestSimdTests: the destination register's 64
// bits in hex, with the register filled with 0xaa beforehand, so a Wd form
// shows its upper half zeroed. The input holds a negative and a positive
// element at every size, in both halves of the vector, so an element read
// zero-extended, from the wrong half or at the wrong index prints differently.
// Bun 1.4's string search reaches SMOV Wd, Vn.H[0]. Then a child runs SMOV Wd
// on an S element, which is unallocated, and the parent prints the signal it
// died of; last the parent runs SMOV Xd on a D element, unallocated too, so
// the program ends with status 132.
//
// Freestanding and static, so it runs on the bare minirootfs. `smov` beside
// this file is its build, made with Homebrew's llvm and lld:
//
//   llvm=$(brew --prefix llvm)/bin
//   $llvm/clang --target=aarch64-linux-gnu -O1 -ffreestanding -nostdlib -static \
//     -fno-stack-protector -fuse-ld=lld --ld-path=$(brew --prefix lld)/bin/ld.lld \
//     -o smov smov.c && $llvm/llvm-strip smov
//
// Built for the host with -DHOST (`clang -DHOST -O1 -o smov-host smov.c`) it
// prints the same lines from the Mac's own NEON, which is where the test's
// expected output comes from.

typedef long L;
typedef unsigned long UL;
typedef unsigned char U8;

static const U8 input[16] = {
    0x00, 0x00, 0x00, 0x80, 0x01, 0xff, 0xff, 0x7f,
    0x7f, 0x80, 0x34, 0x12, 0x00, 0x00, 0x00, 0x80,
};

#define CASE(name, text) \
    static UL name(void) { \
        UL out; \
        __asm__ volatile("ldr q1, [%1]\nmov x9, #0xaaaaaaaaaaaaaaaa\n" text "\nmov %0, x9\n" \
                         : "=r"(out) : "r"(input) : "v1", "x9"); \
        return out; \
    }

CASE(w_b0, "smov w9, v1.b[0]")
CASE(w_b3, "smov w9, v1.b[3]")
CASE(w_b7, "smov w9, v1.b[7]")
CASE(w_b9, "smov w9, v1.b[9]")
CASE(w_b15, "smov w9, v1.b[15]")
CASE(w_h0, "smov w9, v1.h[0]")
CASE(w_h1, "smov w9, v1.h[1]")
CASE(w_h3, "smov w9, v1.h[3]")
CASE(w_h4, "smov w9, v1.h[4]")
CASE(w_h7, "smov w9, v1.h[7]")
CASE(x_b3, "smov x9, v1.b[3]")
CASE(x_b8, "smov x9, v1.b[8]")
CASE(x_b9, "smov x9, v1.b[9]")
CASE(x_h1, "smov x9, v1.h[1]")
CASE(x_h5, "smov x9, v1.h[5]")
CASE(x_h7, "smov x9, v1.h[7]")
CASE(x_s0, "smov x9, v1.s[0]")
CASE(x_s1, "smov x9, v1.s[1]")
CASE(x_s2, "smov x9, v1.s[2]")
CASE(x_s3, "smov x9, v1.s[3]")

static const struct { const char *name; UL (*run)(void); } cases[] = {
    {"smov w b[0]", w_b0}, {"smov w b[3]", w_b3}, {"smov w b[7]", w_b7}, {"smov w b[9]", w_b9},
    {"smov w b[15]", w_b15}, {"smov w h[0]", w_h0}, {"smov w h[1]", w_h1}, {"smov w h[3]", w_h3},
    {"smov w h[4]", w_h4}, {"smov w h[7]", w_h7}, {"smov x b[3]", x_b3}, {"smov x b[8]", x_b8},
    {"smov x b[9]", x_b9}, {"smov x h[1]", x_h1}, {"smov x h[5]", x_h5}, {"smov x h[7]", x_h7},
    {"smov x s[0]", x_s0}, {"smov x s[1]", x_s1}, {"smov x s[2]", x_s2}, {"smov x s[3]", x_s3},
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

static void line(const char *name, UL v) {
    static const char hex[] = "0123456789abcdef";
    char b[64];
    L n = 0;
    while (name[n]) { b[n] = name[n]; n++; }
    b[n++] = ' ';
    for (int i = 60; i >= 0; i -= 4) b[n++] = hex[(v >> i) & 15];
    b[n++] = '\n';
    out(b, n);
}

static void report(void) {
    for (unsigned i = 0; i < sizeof(cases) / sizeof(cases[0]); i++) line(cases[i].name, cases[i].run());
}

#ifdef HOST
int main(void) { report(); return 0; }
#else
static L sys(L n, L a, L b, L c, L d) {
    register L x8 __asm__("x8") = n;
    register L x0 __asm__("x0") = a;
    register L x1 __asm__("x1") = b;
    register L x2 __asm__("x2") = c;
    register L x3 __asm__("x3") = d;
    __asm__ volatile("svc 0" : "+r"(x0) : "r"(x8), "r"(x1), "r"(x2), "r"(x3) : "memory");
    return x0;
}

void _start(void) {
    report();
    L child = sys(220 /* clone */, 17 /* SIGCHLD */, 0, 0, 0);
    if (child == 0) {
        __asm__ volatile(".inst 0x0e042c00"); // smov w0, v0.s[0]: unallocated
        leave();
    }
    int status = 0;
    sys(260 /* wait4 */, child, (L)&status, 0, 0);
    out((status & 0x7f) == 4 ? "smov w s[0] SIGILL\n" : "smov w s[0] ran\n", (status & 0x7f) == 4 ? 19 : 16);
    __asm__ volatile(".inst 0x4e082c00"); // smov x0, v0.d[0]: unallocated
    leave();
}
#endif
