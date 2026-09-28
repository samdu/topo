#include "topo_resolv.h"

#include <netdb.h>
#include <resolv.h>
#include <string.h>

int topo_system_nameservers(char *out, size_t size) {
    if (size == 0)
        return -1;
    out[0] = '\0';
    struct __res_state state;
    memset(&state, 0, sizeof(state));
    if (res_ninit(&state) != 0)
        return -1;
    union res_sockaddr_union addresses[8];
    int found = res_getservers(&state, addresses, 8);
    size_t used = 0;
    int written = 0;
    for (int i = 0; i < found; i++) {
        char host[NI_MAXHOST];
        socklen_t length = addresses[i].sin.sin_family == AF_INET6
            ? sizeof(struct sockaddr_in6) : sizeof(struct sockaddr_in);
        if (getnameinfo((struct sockaddr *)&addresses[i], length, host, sizeof(host), NULL, 0, NI_NUMERICHOST) != 0)
            continue;
        size_t hostLength = strlen(host);
        if (used + hostLength + 2 > size)
            break;
        memcpy(out + used, host, hostLength);
        used += hostLength;
        out[used++] = '\n';
        out[used] = '\0';
        written++;
    }
    res_ndestroy(&state);
    return written;
}
