// The signal frame's ucontext as Linux lays it out on arm64, read the way musl
// and a runtime's signal handler read it, printed as one line for
// GuestSignalFrameTests. The handler is entered from a tgkill made at a known
// stack pointer and a known return address, and reads back from the context
// the stack pointer at 432 and the pc at 440 (uc_mcontext at 176, 16-byte
// aligned, its registers from 8), and the FPSIMD record's magic at the
// mcontext's 288. Bun's thread-suspend handler judges the interrupted stack by
// the context's sp, so a frame that puts it elsewhere suspends no thread.
//
// Freestanding and static, so it runs on the bare minirootfs. `ucontext` beside
// this file is its build, made with Homebrew's llvm and lld:
//
//   llvm=$(brew --prefix llvm)/bin
//   $llvm/clang --target=aarch64-linux-gnu -O1 -ffreestanding -nostdlib -static \
//     -fno-stack-protector -fuse-ld=lld --ld-path=$(brew --prefix lld)/bin/ld.lld \
//     -o ucontext ucontext.c && $llvm/llvm-strip ucontext

typedef long L;
typedef unsigned long U;

static L sc(L n, L a, L b, L c, L d) {
    register L x8 __asm__("x8") = n;
    register L x0 __asm__("x0") = a;
    register L x1 __asm__("x1") = b;
    register L x2 __asm__("x2") = c;
    register L x3 __asm__("x3") = d;
    __asm__ volatile("svc 0" : "+r"(x0) : "r"(x8), "r"(x1), "r"(x2), "r"(x3) : "memory");
    return x0;
}

enum { WRITE = 64, EXIT_GROUP = 94, RT_SIGACTION = 134, GETPID = 172, GETTID = 178, TGKILL = 131 };
enum { SIGUSR1 = 10, SA_SIGINFO = 4 };

static void put(const char *s) { L n = 0; while (s[n]) n++; sc(WRITE, 1, (L)s, n, 0); }

static void hex(U v) {
    char b[19]; b[0] = '0'; b[1] = 'x';
    for (int i = 0; i < 16; i++) b[2 + i] = "0123456789abcdef"[(v >> (60 - 4 * i)) & 0xf];
    b[18] = 0;
    put(b);
}

static volatile U sentSP, sentPC, readSP, readPC, mcontextAt;
static volatile unsigned readMagic;
static volatile int handled;

static void handler(int sig, void *info, void *uc) {
    (void)sig; (void)info;
    const unsigned char *u = uc;
    mcontextAt = (U)(u + 176);
    readSP = *(const U *)(u + 432);
    readPC = *(const U *)(u + 440);
    readMagic = *(const unsigned *)(u + 176 + 288);
    handled = 1;
}

static void check(const char *name, U got, U want) {
    put(name);
    if (got == want) { put("=ok"); return; }
    put("="); hex(got); put("/"); hex(want);
}

void _start(void) {
    struct { void *handler; U flags; void *restorer; U mask; } act = {(void *)handler, SA_SIGINFO, 0, 0};
    sc(RT_SIGACTION, SIGUSR1, (L)&act, 0, 8);

    L pid = sc(GETPID, 0, 0, 0, 0), tid = sc(GETTID, 0, 0, 0, 0);
    {
        register L x8 __asm__("x8") = TGKILL;
        register L x0 __asm__("x0") = pid;
        register L x1 __asm__("x1") = tid;
        register L x2 __asm__("x2") = SIGUSR1;
        __asm__ volatile(
            "mov x9, sp\n"
            "str x9, [%[sp]]\n"
            "adr x9, 1f\n"
            "str x9, [%[pc]]\n"
            "svc 0\n"
            "1:\n"
            : "+r"(x0)
            : "r"(x8), "r"(x1), "r"(x2), [sp] "r"(&sentSP), [pc] "r"(&sentPC)
            : "x9", "memory");
    }

    if (!handled) { put("not handled\n"); sc(EXIT_GROUP, 1, 0, 0, 0); }
    check("sp", readSP, sentSP);
    put(" "); check("pc", readPC, sentPC);
    put(" "); check("aligned", mcontextAt & 15, 0);
    put(" "); check("fpsimd", readMagic, 0x46508001);
    put(" returned\n");
    sc(EXIT_GROUP, 0, 0, 0, 0);
}
