// utimensat(2) on a file in the current directory, printed as one line for
// GuestMountTests: times set to the nanosecond, both UTIME_OMIT changing
// nothing (ctime included), UTIME_OMIT for atime with UTIME_NOW for mtime
// keeping the one and moving the other and ctime, and ENOENT for a name that
// is not there. That is Linux's behaviour; the test runs it on a tmpfs the
// guest made (`patches/ish/0014-tmpfs-utime.patch`).
//
// Freestanding and static, so it runs on the bare minirootfs. `utimes` beside
// this file is its build, made with Homebrew's llvm and lld:
//
//   llvm=$(brew --prefix llvm)/bin
//   $llvm/clang --target=aarch64-linux-gnu -O1 -ffreestanding -nostdlib -static \
//     -fno-stack-protector -fuse-ld=lld --ld-path=$(brew --prefix lld)/bin/ld.lld \
//     -o utimes utimes.c && $llvm/llvm-strip utimes

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

enum { OPENAT = 56, CLOSE = 57, FSTATAT = 79, UTIMENSAT = 88, NANOSLEEP = 101,
       CLOCK_GETTIME = 113, WRITE = 64, EXIT_GROUP = 94 };
enum { AT_FDCWD = -100, UTIME_NOW = (1l << 30) - 1, UTIME_OMIT = (1l << 30) - 2 };

struct ts { L sec, nsec; };
// The three times of an aarch64 `struct stat`, which sit at bytes 72 to 120 of its 128.
struct times { struct ts a, m, c; };

static void put(const char *s) { L n = 0; while (s[n]) n++; sc(WRITE, 1, (L)s, n, 0); }

static void num(L v) {
    char b[24]; int i = 23; b[i] = 0;
    int neg = v < 0; if (neg) v = -v;
    do { b[--i] = '0' + v % 10; v /= 10; } while (v);
    if (neg) b[--i] = '-';
    put(b + i);
}

static struct times stat_f(void) {
    L st[16];
    if (sc(FSTATAT, AT_FDCWD, (L)"f", (L)st, 0) != 0) { put("stat failed\n"); sc(EXIT_GROUP, 2, 0, 0, 0); }
    return (struct times){ { st[9], st[10] }, { st[11], st[12] }, { st[13], st[14] } };
}

static L utime(const char *name, L asec, L ansec, L msec, L mnsec) {
    struct ts t[2] = { { asec, ansec }, { msec, mnsec } };
    return sc(UTIMENSAT, AT_FDCWD, (L)name, (L)t, 0);
}

static int same(struct ts x, struct ts y) { return x.sec == y.sec && x.nsec == y.nsec; }

static void pause_(void) { struct ts d = { 0, 20000000 }; sc(NANOSLEEP, (L)&d, 0, 0, 0); }

void _start(void) {
    L fd = sc(OPENAT, AT_FDCWD, (L)"f", 0101 /* O_WRONLY | O_CREAT */, 0644);
    if (fd < 0) { put("create failed\n"); sc(EXIT_GROUP, 2, 0, 0, 0); }
    sc(CLOSE, fd, 0, 0, 0);
    int bad = 0;

    // Set to the nanosecond.
    L rc = utime("f", 1000, 111, 2000, 222);
    struct times t = stat_f();
    put("set="); num(rc); put(":"); num(t.a.sec); put("."); num(t.a.nsec);
    put(","); num(t.m.sec); put("."); num(t.m.nsec);
    bad |= rc != 0 || t.a.sec != 1000 || t.a.nsec != 111 || t.m.sec != 2000 || t.m.nsec != 222;

    // Both omitted: nothing moves, ctime included.
    pause_();
    rc = utime("f", 0, UTIME_OMIT, 0, UTIME_OMIT);
    struct times u = stat_f();
    int kept = same(u.a, t.a) && same(u.m, t.m) && same(u.c, t.c);
    put(" omit="); num(rc); put(kept ? ":same" : ":moved");
    bad |= rc != 0 || !kept;

    // atime omitted, mtime now: atime stays, mtime and ctime move to now.
    pause_();
    struct ts before, after;
    sc(CLOCK_GETTIME, 0 /* CLOCK_REALTIME */, (L)&before, 0, 0);
    rc = utime("f", 0, UTIME_OMIT, 0, UTIME_NOW);
    sc(CLOCK_GETTIME, 0, (L)&after, 0, 0);
    struct times v = stat_f();
    int a_kept = same(v.a, t.a);
    int m_now = v.m.sec >= before.sec && v.m.sec <= after.sec;
    int c_moved = !same(v.c, u.c) && v.c.sec >= before.sec && v.c.sec <= after.sec;
    put(" now="); num(rc); put(a_kept ? ":a-kept" : ":a-moved");
    put(m_now ? ",m-now" : ",m-not-now"); put(c_moved ? ",c-moved" : ",c-not-moved");
    bad |= rc != 0 || !a_kept || !m_now || !c_moved;

    // A name that is not there, even with both omitted.
    rc = utime("absent", 0, UTIME_OMIT, 0, UTIME_OMIT);
    put(" absent="); num(rc); put("\n");
    bad |= rc != -2;

    sc(EXIT_GROUP, bad, 0, 0, 0);
}
