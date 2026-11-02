# Bounded gzip decoding

This target builds only zlib's inflate and checksum files, pinned to zlib 1.3.2
at `da607da739fa6047df13e66a2af6b8bec7c2a498`. The original files and license are
in `vendor`; `provenance.json` records their SHA-256 values and upstream source.
`Z_PREFIX` isolates the symbols from the Mac system zlib.

`pacer_gzip_decode` accepts one complete gzip member, checks its checksum, rejects
trailing or concatenated members, and limits output to the caller's byte budget.
Both hosts use this decoder for Claude's bounded OTLP HTTP body.
