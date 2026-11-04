// nanosleep and clock_nanosleep with a timespec Linux refuses and with ones it
// takes, printed as one line of what each returned for GuestSleepTests. A
// negative second, a negative nanosecond and a nanosecond of 1e9 are EINVAL
// (-22); a sleep inside the yield's 50 us and one past it return 0.
//
// Freestanding and static, so it runs on the bare minirootfs. `nanosleep`
// beside this file is its build, made with Homebrew's llvm and lld:
//
//   llvm=$(brew --prefix llvm)/bin
//   $llvm/clang --target=aarch64-linux-gnu -O1 -ffreestanding -nostdlib -static \
//     -fno-stack-protector -fuse-ld=lld --ld-path=$(brew --prefix lld)/bin/ld.lld \
//     -o nanosleep nanosleep.c && $llvm/llvm-strip nanosleep

typedef long L;

static L sc(L n, L a, L b, L c, L d) {
    register L x8 __asm__("x8") = n;
    register L x0 __asm__("x0") = a;
    register L x1 __asm__("x1") = b;
    register L x2 __asm__("x2") = c;
    register L x3 __asm__("x3") = d;
    __asm__ volatile("svc 0" : "+r"(x0) : "r"(x8), "r"(x1), "r"(x2), "r"(x3) : "memory");
    return x0;
}

enum { WRITE = 64, EXIT_GROUP = 94, NANOSLEEP = 101, CLOCK_NANOSLEEP = 115 };
enum { CLOCK_MONOTONIC = 1 };

static void put(const char *s) { L n = 0; while (s[n]) n++; sc(WRITE, 1, (L)s, n, 0); }

static void num(L v) {
    char b[24]; int i = 23; b[i] = 0;
    int neg = v < 0; if (neg) v = -v;
    do { b[--i] = '0' + v % 10; v /= 10; } while (v);
    if (neg) b[--i] = '-';
    put(" "); put(b + i);
}

struct ts { L sec; L nsec; };

static void plain(L sec, L nsec) {
    struct ts t = {sec, nsec};
    num(sc(NANOSLEEP, (L)&t, 0, 0, 0));
}

static void clocked(L sec, L nsec) {
    struct ts t = {sec, nsec};
    num(sc(CLOCK_NANOSLEEP, CLOCK_MONOTONIC, 0, (L)&t, 0));
}

void _start(void) {
    put("nanosleep");
    plain(-1, 0); plain(0, -1); plain(0, 1000000000); plain(0, 1000); plain(0, 1000000);
    put(" clock_nanosleep");
    clocked(-1, 0); clocked(0, -1); clocked(0, 1000000000); clocked(0, 1000000);
    put("\n");
    sc(EXIT_GROUP, 0, 0, 0, 0);
}
