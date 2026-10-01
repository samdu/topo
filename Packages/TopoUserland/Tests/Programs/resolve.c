// A name looked up the way the guest's own programs look one up, through musl, for GuestDNSTests:
//
//   resolve NAME        getaddrinfo, one line per address: "A 10.0.0.1" or "AAAA fd00::1",
//                       or "gai <code>" when it fails
//   resolve -txt NAME   res_query for TXT, one line per string: "TXT <text>", then
//                       "bytes <reply length>", or "res_query failed" when it fails
//
// Linked against the guest's own musl (/lib/libc.musl-aarch64.so.1, the minirootfs's), so the
// lookup is the one every program in the guest makes; built against Alpine's musl-dev 1.2.5-r12
// (aarch64) and musl unpacked into a sysroot. `resolve` beside this file is its build, made with
// Homebrew's llvm and lld:
//
//   llvm=$(brew --prefix llvm)/bin; sysroot=<musl-dev and musl unpacked>
//   $llvm/clang --target=aarch64-linux-musl --sysroot=$sysroot -O1 -nostdlib -fuse-ld=lld \
//     --ld-path=$(brew --prefix lld)/bin/ld.lld -Wl,-dynamic-linker,/lib/ld-musl-aarch64.so.1 \
//     -o resolve $sysroot/usr/lib/Scrt1.o $sysroot/usr/lib/crti.o resolve.c \
//     $sysroot/lib/libc.musl-aarch64.so.1 $sysroot/usr/lib/crtn.o && $llvm/llvm-strip resolve

#include <arpa/inet.h>
#include <arpa/nameser.h>
#include <netdb.h>
#include <resolv.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>

static int txt(const char *name) {
    unsigned char reply[65536];
    int length = res_query(name, C_IN, T_TXT, reply, sizeof reply);
    if (length < 0) {
        printf("res_query failed\n");
        return 1;
    }
    ns_msg message;
    if (ns_initparse(reply, length, &message) < 0) {
        printf("unparsable\n");
        return 1;
    }
    for (int i = 0; i < ns_msg_count(message, ns_s_an); i++) {
        ns_rr rr;
        if (ns_parserr(&message, ns_s_an, i, &rr) < 0 || ns_rr_type(rr) != ns_t_txt) continue;
        const unsigned char *data = ns_rr_rdata(rr);
        int left = ns_rr_rdlen(rr);
        while (left > 0) {
            int size = data[0];
            if (size + 1 > left) break;
            printf("TXT %.*s\n", size, (const char *) data + 1);
            data += size + 1;
            left -= size + 1;
        }
    }
    printf("bytes %d\n", length);
    return 0;
}

int main(int argc, char **argv) {
    if (argc == 3 && strcmp(argv[1], "-txt") == 0) return txt(argv[2]);
    if (argc != 2) return 2;
    struct addrinfo hints = {.ai_family = AF_UNSPEC, .ai_socktype = SOCK_STREAM}, *found;
    int error = getaddrinfo(argv[1], NULL, &hints, &found);
    if (error != 0) {
        printf("gai %d\n", error);
        return 1;
    }
    for (struct addrinfo *at = found; at; at = at->ai_next) {
        char text[INET6_ADDRSTRLEN];
        if (at->ai_family == AF_INET) {
            inet_ntop(AF_INET, &((struct sockaddr_in *) at->ai_addr)->sin_addr, text, sizeof text);
            printf("A %s\n", text);
        } else {
            inet_ntop(AF_INET6, &((struct sockaddr_in6 *) at->ai_addr)->sin6_addr, text, sizeof text);
            printf("AAAA %s\n", text);
        }
    }
    freeaddrinfo(found);
    return 0;
}
