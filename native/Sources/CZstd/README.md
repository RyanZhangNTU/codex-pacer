# CZstd

Decompression-only sources from [Zstandard](https://github.com/facebook/zstd) v1.5.7 (commit f8745da), copied unmodified from `lib/common`, `lib/decompress`, `zstd.h` and `zstd_errors.h`. Pacer uses it to read DeepSeek Harness session logs, which are concatenated Zstandard frames. The x86-64 Huffman assembly is excluded and disabled with `ZSTD_DISABLE_ASM`; compression, dictionary building, legacy formats and threading are not built. Licensed under the BSD terms in `LICENSE`.
