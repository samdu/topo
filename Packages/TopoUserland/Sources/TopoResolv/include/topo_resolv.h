#ifndef TOPO_RESOLV_H
#define TOPO_RESOLV_H

#include <stddef.h>

/// Writes the name servers the system resolver is using now, as numeric addresses one a line,
/// into `out` (at most `size` bytes, NUL-terminated), and answers how many it wrote, or -1 when
/// the resolver's configuration could not be read.
int topo_system_nameservers(char *out, size_t size);

#endif
