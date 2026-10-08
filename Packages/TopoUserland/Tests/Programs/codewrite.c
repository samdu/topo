// Several threads write to pages holding translated code while the code on
// those pages, and on the pages that share its page-hash buckets, is being
// run; printed as one line for GuestCodeWriteTests. Each thread owns two
// copies of a chain of four one-page functions: page i sets lane i of x0
// (`movk x0, #v, lsl #16*i`) and branches straight to page i+1, the last
// returns. Every direct branch chains in the emulator, so each page's block
// has the previous page's as a predecessor, which is what an invalidation has
// to disconnect. Every chain is 1024 pages from the next, so page i of every
// chain shares the emulator's page-hash bucket with page i of every other, and
// one thread's write invalidates every thread's blocks for that page, the
// blocks they are running included.
//
// A round is one page of one copy patched to a new value, then both copies
// run and every lane of each compared with what this thread wrote to it. Only
// the owner ever runs its chains, so what it reads back is its own doing; a
// lane that is not what was written is a mismatch, counted per thread. The
// line is the counts and the mismatches, and the status is 1 if there were any.
//
// Freestanding and static, so it runs on the bare minirootfs. `codewrite`
// beside this file is its build, made with Homebrew's llvm and lld:
//
//   llvm=$(brew --prefix llvm)/bin
//   $llvm/clang --target=aarch64-linux-gnu -O1 -ffreestanding -nostdlib -static \
//     -fno-stack-protector -fuse-ld=lld --ld-path=$(brew --prefix lld)/bin/ld.lld \
//     -o codewrite codewrite.c && $llvm/llvm-strip codewrite

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

enum { PAGE = 4096, LANES = 4, THREADS = 4, COPIES = 2, APART = 1024, ROUNDS = 20000 };

static char *region;
static volatile L mismatches[THREADS];
static volatile L done;

// Chain `chain` (a thread's copy) starts APART * chain pages into the region.
static U32 *word(int chain, int lane, int index) {
    return (U32 *)(region + ((L)chain * APART + lane) * PAGE) + index;
}

// `movk x0, #v, lsl #(16 * lane)`.
static U32 movk(int lane, U32 v) { return 0xf2800000u | ((U32)lane << 21) | ((v & 0xffff) << 5); }

static U64 run(int chain) {
    U64 (*fn)(U64) = (U64 (*)(U64))(region + (L)chain * APART * PAGE);
    return fn(0);
}

static void thread(L who) {
    U32 wrote[COPIES][LANES];
    for (int c = 0; c < COPIES; c++)
        for (int lane = 0; lane < LANES; lane++) wrote[c][lane] = 1;
    for (int r = 1; r <= ROUNDS; r++) {
        int c = r % COPIES, lane = (r / COPIES) % LANES, chain = (int)who * COPIES + c;
        U32 v = 1 + (r & 0x7fff);
        *(volatile U32 *)word(chain, lane, 0) = movk(lane, v);
        __asm__ volatile("" ::: "memory");
        wrote[c][lane] = v;
        for (int k = 0; k < COPIES; k++) {
            U64 x = run((int)who * COPIES + k);
            for (int l = 0; l < LANES; l++)
                if (((x >> (16 * l)) & 0xffff) != wrote[k][l])
                    __atomic_fetch_add(&mismatches[who], 1, __ATOMIC_SEQ_CST);
        }
        sc(SCHED_YIELD, 0, 0, 0, 0, 0, 0);
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
    int chains = THREADS * COPIES;
    L pages = (L)(chains - 1) * APART + LANES;
    region = (char *)sc(MMAP, 0, pages * PAGE, 7 /* RWX */, 0x22 /* private, anonymous */, -1, 0);
    if ((L)region < 0 && (L)region > -4096) { put("mmap failed\n"); sc(EXIT_GROUP, 2, 0, 0, 0, 0, 0); }
    hex_line("region", (U64)region);
    hex_line("end", (U64)region + (U64)pages * PAGE);
    for (int chain = 0; chain < chains; chain++) {
        for (int lane = 0; lane < LANES; lane++) {
            *word(chain, lane, 0) = movk(lane, 1);
            // `b` to the next page (4092 bytes on), or `ret` from the last.
            *word(chain, lane, 1) = lane + 1 < LANES ? 0x14000000u | ((PAGE - 4) / 4) : 0xd65f03c0u;
        }
    }

    for (L t = 0; t < THREADS; t++) {
        L stack = sc(MMAP, 0, 65536, 3, 0x22, -1, 0);
        if (spawn(t, stack + 65536) < 0) { put("clone failed\n"); sc(EXIT_GROUP, 2, 0, 0, 0, 0, 0); }
    }
    while (__atomic_load_n(&done, __ATOMIC_SEQ_CST) < THREADS)
        sc(SCHED_YIELD, 0, 0, 0, 0, 0, 0);

    L total = 0;
    for (int t = 0; t < THREADS; t++) total += mismatches[t];
    put("rounds="); num(ROUNDS); put(" threads="); num(THREADS); put(" copies="); num(COPIES);
    put(" mismatches="); num(total); put("\n");
    sc(EXIT_GROUP, total ? 1 : 0, 0, 0, 0, 0, 0);
}
