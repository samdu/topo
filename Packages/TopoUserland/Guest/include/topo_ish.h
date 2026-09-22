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

/// Boots the kernel on the fakefs at `fakefs_dir`: mounts it as root, makes init (pid 1, which
/// never runs a program, so it never exits and never halts the process), the device nodes, /proc
/// and /dev/pts. 0 on success, a negative guest errno on failure, and `TOPO_ISH_ALREADY_BOOTED`
/// for every call after the first, whatever the first answered.
int topo_ish_boot(const char *fakefs_dir);

/// How many times this process has made a kernel: 0 before a boot, 1 after, never more.
int topo_ish_kernels(void);

/// Starts `path` in the guest as a child of init, with `argv` and `envp` (NULL-terminated), stdin
/// on /dev/null and stdout and stderr on pipes whose read ends are returned; the caller closes
/// them. The pid on success, a negative guest errno otherwise. Requires a booted kernel.
int topo_ish_spawn(const char *path, const char *const *argv, const char *const *envp,
                   int *stdout_fd, int *stderr_fd);

/// Waits for a pid `topo_ish_spawn` returned, reaps it, and writes its status: the exit code, or
/// 128 + the signal that ended it. 0 on success, a negative guest errno otherwise.
int topo_ish_wait(int pid, int *status);

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
