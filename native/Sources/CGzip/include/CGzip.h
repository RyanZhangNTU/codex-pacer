#ifndef PACER_GZIP_H
#define PACER_GZIP_H
#include <stddef.h>
#include <stdint.h>
/* 1 success, -1 malformed/empty/trailing input, -2 expansion limit exceeded. */
int pacer_gzip_decode(const uint8_t *bytes, size_t count, uint8_t *output, size_t maximum, size_t *written);
#endif
