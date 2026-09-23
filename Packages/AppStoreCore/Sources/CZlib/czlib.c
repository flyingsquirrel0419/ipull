#include "include/czlib.h"
#include <zlib.h>

long czlib_inflate(const unsigned char *src, size_t src_len,
                   unsigned char *dst, size_t dst_len) {
    z_stream stream;
    stream.zalloc = Z_NULL;
    stream.zfree = Z_NULL;
    stream.opaque = Z_NULL;
    stream.next_in = (Bytef *)src;
    stream.avail_in = (uInt)src_len;
    stream.next_out = dst;
    stream.avail_out = (uInt)dst_len;

    if (inflateInit(&stream) != Z_OK) {
        return -1;
    }
    int status = inflate(&stream, Z_FINISH);
    inflateEnd(&stream);
    if (status != Z_STREAM_END && status != Z_OK) {
        return -2;
    }
    return (long)(dst_len - stream.avail_out);
}

long czlib_deflate(const unsigned char *src, size_t src_len,
                   unsigned char *dst, size_t dst_len) {
    uLongf bound = compressBound((uLong)src_len);
    if (dst_len < bound) {
        return -1;
    }
    if (compress(dst, &bound, src, (uLong)src_len) != Z_OK) {
        return -2;
    }
    return (long)bound;
}

size_t czlib_deflate_bound(size_t src_len) {
    return (size_t)compressBound((uLong)src_len);
}
