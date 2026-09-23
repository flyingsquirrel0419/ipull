#ifndef CBZIP2_H
#define CBZIP2_H

#include <stddef.h>

/// One-shot bzip2 decompression. The input may be missing the leading
/// "BZh" magic (Apple's Payload raw stream starts after it) — pass
/// add_magic=1 to prepend a synthetic header.
/// Returns bytes written, or a negative value on error.
long cbzip2_decompress(const unsigned char *src, size_t src_len,
                       unsigned char *dst, size_t dst_len, int add_magic);

#endif
