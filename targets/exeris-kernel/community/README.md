# targets/exeris-kernel/community

This directory contains configuration for running benchmarks against the
**Exeris Kernel Community** target.

## Files

| File | Purpose |
|---|---|
| `wrk-target.env` | wrk/wrk2 base URL and run parameters |
| `h2load-target.env` | h2load base URL and run parameters |

## How to use

```bash
# HTTP/1.1 plaintext (wrk)
./scripts/run-wrk.sh targets/exeris-kernel/community scenarios/plaintext

# HTTP/2 plaintext (h2load)
./scripts/run-h2load.sh targets/exeris-kernel/community scenarios/plaintext

# Start / stop the target via Docker
./runtime/drivers/start-target.sh community
./runtime/drivers/stop-target.sh community
```

## Notes

- Set `EXERIS_COMMUNITY_IMAGE` env var to override the Docker image.
- Pure mode only — this target does not include Spring Runtime.
- HTTP/2 requires a valid TLS certificate; use `--insecure` for self-signed certs.
