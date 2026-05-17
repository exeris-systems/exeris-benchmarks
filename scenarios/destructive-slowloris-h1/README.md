# destructive-slowloris-h1

Slowloris-style slow-header attack against an externally-launched HTTP/1.1 target.

## Attack shape

`runtime/drivers/slowloris.py` opens `connection_count` TCP sockets to `${BASE_URL}` and on each writes:

```
GET /?slow=<random> HTTP/1.1\r\nHost: <host>\r\n
```

Then loops every `header_delay_seconds`, writing one fake header line per connection. **No** terminating `\r\n\r\n` is ever sent — connections sit half-open consuming server slots until the target's header-receive-timeout evicts them.

## Run

```bash
# Target must be launched externally first. Example:
#   targets/exeris-community-app/target/exeris-community-app.jar &
#   export BASE_URL=http://127.0.0.1:8080
#   tools/bench/lib/readiness.sh — wait for /health

./scripts/run-destructive-slowloris.sh \
    --base-url http://127.0.0.1:8080 \
    --connections 1000 \
    --header-delay 10 \
    --duration 120 \
    --cooldown 30 \
    --output results/raw/destructive-slowloris-h1-$(date +%Y%m%d-%H%M%S)
```

## Pass / fail

| Signal | stable | graceful-shed | timeout-flood | leak-suspected |
|---|---|---|---|---|
| post-attack liveness probe == 200 within 1s | ✓ | ✓ | ✗ | ✓ |
| RSS delta within tolerance | ✓ | ✓ | — | ✗ |
| hang_count (slow conns held > attack window) | 0 | > 0 | — | — |

`crash` and `oom` classes are only emitted if the target process exits during the attack.

## Confidentiality

slowloris produces no attacker-supplied corpus, so the campaign's `--publication-mode` may be `redacted` (not `internal-only`) — but the JFR recording covering the attack window MUST still be treated as raw JFR by `publish-report.sh`.
