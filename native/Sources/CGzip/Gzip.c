#include "CGzip.h"
#include "vendor/zlib.h"
#include <limits.h>
#include <string.h>
#include <stdlib.h>

static voidpf pacer_gzip_allocate(voidpf context, uInt items, uInt size) {
    (void)context;
    if (items != 0 && size > SIZE_MAX / items) return NULL;
    return calloc(items, size);
}
static void pacer_gzip_free(voidpf context, voidpf pointer) { (void)context; free(pointer); }

int pacer_gzip_decode(const uint8_t *bytes, size_t count, uint8_t *output, size_t maximum, size_t *written) {
    if (bytes == NULL || output == NULL || written == NULL || count == 0 || count > UINT_MAX || maximum >= UINT_MAX) return -1;
    z_stream stream;
    memset(&stream, 0, sizeof(stream));
    stream.zalloc = pacer_gzip_allocate; stream.zfree = pacer_gzip_free;
    if (inflateInit2(&stream, MAX_WBITS + 16) != Z_OK) return -1;
    stream.next_in = (Bytef *)bytes; stream.avail_in = (uInt)count;
    stream.next_out = output; stream.avail_out = (uInt)(maximum + 1);
    int result = -1;
    while (1) {
        uLong before_in = stream.total_in, before_out = stream.total_out;
        int status = inflate(&stream, Z_NO_FLUSH);
        if (stream.total_out > maximum) { result = -2; break; }
        if (status == Z_STREAM_END) {
            if (stream.avail_in == 0 && stream.total_out != 0) { *written = stream.total_out; result = 1; }
            break;
        }
        if (status != Z_OK || (stream.total_in == before_in && stream.total_out == before_out)) break;
    }
    inflateEnd(&stream);
    return result;
}
