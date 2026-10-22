// Threads that store a new instruction into a page holding translated code
// and then run it, beside threads running the same code: printed as one line
// for GuestCodeWriteTests. One chain of four one-page functions: page i sets
// lane i of x0 (`movk x0, #v, lsl #16*i`) and branches straight to page i+1,
// the last returns. Writer i owns lane i: a round stores a new value into page
// i, then runs the chain and compares lane i with what it just wrote. Four
// runner threads run the same chain all the while, so a runner can be
// compiling page i between a writer's write miss and its store landing. Only a
// writer writes its lane, so a lane that is not its last write is a mismatch,
// counted per writer; the line is the counts and the mismatches, and the
// status is 1 if there were any.
//
// Built three ways, by how a writer stores its instruction:
//
//   codeshare       a plain `str`, which the emulator makes in a gadget;
//   codeshare-swp   a `swp` (LSE), which it makes in a C helper (c_atomic_rmw);
//   codeshare-ivau  a plain `str` followed by DC CVAU, DSB, IC IVAU, DSB, ISB.
//
// The first two hold the emulator to its own promise: a store that reaches a
// page of translated code is in what the next run of that page executes. ARM
// itself promises that only after the writer's IC IVAU and ISB, which those
// two do not issue, so on hardware their result would be undefined. The third
// issues them, so a mismatch there breaks ARM's own rule.
//
// Freestanding and static, so it runs on the bare minirootfs. The three
// binaries beside this file are its builds, made with Homebrew's llvm and lld:
//
//   llvm=$(brew --prefix llvm)/bin
//   build() { $llvm/clang --target=aarch64-linux-gnu -march=armv8.1-a -O1 -ffreestanding \
//     -nostdlib -static -fno-stack-protector -fuse-ld=lld \
//     --ld-path=$(brew --prefix lld)/bin/ld.lld "$@" codeshare.c && $llvm/llvm-strip "$2"; }
//   build -o codeshare; build -o codeshare-swp -DCODESHARE_SWP; build -o codeshare-ivau -DCODESHARE_IVAU

typedef long L;
typedef unsigned int U32;
typedef unsigned long U64;

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

enum { CLONE = 220, EXIT = 93, EXIT_GROUP = 94, SCHED_YIELD = 124, MMAP = 222, WRITE = 64 };

static void put(const char *s) { L n = 0; while (s[n]) n++; sc(WRITE, 1, (L)s, n, 0, 0, 0); }

static void num(L v) {
    char b[24]; int i = 23; b[i] = 0;
    do { b[--i] = '0' + v % 10; v /= 10; } while (v);
    put(b + i);
}

// `<name>=0x<v>` on stderr: the region's first and one-past-last addresses, which the test
// reads to see that every chain sits below 4 GB, where this fork's emulator chains blocks.
static void hex_line(const char *name, U64 v) {
    char b[32]; int i = 31; b[i] = 0;
    do { b[--i] = "0123456789abcdef"[v & 15]; v >>= 4; } while (v);
    b[--i] = 'x'; b[--i] = '0'; b[--i] = '=';
    const char *s = b + i; L n = 0; while (s[n]) n++;
    L m = 0; while (name[m]) m++;
    sc(WRITE, 2, (L)name, m, 0, 0, 0); sc(WRITE, 2, (L)s, n, 0, 0, 0); sc(WRITE, 2, (L)"\n", 1, 0, 0, 0);
}

enum { PAGE = 4096, LANES = 4, WRITERS = 4, RUNNERS = 4, ROUNDS = 20000 };

static char *region;
static volatile L mismatches[WRITERS];
static volatile L writing = WRITERS;
static volatile L done;

static U32 *word(int lane, int index) { return (U32 *)(region + (L)lane * PAGE) + index; }

// `movk x0, #v, lsl #(16 * lane)`.
static U32 movk(int lane, U32 v) { return 0xf2800000u | ((U32)lane << 21) | ((v & 0xffff) << 5); }

// Writer's store of `insn` to `at`, made the way this build makes it.
static void store(U32 *at, U32 insn) {
#if defined(CODESHARE_SWP)
    U32 old;
    __asm__ volatile("swp %w1, %w0, [%2]" : "=&r"(old) : "r"(insn), "r"(at) : "memory");
#else
    *(volatile U32 *)at = insn;
#endif
#if defined(CODESHARE_IVAU)
    __asm__ volatile("dc cvau, %0\n dsb ish\n ic ivau, %0\n dsb ish\n isb" :: "r"(at) : "memory");
#endif
}

static U64 run(void) {
    U64 (*fn)(U64) = (U64 (*)(U64))region;
    return fn(0);
}

// Threads 0 to WRITERS - 1 write and check their lane; the rest run the chain until every
// writer is done.
static void thread(L who) {
    if (who < WRITERS) {
        int lane = (int)who;
        for (int r = 1; r <= ROUNDS; r++) {
            U32 v = 2 + (r & 0x7fff);
            store(word(lane, 0), movk(lane, v));
            __asm__ volatile("" ::: "memory");
            U64 x = run();
            if (((x >> (16 * lane)) & 0xffff) != v)
                __atomic_fetch_add(&mismatches[who], 1, __ATOMIC_SEQ_CST);
            sc(SCHED_YIELD, 0, 0, 0, 0, 0, 0);
        }
        __atomic_fetch_sub(&writing, 1, __ATOMIC_SEQ_CST);
    } else {
        for (L n = 0; __atomic_load_n(&writing, __ATOMIC_SEQ_CST) > 0; n++) {
            run();
            if (n % 64 == 0) sc(SCHED_YIELD, 0, 0, 0, 0, 0, 0);
        }
    }
    __atomic_fetch_add(&done, 1, __ATOMIC_SEQ_CST);
    sc(EXIT, 0, 0, 0, 0, 0, 0);
}

// clone(2) with a stack of its own; the child calls thread(arg) and never returns here.
static L spawn(L arg, L stack_top) {
    register L x0 __asm__("x0") = 0x50f00; // VM, FS, FILES, SIGHAND, THREAD, SYSVSEM
    register L x1 __asm__("x1") = stack_top;
    register L x2 __asm__("x2") = 0;
    register L x3 __asm__("x3") = 0;
    register L x4 __asm__("x4") = 0;
    register L x5 __asm__("x5") = (L)thread;
    register L x6 __asm__("x6") = arg;
    register L x8 __asm__("x8") = CLONE;
    __asm__ volatile(
        "svc 0\n"
        "cbnz x0, 1f\n"
        "mov x0, x6\n"
        "blr x5\n"
        "1:\n"
        : "+r"(x0) : "r"(x1), "r"(x2), "r"(x3), "r"(x4), "r"(x5), "r"(x6), "r"(x8) : "memory", "cc", "x30");
    return x0;
}

void _start(void) {
    region = (char *)sc(MMAP, 0, LANES * PAGE, 7 /* RWX */, 0x22 /* private, anonymous */, -1, 0);
    if ((L)region < 0 && (L)region > -4096) { put("mmap failed\n"); sc(EXIT_GROUP, 2, 0, 0, 0, 0, 0); }
    hex_line("region", (U64)region);
    hex_line("end", (U64)region + (U64)LANES * PAGE);
    for (int lane = 0; lane < LANES; lane++) {
        *word(lane, 0) = movk(lane, 1);
        // `b` to the next page (4092 bytes on), or `ret` from the last.
        *word(lane, 1) = lane + 1 < LANES ? 0x14000000u | ((PAGE - 4) / 4) : 0xd65f03c0u;
    }

    for (L t = 0; t < WRITERS + RUNNERS; t++) {
        L stack = sc(MMAP, 0, 65536, 3, 0x22, -1, 0);
        if (spawn(t, stack + 65536) < 0) { put("clone failed\n"); sc(EXIT_GROUP, 2, 0, 0, 0, 0, 0); }
    }
    while (__atomic_load_n(&done, __ATOMIC_SEQ_CST) < WRITERS + RUNNERS)
        sc(SCHED_YIELD, 0, 0, 0, 0, 0, 0);

    L total = 0;
    put("rounds="); num(ROUNDS); put(" writers="); num(WRITERS); put(" runners="); num(RUNNERS);
    put(" lanes=");
    for (int w = 0; w < WRITERS; w++) { if (w) put(","); num(mismatches[w]); total += mismatches[w]; }
    put(" mismatches="); num(total); put("\n");
    sc(EXIT_GROUP, total ? 1 : 0, 0, 0, 0, 0, 0);
}
