// What the SIMD programs beside this share (qshl.c, cvtf.c, udot.c, fneg.c):
// a line of output per instruction for GuestSimdTests, and a child to run an
// unallocated encoding in. Each program defines `report`, which prints its
// lines, and `traps`, which runs its unallocated encodings.
//
// Freestanding and static, so a program runs on the bare minirootfs. The file
// named for each .c beside it is its build, made with Homebrew's llvm and lld:
//
//   llvm=$(brew --prefix llvm)/bin
//   $llvm/clang --target=aarch64-linux-gnu -O1 -ffreestanding -nostdlib -static \
//     -fno-stack-protector -fuse-ld=lld --ld-path=$(brew --prefix lld)/bin/ld.lld \
//     -o qshl qshl.c && $llvm/llvm-strip qshl
//
// Built for the host with -DHOST (`clang -DHOST -O1 -o qshl-host qshl.c`) it
// prints the same lines from the Mac's own NEON, which is where the test's
// expected output comes from. The host build runs no unallocated encoding.

typedef long L;
typedef unsigned char U8;

// One instruction: v1 and v2 are the two inputs, and v0, the destination, is
// filled with 0xaa beforehand, so a 64-bit form shows its upper half zeroed.
#define CASE(name, text) \
    static void name(U8 *out, const U8 *a, const U8 *b) { \
        __asm__ volatile("ldr q1, [%1]\nldr q2, [%2]\nmovi v0.16b, #0xaa\n" text "\nstr q0, [%0]\n" \
                         : : "r"(out), "r"(a), "r"(b) : "v0", "v1", "v2", "memory"); \
    }

struct simd_case { const char *name; void (*run)(U8 *, const U8 *, const U8 *); };

#ifdef HOST
#include <unistd.h>
static void out(const char *s, L n) { write(1, s, n); }
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
static void out(const char *s, L n) { sys(64 /* write */, 1, (L)s, n, 0); }
static void leave(void) {
    sys(94 /* exit_group */, 0, 0, 0, 0);
    for (;;) {}
}
#endif

static L put(char *b, L n, const char *s) {
    while (*s) b[n++] = *s++;
    return n;
}

static void line(const char *name, const U8 *v) {
    static const char hex[] = "0123456789abcdef";
    char b[96];
    L n = put(b, 0, name);
    b[n++] = ' ';
    for (int i = 0; i < 16; i++) { b[n++] = hex[v[i] >> 4]; b[n++] = hex[v[i] & 15]; }
    b[n++] = '\n';
    out(b, n);
}

static void lines(const struct simd_case *cases, unsigned count, const U8 *a, const U8 *b) {
    for (unsigned i = 0; i < count; i++) {
        U8 v[16];
        cases[i].run(v, a, b);
        line(cases[i].name, v);
    }
}
#define LINES(cases, a, b) lines(cases, sizeof(cases) / sizeof(cases[0]), a, b)

static void report(void);

#ifdef HOST
int main(void) { report(); return 0; }
#else
// Runs one encoding in a child and prints the signal the child died of, or
// that it ran: an unallocated encoding is SIGILL.
#define TRAP(name, word) do { \
        L child = sys(220 /* clone */, 17 /* SIGCHLD */, 0, 0, 0); \
        if (child == 0) { __asm__ volatile(".inst " #word); leave(); } \
        int status = 0; \
        sys(260 /* wait4 */, child, (L)&status, 0, 0); \
        char b[64]; \
        L n = put(b, 0, name); \
        n = put(b, n, (status & 0x7f) == 4 ? " SIGILL\n" : " ran\n"); \
        out(b, n); \
    } while (0)

static void traps(void);

void _start(void) {
    report();
    traps();
    leave();
}
#endif
