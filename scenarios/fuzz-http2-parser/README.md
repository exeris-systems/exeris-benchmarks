# fuzz-http2-parser

Jazzer fuzz campaign against `eu.exeris.kernel.core.http.http2.Http2FrameParser.parseHeader`.

## What it tests

The HTTP/2 frame header (RFC 7540 §4.1) is a 9-byte fixed structure:

```
0                   1                   2                   3
0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                 Length (24)                   |    Type (8)   |
+---------------+---------------+---------------+---------------+
|   Flags (8)   |R|                 Stream Identifier (31)      |
+-+-------------+---------------+-------------------------------+
```

Fuzz iterations with `byte[].length < 9` short-circuit. Otherwise the byte[] is copied into a confined `Arena` `MemorySegment` and `parseHeader(seg, 0)` is invoked.

## Pass / fail

Pass = zero unexpected throwables, zero hangs.
Fail semantics identical to `fuzz-http1-parser`.

## Run

```bash
./scripts/run-fuzz-campaign.sh scenarios/fuzz-http2-parser --duration 60s
```
