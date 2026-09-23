#ifndef CBZIP2_H
#define CBZIP2_H

#include <stddef.h>

/// One-shot bzip2 decompression.
long cbzip2_decompress(const unsigned char *src, size_t src_len,
                       unsigned char *dst, size_t dst_len, int add_magic);

/// Streaming decompressor for large inputs (device: ~3.6 GB SAP payload).
/// Opaque state; init once, feed chunks, end when finished.
typedef struct cbzip2_stream CBzip2Stream;
CBzip2Stream *cbzip2_stream_init(void);
/// Feed src (src_len bytes) and write up to dst_len decompressed bytes to dst.
/// Sets *src_consumed. Returns bytes written, or negative on error.
long cbzip2_stream_decompress(CBzip2Stream *s,
                              const unsigned char *src, size_t src_len,
                              size_t *src_consumed,
                              unsigned char *dst, size_t dst_len);
int  cbzip2_stream_finished(CBzip2Stream *s);
void cbzip2_stream_end(CBzip2Stream *s);

#endif
