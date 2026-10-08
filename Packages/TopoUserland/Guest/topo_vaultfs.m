// The memory's filesystem in the guest: the fork's realfs, with the file coordination the fork's
// own `app/iOSFS.m` puts around it, carried here because that file is part of the fork's app and
// not of anything its meson build makes. The vault is shared with Files, with whatever editor has
// it open, with iCloud Drive and with the mirror, and each of those reads and writes it under
// `NSFileCoordinator`; a guest that did not would read half a file somebody is saving, and would
// read a file iCloud Drive has evicted as whatever the bytes on disk are.
//
// What is coordinated, and why, differs from `iosfs` in four places:
//   - A read open is coordinated and released once the file is open; a write open holds its
//     coordination until the file is closed. Whether a read is of a regular file is judged on
//     what the open returned, not only on a stat before it, so a file made between the two is
//     read coordinated. Holding every reader for its fd's life parks a
//     dispatch thread per open file and holds off the mirror's pass for as long as any reader in
//     the guest lives; holding writers means the mirror never reads half a note the guest is
//     writing.
//   - stat, readdir, readlink and utime are realfs's own: a coordinated stat of an evicted file
//     is a download of every file a listing touches.
//   - Every wait is bounded (`TOPO_ISH_VAULT_WAIT_SECONDS`, then `_EIO`) and ended by a SIGKILL to
//     the waiting task (`_EINTR`), since a host semaphore is not something the kernel's signal
//     wakes, and a task parked here would otherwise hold a teardown past its bound.
//   - `.topo` at the mount's root is the mirror's own (its baseline) and is hidden: a listing of
//     the root leaves it out, anything that names it or a path under it is `_ENOENT`, a
//     name made under it included, and anything that would make `.topo` itself is `_EACCES`. A listing that showed a name nothing
//     could stat would fail every `ls` and `find` of a healthy vault.
//   - The host follows no link: every call is made from the path's folder, opened from the root
//     with `O_NOFOLLOW_ANY`, on a last name it does not follow either (`place_at`). The guest has
//     resolved its own links before a path gets here, but a folder on the way can have become a
//     link by the time the host walks it — the guest keeps what it resolved per thread for 100 ms
//     — and a host that followed it would reach `.topo`, or anywhere the app can, under a name
//     that is neither. So a path's text is the host's path, which is what `.topo` is judged by.
//
// Nothing here holds a kernel lock while it waits: the fs op is called with none of the mount,
// pid or spawn locks held, and the wait takes only the task's own signal lock, for a read.

#import <Foundation/Foundation.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>

#include "kernel/errno.h"
#include "kernel/fs.h"
#include "kernel/signal.h"
#include "kernel/task.h"
#include "fs/fd.h"
#include "fs/fix_path.h"
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

// Where a path's last name is, reached with no link followed: its folder opened from the vault's
// root with `O_NOFOLLOW_ANY`, which fails `ELOOP` on a link anywhere on the way, and the mount as
// realfs sees it with that folder for its root, so realfs's own call on the name walks nothing.
// The root itself is its own place.
struct place {
    struct mount mount;
    char name[MAX_PATH + 2];
};

static int place_at(struct mount *mount, const char *path, struct place *place) {
    while (path[0] == '/')
        path++;
    place->mount = *mount;
    const char *slash = strrchr(path, '/');
    int folder;
    if (slash == NULL) {
        folder = openat(mount->root_fd, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC);
        snprintf(place->name, sizeof(place->name), "%s%s", path[0] == '\0' ? "" : "/", path);
    } else {
        char parent[MAX_PATH];
        size_t length = (size_t) (slash - path);
        if (length >= sizeof(parent))
            return _ENAMETOOLONG;
        memcpy(parent, path, length);
        parent[length] = '\0';
        folder = openat(mount->root_fd, parent, O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC);
        snprintf(place->name, sizeof(place->name), "/%s", slash + 1);
    }
    if (folder < 0)
        return errno_map();
    place->mount.root_fd = folder;
    return 0;
}

static void place_close(struct place *place) {
    close(place->mount.root_fd);
}

// `body` on `path`'s place: the mount rooted at its folder, and its last name.
static int in_place(struct mount *mount, const char *path, int (^body)(struct mount *at, const char *name)) {
    struct place place;
    int err = place_at(mount, path, &place);
    if (err < 0)
        return err;
    err = body(&place.mount, place.name);
    place_close(&place);
    return err;
}

// `body` on the places of `src` and `dst`, for the two calls that name two paths.
static int in_places(struct mount *mount, const char *src, const char *dst,
                     int (^body)(int from, const char *from_name, int to, const char *to_name)) {
    struct place from, to;
    int err = place_at(mount, src, &from);
    if (err < 0)
        return err;
    err = place_at(mount, dst, &to);
    if (err < 0) {
        place_close(&from);
        return err;
    }
    err = body(from.mount.root_fd, fix_path(from.name), to.mount.root_fd, fix_path(to.name));
    place_close(&to);
    place_close(&from);
    return err;
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
    // Default, not user-initiated: a held write waits here on the guest thread that closes it.
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
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

// What a call that names the mirror's folder as something already there answers: there is no
// such name.
#define HIDDEN _ENOENT

// What a call that would make `path`, one of the mirror's, answers: `_EACCES` for the folder's
// own name, which is not the guest's to take, and `HIDDEN` for a name under it, whose folder is
// not there.
static int unmakeable(const char *path) {
    while (path[0] == '/')
        path++;
    return strchr(path, '/') == NULL ? _EACCES : HIDDEN;
}

// A change to `path`, made in its place under a coordinated write. The mirror's folder is
// answered for here as a name being made, which is what mkdir, symlink and mknod rely on; a
// caller that names it as something there answers `HIDDEN` before it calls.
static int coordinated_write(struct mount *mount, const char *path, NSUInteger options,
                             int (^body)(struct mount *at, const char *name)) {
    if (is_mirrors(path))
        return unmakeable(path);
    return coordinated(url_in(mount, path), nil, true, options,
                       ^int(NSURL *url, TopoVaultWait *wait) { return in_place(mount, path, body); }, NULL);
}

// The fd ops are realfs's with the close replaced, so a held write lets go when its file closes,
// and the listing, which leaves the mirror's folder out.
static struct fd_ops vault_fdops;
static int vault_close(struct fd *fd);
static int vault_readdir(struct fd *fd, struct dir_entry *entry);

static void make_fdops(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        vault_fdops = realfs_fdops;
        vault_fdops.close = vault_close;
        vault_fdops.readdir = vault_readdir;
    });
}

// Whether `fd` is the mount's root folder: the same file as the descriptor the mount holds. A
// folder has one name, so the device and the inode say so exactly.
static bool is_root(struct fd *fd) {
    struct stat opened, root;
    if (fd->mount == NULL || fstat(fd->real_fd, &opened) < 0 || fstat(fd->mount->root_fd, &root) < 0)
        return false;
    return opened.st_dev == root.st_dev && opened.st_ino == root.st_ino;
}

// realfs's listing, without the mirror's folder in the root's: `.topo` in any other folder is a
// name like any other, as `is_mirrors` has it.
static int vault_readdir(struct fd *fd, struct dir_entry *entry) {
    for (;;) {
        int err = realfs_readdir(fd, entry);
        if (err != 1 || strcmp(entry->name, ".topo") != 0 || !is_root(fd))
            return err;
    }
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

// The open of `path`'s last name in its place, with the vault's fd ops.
static struct fd *open_in_place(struct mount *mount, const char *path, int host_flags, int mode) {
    __block struct fd *fd = NULL;
    int err = in_place(mount, path, ^int(struct mount *at, const char *name) {
        fd = realfs_open(at, name, host_flags, mode);
        return IS_ERR(fd) ? (int) PTR_ERR(fd) : 0;
    });
    if (err < 0)
        return ERR_PTR(err);
    fd->ops = &vault_fdops;
    return fd;
}

static struct fd *vault_open(struct mount *mount, const char *path, int flags, int mode) {
    if (is_mirrors(path))
        return ERR_PTR(flags & O_CREAT_ ? unmakeable(path) : HIDDEN);
    make_fdops();
    // The guest followed the last name's link, if it was one, before the path got here: the
    // host follows none.
    int host_flags = flags | O_NOFOLLOW_;
    bool writing = (flags & O_ACCMODE_) != O_RDONLY_ || (flags & (O_CREAT_ | O_TRUNC_));
    if (!writing) {
        // A read of a regular file is coordinated. A stat that finds one goes straight to the
        // coordination, since an evicted file is opened only under it (the coordination is what
        // brings it down). Anything else is opened as it is and judged again on the descriptor:
        // a file made between the stat and the open would otherwise be read uncoordinated while
        // its writer holds it, so a regular file found there is let go and opened again under the
        // coordination, as is a name whose open failed on anything but its absence.
        __block struct statbuf stat;
        int found = in_place(mount, path, ^int(struct mount *at, const char *name) { return realfs_stat(at, name, &stat); });
        if (!(found == 0 && S_ISREG(stat.mode))) {
            struct fd *fd = open_in_place(mount, path, host_flags, mode);
            if (IS_ERR(fd) && PTR_ERR(fd) == _ENOENT)
                return fd;
            if (!IS_ERR(fd)) {
                struct stat opened;
                if (fstat(fd->real_fd, &opened) == 0 && !S_ISREG(opened.st_mode))
                    return fd;
                fd_close(fd);
            }
        }
    }

    // Every write open is coordinated whatever is at the name, since an open for writing changes
    // the file (`O_TRUNC`) before anything could look at what it opened.
    __block struct fd *opened = NULL;
    dispatch_semaphore_t hold = writing ? dispatch_semaphore_create(0) : NULL;
    NSUInteger options = !writing ? 0
        : (flags & O_TRUNC_) ? NSFileCoordinatorWritingForReplacing : NSFileCoordinatorWritingForMerging;
    int err = coordinated(url_in(mount, path), nil, writing, options, ^int(NSURL *url, TopoVaultWait *wait) {
        struct fd *fd = open_in_place(mount, path, host_flags, mode);
        if (IS_ERR(fd))
            return (int) PTR_ERR(fd);
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
    if (is_mirrors(path))
        return HIDDEN;
    return coordinated_write(mount, path, NSFileCoordinatorWritingForDeleting,
                             ^(struct mount *at, const char *name) { return realfs_unlink(at, name); });
}

static int vault_rmdir(struct mount *mount, const char *path) {
    if (is_mirrors(path))
        return HIDDEN;
    return coordinated_write(mount, path, NSFileCoordinatorWritingForDeleting,
                             ^(struct mount *at, const char *name) { return realfs_rmdir(at, name); });
}

static int vault_mkdir(struct mount *mount, const char *path, mode_t_ mode) {
    return coordinated_write(mount, path, 0, ^(struct mount *at, const char *name) { return realfs_mkdir(at, name, mode); });
}

static int vault_symlink(struct mount *mount, const char *target, const char *link) {
    return coordinated_write(mount, link, 0, ^(struct mount *at, const char *name) { return realfs_symlink(at, target, name); });
}

static int vault_mknod(struct mount *mount, const char *path, mode_t_ mode, dev_t_ dev) {
    return coordinated_write(mount, path, 0, ^(struct mount *at, const char *name) { return realfs_mknod(at, name, mode, dev); });
}

static int vault_link(struct mount *mount, const char *src, const char *dst) {
    if (is_mirrors(src))
        return HIDDEN;
    if (is_mirrors(dst))
        return unmakeable(dst);
    return coordinated(url_in(mount, dst), nil, true, 0, ^int(NSURL *url, TopoVaultWait *wait) {
        return in_places(mount, src, dst, ^int(int from, const char *from_name, int to, const char *to_name) {
            return linkat(from, from_name, to, to_name, 0) < 0 ? errno_map() : 0;
        });
    }, NULL);
}

static int vault_rename(struct mount *mount, const char *src, const char *dst) {
    if (is_mirrors(src))
        return HIDDEN;
    if (is_mirrors(dst))
        return unmakeable(dst);
    NSURL *from = url_in(mount, src), *to = url_in(mount, dst);
    return coordinated(from, to, true, 0, ^int(NSURL *url, TopoVaultWait *wait) {
        return in_places(mount, src, dst, ^int(int from, const char *from_name, int to, const char *to_name) {
            return renameat(from, from_name, to, to_name) < 0 ? errno_map() : 0;
        });
    }, NULL);
}

// realfs's setattr and utime follow a link in the last name; these follow none.
static int vault_setattr(struct mount *mount, const char *path, struct attr attr) {
    if (is_mirrors(path))
        return HIDDEN;
    // A size is the file's content; a mode or an owner is not.
    NSUInteger options = attr.type == attr_size ? NSFileCoordinatorWritingForMerging
                                                : NSFileCoordinatorWritingContentIndependentMetadataOnly;
    return coordinated_write(mount, path, options, ^int(struct mount *at, const char *name) {
        const char *last = fix_path(name);
        int folder = at->root_fd;
        switch (attr.type) {
        case attr_uid:
        case attr_gid: {
            uid_t owner = attr.type == attr_uid ? attr.uid : (uid_t) -1;
            gid_t group = attr.type == attr_gid ? attr.gid : (gid_t) -1;
            if (fchownat(folder, last, owner, group, AT_SYMLINK_NOFOLLOW) < 0)
                return errno == EPERM ? 0 : errno_map(); // not root on the host, as realfs has it
            return 0;
        }
        case attr_mode:
            return fchmodat(folder, last, attr.mode, AT_SYMLINK_NOFOLLOW) < 0 ? errno_map() : 0;
        case attr_size: {
            int fd = openat(folder, last, O_RDWR | O_NOFOLLOW | O_CLOEXEC);
            if (fd < 0)
                return errno_map();
            int err = ftruncate(fd, attr.size) < 0 ? errno_map() : 0;
            close(fd);
            return err;
        }
        default:
            return realfs_setattr(at, name, attr);
        }
    });
}

static int vault_stat(struct mount *mount, const char *path, struct statbuf *stat) {
    if (is_mirrors(path))
        return HIDDEN;
    return in_place(mount, path, ^int(struct mount *at, const char *name) { return realfs_stat(at, name, stat); });
}

static ssize_t vault_readlink(struct mount *mount, const char *path, char *buf, size_t size) {
    if (is_mirrors(path))
        return HIDDEN;
    __block ssize_t length = 0;
    int err = in_place(mount, path, ^int(struct mount *at, const char *name) {
        length = realfs_readlink(at, name, buf, size);
        return length < 0 ? (int) length : 0;
    });
    return err < 0 ? err : length;
}

static int vault_utime(struct mount *mount, const char *path, struct timespec atime, struct timespec mtime) {
    if (is_mirrors(path))
        return HIDDEN;
    return in_place(mount, path, ^int(struct mount *at, const char *name) {
        struct timespec times[2] = {atime, mtime};
        return utimensat(at->root_fd, fix_path(name), times, AT_SYMLINK_NOFOLLOW) < 0 ? errno_map() : 0;
    });
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
