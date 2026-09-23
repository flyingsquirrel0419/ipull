#ifndef CZLIB_H
#define CZLIB_H

#include <stddef.h>

/// One-shot zlib (RFC 1950) inflate into a caller-provided buffer.
/// Returns the number of bytes written, or a negative value on error.
long czlib_inflate(const unsigned char *src, size_t src_len,
                   unsigned char *dst, size_t dst_len);

/// One-shot zlib deflate. Returns the number of bytes written, or a
/// negative value on error. dst must be at least czlib_deflate_bound bytes.
long czlib_deflate(const unsigned char *src, size_t src_len,
                   unsigned char *dst, size_t dst_len);

/// Upper bound for deflated output of src_len bytes.
size_t czlib_deflate_bound(size_t src_len);

#endif
