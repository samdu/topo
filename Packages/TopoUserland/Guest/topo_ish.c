// The kernel side of topo_ish.h, compiled by scripts/build-ish.sh against the fork's own headers
// and archived with its libraries into TopoIsh.xcframework.
//
// The boot sequence and the process launch follow OpenMinis/ish-arm64's app/AppDelegate.m
// (`-boot`, `ish_install_anon_cap`, `ish_memory_governor_tick`) and app/ISHShellExecutor.m, which
// are GPL-3.0 with iSH's App Store exception (THIRD-PARTY); what is left out is everything of
// the terminal's — the consoles, the clipboard and location devices, the boot command — since
// nothing here runs a terminal, and init never runs a program.
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <os/proc.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
#include <mach/mach.h>
#include <TargetConditionals.h>

#include "kernel/calls.h"
#include "kernel/init.h"
#include "kernel/mm.h"
#include "kernel/task.h"
#include "fs/dev.h"
#include "fs/devices.h"
#include "fs/fd.h"
#include "fs/path.h"
#include "fs/real.h"
#include "fs/sock.h"
#include "tools/fakefs.h"

#include "topo_ish.h"

// kernel/uname.c defines it and no header declares it.
extern const char *uname_hostname_override;

// kernel/exit.c defines these and declares none of them in a header.
int do_wait(int idtype, pid_t_ id, struct siginfo_ *info, struct rusage_ *rusage, int options);
#define TOPO_P_PID 1
#define TOPO_WEXITED (1 << 2)

static pthread_mutex_t boot_lock = PTHREAD_MUTEX_INITIALIZER;
static int kernels = 0;
static bool booted = false;
// `become_new_init_child` takes no lock of its own ("locking? who needs locking?!"), so two
// launches at once would race on the pid table.
static pthread_mutex_t spawn_lock = PTHREAD_MUTEX_INITIALIZER;

int topo_ish_import(const char *tarball, const char *fakefs_dir, char *error, size_t error_size) {
    struct fakefsify_error err = {0};
    if (fakefs_import(tarball, fakefs_dir, &err, (struct progress) {NULL, NULL}))
        return 0;
    if (error != NULL && error_size > 0)
        snprintf(error, error_size, "%s (line %d, code %d)", err.message ? err.message : "import failed",
                 err.line, err.code);
    free(err.message);
    return err.code != 0 ? err.code : -1;
}

// The ledger cap the brake falls back on before the first sample: 80% of what the process may
// still allocate, in host pages (a guest page occupies a whole host page). As the fork's app.
static void install_anon_cap(void) {
    size_t avail = os_proc_available_memory();
    size_t page = (size_t) getpagesize();
    if (avail == 0 || page == 0)
        return;
    ish_set_anon_page_limit((long) ((double) avail * 0.8 / (double) page));
}

int topo_ish_boot(const char *fakefs_dir) {
    pthread_mutex_lock(&boot_lock);
    if (kernels > 0) {
        pthread_mutex_unlock(&boot_lock);
        return TOPO_ISH_ALREADY_BOOTED;
    }
    // Counted before anything global is touched: a boot that fails halfway has still mounted a
    // root or made an init, and a second attempt would build over it.
    kernels++;

    install_anon_cap();

    // The guest's name is its own, never the host's: do_uname strcpys the host's nodename into a
    // 65-byte field, which a long host name (a CI runner's, a Mac's) overflows into a fortify
    // trap in the first program that asks, and the host's name is not the guest's to read.
    uname_hostname_override = "topo";

    char data[PATH_MAX];
    snprintf(data, sizeof(data), "%s/data", fakefs_dir);
    int err = mount_root(&fakefs, data);
    if (err < 0)
        goto out;

    struct task *previous = current;
    err = become_first_process();
    if (err < 0)
        goto out;

    generic_mknodat(AT_PWD, "/dev/tty", S_IFCHR|0666, dev_make(TTY_ALTERNATE_MAJOR, DEV_TTY_MINOR));
    generic_mknodat(AT_PWD, "/dev/console", S_IFCHR|0666, dev_make(TTY_ALTERNATE_MAJOR, DEV_CONSOLE_MINOR));
    generic_mknodat(AT_PWD, "/dev/ptmx", S_IFCHR|0666, dev_make(TTY_ALTERNATE_MAJOR, DEV_PTMX_MINOR));
    generic_mknodat(AT_PWD, "/dev/null", S_IFCHR|0666, dev_make(MEM_MAJOR, DEV_NULL_MINOR));
    generic_mknodat(AT_PWD, "/dev/zero", S_IFCHR|0666, dev_make(MEM_MAJOR, DEV_ZERO_MINOR));
    generic_mknodat(AT_PWD, "/dev/full", S_IFCHR|0666, dev_make(MEM_MAJOR, DEV_FULL_MINOR));
    generic_mknodat(AT_PWD, "/dev/random", S_IFCHR|0666, dev_make(MEM_MAJOR, DEV_RANDOM_MINOR));
    generic_mknodat(AT_PWD, "/dev/urandom", S_IFCHR|0666, dev_make(MEM_MAJOR, DEV_URANDOM_MINOR));
    generic_mkdirat(AT_PWD, "/dev/pts", 0755);
    generic_setattrat(AT_PWD, "/", (struct attr) {.type = attr_mode, .mode = 0755}, false);

    do_mount(&procfs, "proc", "/proc", "", 0);
    do_mount(&devptsfs, "devpts", "/dev/pts", "", 0);

#if !TARGET_OS_SIMULATOR
    // A guest's unix sockets are host sockets under this prefix, and the default, /tmp, is
    // outside the sandbox on a device.
    char tmp[PATH_MAX];
    if (confstr(_CS_DARWIN_USER_TEMP_DIR, tmp, sizeof(tmp)) > 0) {
        strlcat(tmp, "ishsock", sizeof(tmp));
        sock_tmp_prefix = strdup(tmp);
    }
#endif

    current = previous;
    booted = true;
    err = 0;
out:
    pthread_mutex_unlock(&boot_lock);
    return err;
}

int topo_ish_kernels(void) {
    pthread_mutex_lock(&boot_lock);
    int n = kernels;
    pthread_mutex_unlock(&boot_lock);
    return n;
}

// A guest fd over a host one, with the host's stat, so a program that fstats its stdout (libuv
// does) sees a pipe rather than zeroes. kernel/init.c's `open_fd_from_actual_fd`, which is static.
static struct fd *guest_fd(int host_fd) {
    struct fd *fd = adhoc_fd_create(&realfs_fdops);
    if (fd == NULL)
        return NULL;
    fd->real_fd = host_fd;
    fd->dir = NULL;
    struct stat st;
    if (fstat(host_fd, &st) == 0) {
        fd->stat.mode = st.st_mode;
        fd->stat.rdev = dev_fake_from_real(st.st_rdev);
        fd->stat.inode = st.st_ino;
        fd->stat.size = st.st_size;
    }
    return fd;
}

// argv or envp as the kernel takes them: one buffer of NUL-terminated strings ending in an
// empty one. -1 when they do not fit.
static ssize_t pack(const char *const *strings, char *out, size_t size, size_t *count) {
    size_t at = 0, n = 0;
    for (; strings != NULL && strings[n] != NULL; n++) {
        size_t len = strlen(strings[n]) + 1;
        if (at + len + 1 > size)
            return -1;
        memcpy(out + at, strings[n], len);
        at += len;
    }
    out[at] = '\0';
    if (count != NULL)
        *count = n;
    return (ssize_t) at;
}

int topo_ish_spawn(const char *path, const char *const *argv, const char *const *envp,
                   int *stdout_fd, int *stderr_fd) {
    if (!booted)
        return _ENODEV;
    char args[16384], env[16384];
    size_t argc = 0;
    if (pack(argv, args, sizeof(args), &argc) < 0 || argc == 0 || pack(envp, env, sizeof(env), NULL) < 0)
        return _E2BIG;

    int out[2], err[2];
    if (pipe(out) < 0)
        return _EMFILE;
    if (pipe(err) < 0) {
        close(out[0]);
        close(out[1]);
        return _EMFILE;
    }
    fcntl(out[0], F_SETFD, FD_CLOEXEC);
    fcntl(err[0], F_SETFD, FD_CLOEXEC);

    pthread_mutex_lock(&spawn_lock);
    struct task *previous = current;
    int result = become_new_init_child();
    if (result < 0)
        goto fail;
    struct task *task = current;

    int null = open("/dev/null", O_RDONLY | O_CLOEXEC);
    task->files->files[0] = null >= 0 ? guest_fd(null) : NULL;
    task->files->files[1] = guest_fd(out[1]);
    task->files->files[2] = guest_fd(err[1]);
    // The guest owns the write ends now: they close when the last guest fd on them does, which
    // is what ends the reads.
    out[1] = err[1] = -1;

    result = do_execve(path, argc, args, env);
    if (result < 0) {
        // The task never ran; it is left to init as a child that never started, which is what the
        // fork's own launcher does with one.
        goto fail;
    }
    int pid = task->pid;
    result = task_start(task);
    current = previous;
    if (result < 0) {
        pthread_mutex_unlock(&spawn_lock);
        close(out[0]);
        close(err[0]);
        return result;
    }
    pthread_mutex_unlock(&spawn_lock);
    *stdout_fd = out[0];
    *stderr_fd = err[0];
    return pid;

fail:
    current = previous;
    pthread_mutex_unlock(&spawn_lock);
    close(out[0]);
    close(err[0]);
    if (out[1] >= 0)
        close(out[1]);
    if (err[1] >= 0)
        close(err[1]);
    return result;
}

int topo_ish_wait(int pid, int *status) {
    if (!booted)
        return _ENODEV;
    // do_wait reaps children of `current`, and the process was started as init's.
    struct task *previous = current;
    current = pid_get_task(1);
    struct siginfo_ info = {0};
    int err = do_wait(TOPO_P_PID, pid, &info, NULL, TOPO_WEXITED);
    current = previous;
    if (err < 0)
        return err;
    // The raw wait status: an exit code in the high byte, or the signal in the low seven bits.
    int raw = (int) info.child.status;
    *status = (raw & 0x7f) != 0 ? 128 + (raw & 0x7f) : (raw >> 8) & 0xff;
    return 0;
}

// Makes every directory on the way to `path` (a normalised, absolute guest path), and `path`
// itself, in whatever filesystem holds each. One that is already there is not an error.
static int make_directories(const char *path) {
    char partial[MAX_PATH];
    size_t length = strlen(path);
    if (length == 0 || length >= sizeof(partial) || path[0] != '/')
        return _EINVAL;
    for (size_t at = 1; at <= length; at++) {
        if (path[at] != '/' && path[at] != '\0')
            continue;
        memcpy(partial, path, at);
        partial[at] = '\0';
        int err = generic_mkdirat(AT_PWD, partial, 0755);
        if (err < 0 && err != _EEXIST)
            return err;
    }
    struct statbuf stat;
    int err = generic_statat(AT_PWD, path, &stat, true);
    if (err < 0)
        return err;
    return S_ISDIR(stat.mode) ? 0 : _ENOTDIR;
}

// The guest's file calls resolve against `current`'s root and working directory, so the host
// thread speaks as init while it makes the mount and the link, under the spawn lock that already
// serialises every other use of `current` from outside the guest.
static struct task *speak_as_init(void) {
    pthread_mutex_lock(&spawn_lock);
    struct task *previous = current;
    current = pid_get_task(1);
    return previous;
}

static void stop_speaking_as_init(struct task *previous) {
    current = previous;
    pthread_mutex_unlock(&spawn_lock);
}

int topo_ish_mount(const char *host_dir, const char *point_raw) {
    if (!booted)
        return _ENODEV;
    // realfs keeps the source by its real path, so that is what an existing mount is compared by.
    char *source = realpath(host_dir, NULL);
    if (source == NULL)
        return _ENOENT;
    struct task *previous = speak_as_init();
    char point[MAX_PATH];
    int err = path_normalize(AT_PWD, point_raw, point, N_SYMLINK_FOLLOW);
    if (err < 0)
        goto out;
    err = make_directories(point);
    if (err < 0)
        goto out;
    lock(&mounts_lock);
    struct mount *mount;
    bool standing = false;
    list_for_each_entry(&mounts, mount, mounts) {
        if (strcmp(mount->point, point) == 0) {
            standing = true;
            break;
        }
    }
    if (standing)
        err = strcmp(mount->source, source) == 0 ? 0 : _EBUSY;
    else
        err = do_mount(&realfs, source, point, "", 0);
    unlock(&mounts_lock);
out:
    stop_speaking_as_init(previous);
    free(source);
    return err;
}

int topo_ish_link(const char *target, const char *path) {
    if (!booted)
        return _ENODEV;
    struct task *previous = speak_as_init();
    char normalised[MAX_PATH];
    int err = path_normalize(AT_PWD, path, normalised, N_SYMLINK_NOFOLLOW);
    if (err < 0)
        goto out;
    char *slash = strrchr(normalised, '/');
    if (slash != NULL && slash != normalised) {
        *slash = '\0';
        err = make_directories(normalised);
        *slash = '/';
        if (err < 0)
            goto out;
    }
    char existing[MAX_PATH];
    ssize_t length = generic_readlinkat(AT_PWD, normalised, existing, sizeof(existing) - 1);
    if (length >= 0) {
        existing[length] = '\0';
        if (strcmp(existing, target) == 0) {
            err = 0;
            goto out;
        }
        err = generic_unlinkat(AT_PWD, normalised);
        if (err < 0)
            goto out;
    } else if (length != _ENOENT) {
        // Something that is not a link is there (readlink answers EINVAL for one): not ours to
        // take away.
        err = length == _EINVAL ? _EEXIST : (int) length;
        goto out;
    }
    err = generic_symlinkat(target, AT_PWD, normalised);
out:
    stop_speaking_as_init(previous);
    return err;
}

void topo_ish_memory_feed(uint64_t limit, uint64_t avail, bool critical) {
    ish_set_memory_status(limit, avail, critical);
}

bool topo_ish_memory_sample(bool critical) {
    task_vm_info_data_t info;
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    uint64_t footprint = 0;
    if (task_info(mach_task_self(), TASK_VM_INFO, (task_info_t) &info, &count) == KERN_SUCCESS)
        footprint = info.phys_footprint;
    uint64_t avail = (uint64_t) os_proc_available_memory();
    if (footprint == 0 || avail == 0)
        return false;
    ish_set_memory_status(footprint + avail, avail, critical);
    return true;
}

void topo_ish_memory_refresh(void) {
    topo_ish_memory_sample(false);
}

void topo_ish_set_memory_refresh(void (*hook)(void)) {
    ish_mem_refresh_hook = hook;
}

bool topo_ish_memory_admits(uint64_t bytes) {
    return ish_mem_commit_ok(bytes);
}
