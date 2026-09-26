// The memory's filesystem in the guest: the fork's realfs, with the file coordination the fork's
// own `app/iOSFS.m` puts around it, carried here because that file is part of the fork's app and
// not of anything its meson build makes. The vault is shared with Files, with whatever editor has
// it open, with iCloud Drive and with the mirror, and each of those reads and writes it under
// `NSFileCoordinator`; a guest that did not would read half a file somebody is saving, and would
// read a file iCloud Drive has evicted as whatever the bytes on disk are.
//
// What is coordinated, and why, differs from `iosfs` in four places:
//   - A read open is coordinated and released once the file is open; a write open holds its
//     coordination until the file is closed. Holding every reader for its fd's life parks a
//     dispatch thread per open file and holds off the mirror's pass for as long as any reader in
//     the guest lives; holding writers means the mirror never reads half a note the guest is
//     writing.
//   - stat, readdir, readlink and utime are realfs's own: a coordinated stat of an evicted file
//     is a download of every file a listing touches.
//   - Every wait is bounded (`TOPO_ISH_VAULT_WAIT_SECONDS`, then `_EIO`) and ended by a SIGKILL to
//     the waiting task (`_EINTR`), since a host semaphore is not something the kernel's signal
//     wakes, and a task parked here would otherwise hold a teardown past its bound.
//   - `.topo` at the mount's root is the mirror's own (its baseline) and is refused `_EACCES`.
//
// Nothing here holds a kernel lock while it waits: the fs op is called with none of the mount,
// pid or spawn locks held, and the wait takes only the task's own signal lock, for a read.

#import <Foundation/Foundation.h>
#include <sys/stat.h>

#include "kernel/errno.h"
#include "kernel/fs.h"
#include "kernel/signal.h"
#include "kernel/task.h"
#include "fs/fd.h"
#include "fs/real.h"

#include "topo_ish.h"

// How often a waiting task looks for a SIGKILL.
static const int64_t slice_ns = 100 * NSEC_PER_MSEC;

extern const struct fs_ops topo_vaultfs;

// One coordination and the task waiting on it. The accessor and the waiter each look at it under
// its lock, so an access that lands at the moment the waiter gives up is either taken or never
// made, never both.
@interface TopoVaultWait : NSObject
@property (nonatomic) bool done;
@property (nonatomic) bool abandoned;
@property (nonatomic) int result;
@property (nonatomic) struct fd *fd;
@property (nonatomic, strong) dispatch_semaphore_t finished;
@end

@implementation TopoVaultWait
- (instancetype)init {
    if ((self = [super init])) {
        _finished = dispatch_semaphore_create(0);
        _result = 0;
    }
    return self;
}
@end

static NSURL *root_url(struct mount *mount) {
    return (__bridge NSURL *) mount->data;
}

static NSURL *url_in(struct mount *mount, const char *path) {
    while (path[0] == '/')
        path++;
    if (path[0] == '\0')
        return root_url(mount);
    return [root_url(mount) URLByAppendingPathComponent:[NSString stringWithUTF8String:path] isDirectory:NO];
}

// Whether `path` is the mirror's own folder or under it: `.topo` as the first name below the root.
static bool is_mirrors(const char *path) {
    while (path[0] == '/')
        path++;
    static const char name[] = ".topo";
    size_t n = sizeof(name) - 1;
    return strncmp(path, name, n) == 0 && (path[n] == '\0' || path[n] == '/');
}

static int posix_error(NSError *error) {
    while (error != nil) {
        if ([error.domain isEqualToString:NSPOSIXErrorDomain])
            return err_map((int) error.code);
        error = error.userInfo[NSUnderlyingErrorKey];
    }
    return _EIO;
}

static bool killed(void) {
    if (current == NULL)
        return false;
    lock(&current->sighand->lock);
    bool pending = sigset_has(current->pending, SIGKILL_);
    unlock(&current->sighand->lock);
    return pending;
}

// Waits for `wait` with the bound, in slices, looking for a SIGKILL between them. On giving up the
// wait is marked abandoned under its lock and the coordination cancelled; an access that already
// landed is taken instead.
static int await_coordination(TopoVaultWait *wait, NSFileCoordinator *coordinator) {
    int64_t waited = 0;
    const int64_t bound = (int64_t) TOPO_ISH_VAULT_WAIT_SECONDS * NSEC_PER_SEC;
    for (;;) {
        if (dispatch_semaphore_wait(wait.finished, dispatch_time(DISPATCH_TIME_NOW, slice_ns)) == 0)
            return wait.result;
        waited += slice_ns;
        bool kill = killed();
        if (!kill && waited < bound)
            continue;
        @synchronized (wait) {
            if (wait.done)
                return wait.result;
            wait.abandoned = true;
        }
        [coordinator cancel];
        return kill ? _EINTR : _EIO;
    }
}

// Runs `access` inside a coordination of `url` (and `other`, for a move) on a queue of its own and
// waits for it. `hold`, for a write open, keeps the coordination until it is signalled.
static int coordinated(NSURL *url, NSURL *other, bool writing, NSUInteger options,
                       int (^access)(NSURL *url, TopoVaultWait *wait), dispatch_semaphore_t hold) {
    NSFileCoordinator *coordinator = [[NSFileCoordinator alloc] initWithFilePresenter:nil];
    TopoVaultWait *wait = [TopoVaultWait new];
    void (^accessor)(NSURL *) = ^(NSURL *granted) {
        int result;
        @synchronized (wait) {
            if (wait.abandoned)
                return;
            result = access(granted, wait);
            wait.result = result;
            wait.done = true;
        }
        dispatch_semaphore_signal(wait.finished);
        if (hold != NULL && result == 0)
            dispatch_semaphore_wait(hold, DISPATCH_TIME_FOREVER);
    };
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSError *error = nil;
        if (other != nil) {
            [coordinator coordinateWritingItemAtURL:url options:NSFileCoordinatorWritingForMoving
                                   writingItemAtURL:other options:NSFileCoordinatorWritingForReplacing
                                              error:&error byAccessor:^(NSURL *from, NSURL *to) { accessor(from); }];
        } else if (writing) {
            [coordinator coordinateWritingItemAtURL:url options:options error:&error byAccessor:accessor];
        } else {
            [coordinator coordinateReadingItemAtURL:url options:options error:&error byAccessor:accessor];
        }
        if (error != nil) {
            @synchronized (wait) {
                if (wait.done || wait.abandoned)
                    return;
                wait.result = posix_error(error);
                wait.done = true;
            }
            dispatch_semaphore_signal(wait.finished);
        }
    });
    return await_coordination(wait, coordinator);
}

static int coordinated_write(struct mount *mount, const char *path, NSUInteger options,
                             int (^body)(void)) {
    if (is_mirrors(path))
        return _EACCES;
    return coordinated(url_in(mount, path), nil, true, options,
                       ^int(NSURL *url, TopoVaultWait *wait) { return body(); }, NULL);
}

// The fd ops are realfs's with the close replaced, so a held write lets go when its file closes.
static struct fd_ops vault_fdops;
static int vault_close(struct fd *fd);

static void make_fdops(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        vault_fdops = realfs_fdops;
        vault_fdops.close = vault_close;
    });
}

static int vault_close(struct fd *fd) {
    int err = realfs_close(fd);
    if (fd->fs_data != NULL) {
        dispatch_semaphore_t hold = (__bridge_transfer dispatch_semaphore_t) fd->fs_data;
        fd->fs_data = NULL;
        dispatch_semaphore_signal(hold);
    }
    return err;
}

static struct fd *vault_open(struct mount *mount, const char *path, int flags, int mode) {
    if (is_mirrors(path))
        return ERR_PTR(_EACCES);
    make_fdops();
    struct statbuf stat;
    int found = realfs_stat(mount, path, &stat);
    bool writing = (flags & O_ACCMODE_) != O_RDONLY_ || (flags & (O_CREAT_ | O_TRUNC_));
    bool regular = found == 0 && S_ISREG(stat.mode);
    bool creating = found == _ENOENT && (flags & O_CREAT_);
    if (!regular && !creating) {
        // A directory (a listing), or a name that is not there and is not being made.
        struct fd *fd = realfs_open(mount, path, flags, mode);
        if (!IS_ERR(fd))
            fd->ops = &vault_fdops;
        return fd;
    }

    __block struct fd *opened = NULL;
    dispatch_semaphore_t hold = writing ? dispatch_semaphore_create(0) : NULL;
    NSUInteger options = !writing ? 0
        : (flags & O_TRUNC_) ? NSFileCoordinatorWritingForReplacing : NSFileCoordinatorWritingForMerging;
    int err = coordinated(url_in(mount, path), nil, writing, options, ^int(NSURL *url, TopoVaultWait *wait) {
        struct fd *fd = realfs_open(mount, path, flags, mode);
        if (IS_ERR(fd))
            return (int) PTR_ERR(fd);
        fd->ops = &vault_fdops;
        if (hold != NULL)
            fd->fs_data = (__bridge_retained void *) hold;
        opened = fd;
        return 0;
    }, hold);
    if (err < 0)
        return ERR_PTR(err);
    return opened;
}

static int vault_mount(struct mount *mount) {
    int err = realfs.mount(mount);
    if (err < 0)
        return err;
    NSURL *url = [NSURL fileURLWithFileSystemRepresentation:mount->source isDirectory:YES relativeToURL:nil];
    mount->data = (void *) CFBridgingRetain(url);
    return 0;
}

// realfs has no umount, so the folder's descriptor would outlive the mount; a folder removed and
// made again at the same path is then reached through a mount made again, never this one.
static int vault_umount(struct mount *mount) {
    if (mount->data != NULL)
        CFBridgingRelease(mount->data);
    mount->data = NULL;
    close(mount->root_fd);
    return 0;
}

static int vault_unlink(struct mount *mount, const char *path) {
    return coordinated_write(mount, path, NSFileCoordinatorWritingForDeleting, ^{ return realfs_unlink(mount, path); });
}

static int vault_rmdir(struct mount *mount, const char *path) {
    return coordinated_write(mount, path, NSFileCoordinatorWritingForDeleting, ^{ return realfs_rmdir(mount, path); });
}

static int vault_mkdir(struct mount *mount, const char *path, mode_t_ mode) {
    return coordinated_write(mount, path, 0, ^{ return realfs_mkdir(mount, path, mode); });
}

static int vault_symlink(struct mount *mount, const char *target, const char *link) {
    return coordinated_write(mount, link, 0, ^{ return realfs_symlink(mount, target, link); });
}

static int vault_mknod(struct mount *mount, const char *path, mode_t_ mode, dev_t_ dev) {
    return coordinated_write(mount, path, 0, ^{ return realfs_mknod(mount, path, mode, dev); });
}

static int vault_link(struct mount *mount, const char *src, const char *dst) {
    if (is_mirrors(src))
        return _EACCES;
    return coordinated_write(mount, dst, 0, ^{ return realfs_link(mount, src, dst); });
}

static int vault_rename(struct mount *mount, const char *src, const char *dst) {
    if (is_mirrors(src) || is_mirrors(dst))
        return _EACCES;
    NSURL *from = url_in(mount, src), *to = url_in(mount, dst);
    return coordinated(from, to, true, 0, ^int(NSURL *url, TopoVaultWait *wait) {
        return realfs_rename(mount, src, dst);
    }, NULL);
}

static int vault_setattr(struct mount *mount, const char *path, struct attr attr) {
    // A size is the file's content; a mode or an owner is not.
    NSUInteger options = attr.type == attr_size ? NSFileCoordinatorWritingForMerging
                                                : NSFileCoordinatorWritingContentIndependentMetadataOnly;
    return coordinated_write(mount, path, options, ^{ return realfs_setattr(mount, path, attr); });
}

static int vault_stat(struct mount *mount, const char *path, struct statbuf *stat) {
    if (is_mirrors(path))
        return _EACCES;
    return realfs_stat(mount, path, stat);
}

static ssize_t vault_readlink(struct mount *mount, const char *path, char *buf, size_t size) {
    if (is_mirrors(path))
        return _EACCES;
    return realfs_readlink(mount, path, buf, size);
}

static int vault_utime(struct mount *mount, const char *path, struct timespec atime, struct timespec mtime) {
    if (is_mirrors(path))
        return _EACCES;
    return realfs_utime(mount, path, atime, mtime);
}

const struct fs_ops topo_vaultfs = {
    .name = "topo-vault", .magic = 0x746f706f,
    .mount = vault_mount,
    .umount = vault_umount,
    .statfs = realfs_statfs,

    .open = vault_open,
    .readlink = vault_readlink,
    .link = vault_link,
    .unlink = vault_unlink,
    .rmdir = vault_rmdir,
    .rename = vault_rename,
    .symlink = vault_symlink,
    .mknod = vault_mknod,
    .mkdir = vault_mkdir,

    .close = vault_close,
    .stat = vault_stat,
    .fstat = realfs_fstat,
    .setattr = vault_setattr,
    .fsetattr = realfs_fsetattr,
    .utime = vault_utime,
    .getpath = realfs_getpath,
    .flock = realfs_flock,
};
