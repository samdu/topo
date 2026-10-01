// The address the guest's socket layer reports for a name server, for GuestDNSTests: one line of
// what each call returned, so the test can hold the guest's DNS stub rewrite
// (patches/ish/0006-dns-sentinel.patch) to the address itself rather than to a lookup working.
//
//   dnsaddr udp 4|6 HOST PORT   a query for a.example sent three ways to HOST:PORT, on an AF_INET
//                               or AF_INET6 socket: "recvfrom=<from> recvmsg=<from>
//                               getpeername=<peer> reply=<1|none>" — the source recvfrom
//                               returned for the reply to a sendto, the source recvmsg returned
//                               for the reply to a sendmsg, the peer of a connected socket and
//                               whether its reply came
//   dnsaddr tcp 4|6 HOST PORT   a connect: "getpeername=<peer>", or "connect=<-errno>"
//
// An address prints as "<4|6> <address> <port>", and "none" when nothing came within 2 s.
//
// Linked against the guest's own musl (/lib/libc.musl-aarch64.so.1, the minirootfs's), as
// `resolve` is; built against Alpine's musl-dev 1.2.5-r12 (aarch64) and musl unpacked into a
// sysroot. `dnsaddr` beside this file is its build, made with Homebrew's llvm and lld:
//
//   llvm=$(brew --prefix llvm)/bin; sysroot=<musl-dev and musl unpacked>
//   $llvm/clang --target=aarch64-linux-musl --sysroot=$sysroot -O1 -nostdlib -fuse-ld=lld \
//     --ld-path=$(brew --prefix lld)/bin/ld.lld -Wl,-dynamic-linker,/lib/ld-musl-aarch64.so.1 \
//     -o dnsaddr $sysroot/usr/lib/Scrt1.o $sysroot/usr/lib/crti.o dnsaddr.c \
//     $sysroot/lib/libc.musl-aarch64.so.1 $sysroot/usr/lib/crtn.o && $llvm/llvm-strip dnsaddr

#include <arpa/inet.h>
#include <errno.h>
#include <poll.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

static void put(const char *s) { write(1, s, strlen(s)); }

static void num(long v) {
    char b[24]; int i = 23; b[i] = 0;
    int neg = v < 0; if (neg) v = -v;
    do { b[--i] = '0' + v % 10; v /= 10; } while (v);
    if (neg) b[--i] = '-';
    put(b + i);
}

static void address(const struct sockaddr_storage *a) {
    char text[INET6_ADDRSTRLEN];
    if (a->ss_family == AF_INET) {
        const struct sockaddr_in *in = (const void *) a;
        put("4 "); put(inet_ntop(AF_INET, &in->sin_addr, text, sizeof text)); put(" "); num(ntohs(in->sin_port));
    } else if (a->ss_family == AF_INET6) {
        const struct sockaddr_in6 *in6 = (const void *) a;
        put("6 "); put(inet_ntop(AF_INET6, &in6->sin6_addr, text, sizeof text)); put(" "); num(ntohs(in6->sin6_port));
    } else {
        put("family "); num(a->ss_family);
    }
}

static const unsigned char query[] = {
    0x12, 0x34, 0x01, 0, 0, 1, 0, 0, 0, 0, 0, 0,
    1, 'a', 7, 'e', 'x', 'a', 'm', 'p', 'l', 'e', 0, 0, 1, 0, 1,
};

static int target(int family, const char *host, int port, struct sockaddr_storage *out, socklen_t *length) {
    memset(out, 0, sizeof *out);
    if (family == AF_INET) {
        struct sockaddr_in *in = (void *) out;
        in->sin_family = AF_INET;
        in->sin_port = htons(port);
        *length = sizeof *in;
        return inet_pton(AF_INET, host, &in->sin_addr) == 1 ? 0 : -1;
    }
    struct sockaddr_in6 *in6 = (void *) out;
    in6->sin6_family = AF_INET6;
    in6->sin6_port = htons(port);
    *length = sizeof *in6;
    return inet_pton(AF_INET6, host, &in6->sin6_addr) == 1 ? 0 : -1;
}

static int open_socket(int family, int type) { return socket(family, type, 0); }

// Whether a reply is waiting within 2 s: the guest's blocking receive takes no SO_RCVTIMEO.
static int arrives(int fd) {
    struct pollfd p = {fd, POLLIN, 0};
    return poll(&p, 1, 2000) == 1;
}

int main(int argc, char **argv) {
    if (argc != 5) return 2;
    int family = strcmp(argv[2], "6") == 0 ? AF_INET6 : AF_INET;
    struct sockaddr_storage to, from;
    socklen_t to_length, from_length;
    if (target(family, argv[3], atoi(argv[4]), &to, &to_length) < 0) return 2;
    unsigned char reply[512];

    if (strcmp(argv[1], "tcp") == 0) {
        int fd = open_socket(family, SOCK_STREAM);
        if (connect(fd, (void *) &to, to_length) < 0) { put("connect="); num(-errno); put("\n"); return 0; }
        from_length = sizeof from;
        put("getpeername=");
        if (getpeername(fd, (void *) &from, &from_length) == 0) address(&from); else num(-errno);
        put("\n");
        return 0;
    }

    int fd = open_socket(family, SOCK_DGRAM);
    sendto(fd, query, sizeof query, 0, (void *) &to, to_length);
    from_length = sizeof from;
    put("recvfrom=");
    if (arrives(fd) && recvfrom(fd, reply, sizeof reply, 0, (void *) &from, &from_length) > 0) address(&from); else put("none");
    close(fd);

    fd = open_socket(family, SOCK_DGRAM);
    struct iovec out = {(void *) query, sizeof query};
    struct msghdr sent = {.msg_name = &to, .msg_namelen = to_length, .msg_iov = &out, .msg_iovlen = 1};
    sendmsg(fd, &sent, 0);
    struct iovec iov = {reply, sizeof reply};
    struct msghdr msg = {.msg_name = &from, .msg_namelen = sizeof from, .msg_iov = &iov, .msg_iovlen = 1};
    put(" recvmsg=");
    if (arrives(fd) && recvmsg(fd, &msg, 0) > 0) address(&from); else put("none");
    close(fd);

    fd = open_socket(family, SOCK_DGRAM);
    put(" getpeername=");
    if (connect(fd, (void *) &to, to_length) < 0) {
        put("connect "); num(-errno);
    } else {
        from_length = sizeof from;
        if (getpeername(fd, (void *) &from, &from_length) == 0) address(&from); else num(-errno);
    }
    send(fd, query, sizeof query, 0);
    put(" reply=");
    put(arrives(fd) && recv(fd, reply, sizeof reply, 0) > 0 ? "1" : "none");
    put("\n");
    return 0;
}
