// pidfd_open(2) against the three states of a child, printed as one line for
// GuestPidfdTests: a zombie (exited, not yet reaped) opens and polls readable,
// a reaped one is ESRCH, and a live one opens and does not poll readable.
// That is Linux's behaviour, and bun, which opens a pidfd on every child it
// spawns, relies on the first.
//
// Freestanding and static, so it runs on the bare minirootfs. `pidfd` beside
// this file is its build, made with Homebrew's llvm and lld:
//
//   llvm=$(brew --prefix llvm)/bin
//   $llvm/clang --target=aarch64-linux-gnu -O1 -ffreestanding -nostdlib -static \
//     -fno-stack-protector -fuse-ld=lld --ld-path=$(brew --prefix lld)/bin/ld.lld \
//     -o pidfd pidfd.c && $llvm/llvm-strip pidfd

typedef long L;

static L sc(L n, L a, L b, L c, L d, L e) {
    register L x8 __asm__("x8") = n;
    register L x0 __asm__("x0") = a;
    register L x1 __asm__("x1") = b;
    register L x2 __asm__("x2") = c;
    register L x3 __asm__("x3") = d;
    register L x4 __asm__("x4") = e;
    __asm__ volatile("svc 0" : "+r"(x0) : "r"(x8), "r"(x1), "r"(x2), "r"(x3), "r"(x4) : "memory");
    return x0;
}

enum { CLONE = 220, EXIT_GROUP = 94, NANOSLEEP = 101, WAITID = 95, WAIT4 = 260,
       PIDFD_OPEN = 434, PPOLL = 73, WRITE = 64, KILL = 129 };

static void put(const char *s) { L n = 0; while (s[n]) n++; sc(WRITE, 1, (L)s, n, 0, 0); }

static void num(L v) {
    char b[24]; int i = 23; b[i] = 0;
    int neg = v < 0; if (neg) v = -v;
    do { b[--i] = '0' + v % 10; v /= 10; } while (v);
    if (neg) b[--i] = '-';
    put(b + i);
}

static L child(L seconds) {
    L pid = sc(CLONE, 17 /* SIGCHLD */, 0, 0, 0, 0);
    if (pid == 0) {
        struct { L s, ns; } t = {seconds, 0};
        if (seconds) sc(NANOSLEEP, (L)&t, 0, 0, 0, 0);
        sc(EXIT_GROUP, 0, 0, 0, 0, 0);
    }
    return pid;
}

// The pidfd's poll, without waiting: 1 if it reads as exited.
static L readable(L fd) {
    struct { int fd; short events, revents; } p = {(int)fd, 1 /* POLLIN */, 0};
    struct { L s, ns; } zero = {0, 0};
    L r = sc(PPOLL, (L)&p, 1, (L)&zero, 0, 8);
    return r < 0 ? r : (p.revents & 1);
}

static void report(const char *name, L fd) {
    put(name); put("=");
    if (fd < 0) { num(fd); return; }
    put("open readable="); num(readable(fd));
}

void _start(void) {
    char info[128];

    // Exited and not reaped: waitid with WNOWAIT returns once it is a zombie
    // and leaves it one.
    L zombie = child(0);
    sc(WAITID, 1 /* P_PID */, zombie, (L)info, 4 /* WEXITED */ | 0x1000000 /* WNOWAIT */, 0);
    report("zombie", sc(PIDFD_OPEN, zombie, 0, 0, 0, 0));

    // Reaped: the pid is gone.
    sc(WAIT4, zombie, 0, 0, 0, 0);
    put(" "); report("reaped", sc(PIDFD_OPEN, zombie, 0, 0, 0, 0));

    // Running.
    L live = child(30);
    put(" "); report("live", sc(PIDFD_OPEN, live, 0, 0, 0, 0));
    sc(KILL, live, 9, 0, 0, 0);
    sc(WAIT4, live, 0, 0, 0, 0);

    put("\n");
    sc(EXIT_GROUP, 0, 0, 0, 0, 0);
}
