# destructive-radamsa-h1

Radamsa-mutated malformed HTTP/1.1 input attack against an externally-launched target.

## Attack shape

`runtime/drivers/radamsa-h1-attacker.py` reads a seed request from stdin (default: `GET /plaintext HTTP/1.1\r\nHost: localhost\r\n\r\n`), pipes it through `radamsa --seed <SEED>` to produce N mutated variants, and fires each over a fresh `socket.socket()` TCP connection at the target. Each connection is closed after the response (or after `--socket-timeout` if no response arrives).

## Prerequisite

`radamsa` must be on PATH. Install: `git clone https://gitlab.com/akihe/radamsa && cd radamsa && make && sudo make install`. The script bails with a clear error if `radamsa` is missing.

## Run

```bash
./scripts/run-destructive-radamsa.sh \
    --base-url http://127.0.0.1:8080 \
    --protocol h1 \
    --rps 500 \
    --duration 120 \
    --cooldown 30 \
    --radamsa-seed 42 \
    --output results/raw/destructive-radamsa-h1-$(date +%Y%m%d-%H%M%S)
```

`--radamsa-seed` is REQUIRED. Without it the campaign is not reproducible and the artifact is descriptive-only.

## Pass / fail

Same `degradation_class` semantics as `destructive-slowloris-h1`. Additional `crash_count` is incremented per mutated input that produces a 5xx or kills the connection abnormally.
