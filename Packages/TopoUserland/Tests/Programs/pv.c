// preadv2 and pwritev2 at offset -1 (the current position) on a pipe, with the
// offset's high register as Zig's std passes it on a 64-bit target (0) and as
// musl does (the offset's top half, -1), printed as one line for
// GuestStreamOffsetTests. A 64-bit kernel reads the
// offset from the low register alone, so all four are stream writes and reads.
// Bun writes its stdout with pwritev2(fd, iov, 1, -1, RWF_NOWAIT) through Zig,
// and a pipe refused it as a positional write at 4 GiB.
//
// Freestanding and static, so it runs on the bare minirootfs. `pv` beside this
// file is its build, made with Homebrew's llvm and lld:
//
//   llvm=$(brew --prefix llvm)/bin
//   $llvm/clang --target=aarch64-linux-gnu -O1 -ffreestanding -nostdlib -static \
//     -fno-stack-protector -fuse-ld=lld --ld-path=$(brew --prefix lld)/bin/ld.lld \
//     -o pv pv.c && $llvm/llvm-strip pv

typedef long L;

static L sc(L n, L a, L b, L c, L d, L e, L f) {
    register L x8 __asm__("x8") = n;
    register L x0 __asm__("x0") = a;
    register L x1 __asm__("x1") = b;
    register L x2 __asm__("x2") = c;
    register L x3 __asm__("x3") = d;
    register L x4 __asm__("x4") = e;
    register L x5 __asm__("x5") = f;
    __asm__ volatile("svc 0" : "+r"(x0) : "r"(x8), "r"(x1), "r"(x2), "r"(x3), "r"(x4), "r"(x5) : "memory");
    return x0;
}

enum { PIPE2 = 59, WRITE = 64, EXIT_GROUP = 94, PREADV2 = 286, PWRITEV2 = 287 };
enum { RWF_NOWAIT = 8 };

static void put(const char *s) { L n = 0; while (s[n]) n++; sc(WRITE, 1, (L)s, n, 0, 0, 0); }

static void num(L v) {
    char b[24]; int i = 23; b[i] = 0;
    int neg = v < 0; if (neg) v = -v;
    do { b[--i] = '0' + v % 10; v /= 10; } while (v);
    if (neg) b[--i] = '-';
    put(b + i);
}

struct iov { const void *base; L len; };

// One write and one read through a fresh pipe, both at offset -1 with `high`
// in the high register; prints what each returned and whether the bytes match.
static void round(const char *name, L high) {
    int fds[2];
    sc(PIPE2, (L)fds, 0, 0, 0, 0, 0);
    struct iov out = {"topo", 4};
    L w = sc(PWRITEV2, fds[1], (L)&out, 1, -1, high, RWF_NOWAIT);
    char got[8] = {0};
    struct iov in = {got, sizeof got};
    L r = sc(PREADV2, fds[0], (L)&in, 1, -1, high, 0);
    put(name); put(" write="); num(w); put(" read="); num(r);
    put(r == 4 && got[0] == 't' && got[3] == 'o' ? " same" : " differ");
}

void _start(void) {
    round("zig", 0);
    put(" ");
    round("musl", -1);
    put("\n");
    sc(EXIT_GROUP, 0, 0, 0, 0, 0, 0);
}
