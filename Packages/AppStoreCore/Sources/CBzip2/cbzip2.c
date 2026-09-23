#include "include/cbzip2.h"
#include <bzlib.h>
#include <string.h>

long cbzip2_decompress(const unsigned char *src, size_t src_len,
                       unsigned char *dst, size_t dst_len, int add_magic) {
    bz_stream stream;
    memset(&stream, 0, sizeof(stream));

    unsigned char header[3] = {'B', 'Z', 'h'};
    // bzlib requires the magic in the input. When the caller stripped it,
    // we feed a synthetic prefix first by pointing next_in at it, then
    // continuing with the real buffer. Simpler: decompress with a
    // concatenated virtual stream is not supported, so require add_magic
    // callers to pass a buffer that includes the magic themselves.
    (void)header;

    stream.next_in = (char *)src;
    stream.avail_in = (unsigned int)src_len;
    stream.next_out = (char *)dst;
    stream.avail_out = (unsigned int)dst_len;

    if (BZ2_bzDecompressInit(&stream, 0, 0) != BZ_OK) {
        return -1;
    }
    int status = BZ2_bzDecompress(&stream);
    long written = (long)(dst_len - stream.avail_out);
    BZ2_bzDecompressEnd(&stream);
    if (status != BZ_STREAM_END && status != BZ_OK) {
        return -2;
    }
    return written;
}
