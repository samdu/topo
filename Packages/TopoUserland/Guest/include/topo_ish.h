// Topo's door into the guest: the few calls the app makes into the iSH kernel of
// OpenMinis/ish-arm64, built by scripts/build-ish.sh into TopoIsh.xcframework with the fork's own
// libraries. Everything else of the kernel stays behind this header; TopoUserland is the only
// caller. The kernel is process-global state, so a process boots at most one.
#ifndef TOPO_ISH_H
#define TOPO_ISH_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

/// What `topo_ish_boot` answers when this process has already booted, or tried to: the kernel's
/// state is global and a second `become_first_process` would be a second init over the first.
#define TOPO_ISH_ALREADY_BOOTED 1

/// Makes a fakefs at `fakefs_dir` (which must not exist; the importer creates it) from a
/// gzipped tarball, with the fork's own importer (`fakefs_import`), so device nodes and
/// ownership land in `meta.db` as the kernel reads them. 0 on success; otherwise non-zero with
/// the importer's reason in `error` (truncated to `error_size`).
int topo_ish_import(const char *tarball, const char *fakefs_dir, char *error, size_t error_size);

/// Writes one uncompressed tarball at `out` (which must not exist) for `topo_ish_import` to make a
/// fakefs from: every entry of the gzipped tarball `rootfs`, then the file entries of each Alpine
/// package in `packages` in order, each entry's header — mode, owner, link target — as the
/// package carries it. A package's control entries (every name at its root that begins with a
/// dot: `.PKGINFO`, `.SIGN.*`, the install scripts and `.trigger`) are left out, and no script
/// runs. 0 on success; otherwise non-zero with libarchive's reason and the archive it was reading
/// in `error`, and `out` left for the caller to remove.
int topo_ish_combine(const char *rootfs, const char *const *packages, size_t package_count, const char *out,
                     char *error, size_t error_size);

/// Boots the kernel on the fakefs at `fakefs_dir`: mounts it as root, makes init (pid 1, which
/// never runs a program, so it never exits and never halts the process), the device nodes, /proc
/// and /dev/pts. 0 on success, a negative guest errno on failure, and `TOPO_ISH_ALREADY_BOOTED`
/// for every call after the first, whatever the first answered.
int topo_ish_boot(const char *fakefs_dir);

/// How many times this process has made a kernel: 0 before a boot, 1 after, never more.
int topo_ish_kernels(void);

/// Starts `path` in the guest as a child of init, with `argv` and `envp` (NULL-terminated), stdout
/// and stderr on pipes whose read ends are returned, and stdin on /dev/null when `stdin_fd` is
/// NULL or on a pipe whose write end is returned there otherwise. The caller closes every end it
/// is handed; the write end never raises SIGPIPE in the app (a write after the guest has let go
/// fails with EPIPE instead). The pid on success, a negative guest errno otherwise. Requires a
/// booted kernel.
int topo_ish_spawn(const char *path, const char *const *argv, const char *const *envp,
                   int *stdin_fd, int *stdout_fd, int *stderr_fd);

/// Waits for a pid `topo_ish_spawn` returned, reaps it, and writes its status: the exit code, or
/// 128 + the signal that ended it. 0 on success, a negative guest errno otherwise.
int topo_ish_wait(int pid, int *status);

/// The two signals the app sends a guest process tree, in the guest's (Linux) numbering.
#define TOPO_ISH_SIGKILL 9
#define TOPO_ISH_SIGTERM 15

/// Sends `sig` to every task in the guest but init, and writes the pids of those that are not
/// zombies (exiting ones included, which are listed and not signalled again) into `pids` up to
/// `capacity`. Answers how many there were, which may be more than `capacity`, or a negative guest
/// errno. Signal 0 only lists. For a guest that runs one program and what it starts, whatever
/// became of the links between them. Requires a booted kernel.
int topo_ish_signal_all(int sig, int *pids, int capacity);

/// How many of `pids` are still running: a task that exists and is not a zombie. A zombie whose
/// parent is init — a descendant orphaned when the process above it died — is reaped here, since
/// init never runs a program and so never reaps one itself. Never pass a pid a `topo_ish_wait`
/// is waiting on: that wait is the one reaper of its process. Requires a booted kernel.
int topo_ish_running(const int *pids, int count);

/// One line about `pid` for a log, into `out` (NUL-terminated, cut at `length`): its name, whether
/// it is a thread and of what, its parent, whether it is running, exiting or a zombie, whether it
/// is parked in a blocking call, the last syscall it entered, and whether a SIGKILL is pending —
/// what a teardown that did not finish says about what stayed. 0, or a negative guest errno.
/// Requires a booted kernel.
int topo_ish_describe(int pid, char *out, int length);

/// Bind-mounts the host directory `host_dir` at `point` in the guest through the fork's realfs,
/// making `point` and its parents directories in the fakefs first where they are not. A mount
/// already standing at `point` from the same host directory is left as it is; one from anywhere
/// else is refused with `_EBUSY`. The host's own mode bits are what the guest sees, so a file is
/// executable there only if it is executable on the host. 0 on success, a negative guest errno
/// otherwise. Requires a booted kernel.
int topo_ish_mount(const char *host_dir, const char *point);

/// `topo_ish_mount`'s contract for the memory's folder, through the vault's own filesystem: realfs
/// with the open of every regular file coordinated (`NSFileCoordinator`) — a read open waits for
/// any writer and has iCloud Drive bring an evicted file down first, a write open holds its
/// coordination until the file is closed — and every rename, removal and creation coordinated
/// as a write, each wait bounded (`TOPO_ISH_VAULT_WAIT_SECONDS`, then `_EIO`) and ended by a
/// SIGKILL to the task that waits (`_EINTR`). The mirror's own `.topo` folder at the mount's root
/// is refused `_EACCES` to every operation. 0, or a negative guest errno. Requires a booted
/// kernel.
int topo_ish_mount_vault(const char *host_dir, const char *point);

/// How long the vault's filesystem waits for a coordination before the guest's call fails: the
/// mirror's own bound on a download.
#define TOPO_ISH_VAULT_WAIT_SECONDS 20

/// Takes away the mount at `point`. `_EBUSY` while anything in the guest holds it — an open file,
/// a working directory — and `_EINVAL` when nothing is mounted there. 0 on success. Requires a
/// booted kernel.
int topo_ish_unmount(const char *point);

/// Makes `path` in the guest a symbolic link to `target`, its parents made where they are not. A
/// link already pointing at `target` is left untouched; one pointing elsewhere is replaced; a path
/// that is something other than a link is refused with `_EEXIST`. 0 on success, a negative guest
/// errno otherwise. Requires a booted kernel.
int topo_ish_link(const char *target, const char *path);

/// Feeds the memory brake a sample: `limit` is footprint plus what is still available (the live
/// jetsam line), `avail` what is still available. The first feed turns the brake on.
void topo_ish_memory_feed(uint64_t limit, uint64_t avail, bool critical);

/// Reads this process's footprint and available memory and feeds them to the brake. False when
/// either reads as zero (a simulator has no jetsam line), in which case nothing is fed.
bool topo_ish_memory_sample(bool critical);

/// `topo_ish_memory_sample(false)` as a hook: what the brake calls on a stale sample.
void topo_ish_memory_refresh(void);

/// Sets what the brake calls before it fails closed on a stale sample (`ish_mem_refresh_hook`,
/// Topo's patch to kernel/mmap.c). NULL fails closed at once, as the unpatched fork does.
void topo_ish_set_memory_refresh(void (*hook)(void));

/// The brake's admission decision for `bytes` of new anonymous memory (`ish_mem_commit_ok`),
/// the one choke point every guest `mmap` and `brk` passes through.
bool topo_ish_memory_admits(uint64_t bytes);

#endif
