# destructive-radamsa-h2

Radamsa-mutated malformed HTTP/2 frame attack (H2C cleartext) against an externally-launched target.

## Attack shape

`runtime/drivers/radamsa-h2-attacker.py`:

1. Builds a seed H2C session: connection preface `PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n` followed by a SETTINGS frame, a HEADERS frame for `GET /plaintext`, and an END_STREAM-flagged empty DATA frame.
2. Mutates the post-preface byte stream via `radamsa --seed <SEED>`.
3. For each mutated variant: open a fresh TCP socket, send the preface (NEVER mutated — the target rejects the connection otherwise) + the mutated post-preface stream, then close.

The point is to stress the HTTP/2 frame parser and HPACK decoder with malformed length fields, illegal type values, and corrupt HPACK indexing.

## H2-over-TLS is out of scope

This scenario is H2C-only. TLS fuzzing belongs in the existing `docs/tls-zero-copy-benchmark-matrix.md` track. The reason: mixing TLS bytes-on-the-wire with a radamsa mutator means the mutations get rejected by the TLS record layer before reaching the H2 parser — the test stops testing what it claims.

## Run

```bash
./scripts/run-destructive-radamsa.sh \
    --base-url http://127.0.0.1:8080 \
    --protocol h2 \
    --rps 200 \
    --duration 120 \
    --cooldown 30 \
    --radamsa-seed 42 \
    --output results/raw/destructive-radamsa-h2-$(date +%Y%m%d-%H%M%S)
```

The liveness probe uses `curl --http2-prior-knowledge http://.../health`. If curl was compiled without `--http2`, the script fails fast with an explicit error.
