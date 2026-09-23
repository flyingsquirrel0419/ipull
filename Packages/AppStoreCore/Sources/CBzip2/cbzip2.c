#include "include/cbzip2.h"
#include <bzlib.h>
#include <stdlib.h>
#include <string.h>

long cbzip2_decompress(const unsigned char *src, size_t src_len,
                       unsigned char *dst, size_t dst_len, int add_magic) {
    (void)add_magic;
    bz_stream stream;
    memset(&stream, 0, sizeof(stream));
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

struct cbzip2_stream {
    bz_stream inner;
    int finished;
};

CBzip2Stream *cbzip2_stream_init(void) {
    CBzip2Stream *s = calloc(1, sizeof(CBzip2Stream));
    if (!s) return NULL;
    if (BZ2_bzDecompressInit(&s->inner, 0, 0) != BZ_OK) {
        free(s);
        return NULL;
    }
    return s;
}

long cbzip2_stream_decompress(CBzip2Stream *s,
                              const unsigned char *src, size_t src_len,
                              size_t *src_consumed,
                              unsigned char *dst, size_t dst_len) {
    if (!s || s->finished) return -3;
    s->inner.next_in = (char *)src;
    s->inner.avail_in = (unsigned int)src_len;
    s->inner.next_out = (char *)dst;
    s->inner.avail_out = (unsigned int)dst_len;

    unsigned int before_in = s->inner.avail_in;
    int status = BZ2_bzDecompress(&s->inner);
    if (src_consumed) *src_consumed = before_in - s->inner.avail_in;
    long written = (long)(dst_len - s->inner.avail_out);
    if (status == BZ_STREAM_END) s->finished = 1;
    if (status != BZ_OK && status != BZ_STREAM_END) return -2;
    return written;
}

int cbzip2_stream_finished(CBzip2Stream *s) {
    return s ? s->finished : 0;
}

void cbzip2_stream_end(CBzip2Stream *s) {
    if (!s) return;
    BZ2_bzDecompressEnd(&s->inner);
    free(s);
}
