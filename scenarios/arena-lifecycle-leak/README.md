# arena-lifecycle-leak

Sustained malformed-input load followed by forced GC, measuring RSS / native-heap / pool-leak deltas.

## What it tests

Zero-copy architectures rely on every request-scoped `Arena` being closed on every code path — including the error paths triggered by malformed input. If a parse-error branch leaks the Arena, the buffer is pinched and a sustained attack burns the pool.

This campaign drives `destructive-radamsa-h1`-style traffic for 10 minutes, then forces two GC cycles, then samples three signals:

1. **Process RSS** (`ps -o rss=`) — coarse but always available.
2. **NMT committed** (`jcmd <pid> VM.native_memory summary`) — requires the target to be launched with `-XX:NativeMemoryTracking=summary`.
3. **MemoryAllocator.stats().leakCount() delta** — requires the target to expose a diagnostic endpoint that returns `eu.exeris.kernel.spi.memory.MemoryStats`. If the endpoint isn't exposed, the metric is `null` in the sidecar.

## Pass / fail

```
rss_growth_pct        <= 5  AND  leak_count_delta == 0     → stable
rss_growth_pct        >  5                                 → leak-suspected
leak_count_delta      >  0                                 → leak-suspected
target exits during attack                                 → crash or oom
```

## Run

```bash
./scripts/run-arena-lifecycle-leak.sh \
    --base-url http://127.0.0.1:8080 \
    --target-pid <pid> \
    --duration 600 \
    --cooldown 60 \
    --radamsa-seed 42 \
    --memory-stats-endpoint /debug/exeris-memory-stats \
    --output results/raw/arena-lifecycle-leak-$(date +%Y%m%d-%H%M%S)
```

`--target-pid` is mandatory for RSS/NMT sampling. If the target is in a Docker container, pass the container PID (1 inside, or the host-visible PID).
