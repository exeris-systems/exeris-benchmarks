# micro/jmh — JMH Microbenchmarks

Standalone Maven module. Imports Exeris artifacts as dependencies — does not
contain product source.

## Build

```bash
mvn clean package -DskipTests
```

This produces `target/benchmarks.jar` (uber-jar with JMH launcher).

## Run all benchmarks

```bash
java -jar target/benchmarks.jar -wi 5 -i 10 -f 3
```

## Run a specific benchmark

```bash
java -jar target/benchmarks.jar RouteRegistry -wi 5 -i 10 -f 3
```

## Run with allocation profiler (Linux, async-profiler or jmh gc prof)

```bash
java -jar target/benchmarks.jar JsonCodec -prof gc -wi 5 -i 10 -f 3
```

Expected on zero-alloc codec path: `·gc.alloc.rate.norm ≈ 0 B/op`

## Run with JSON output for CI comparison

```bash
java -jar target/benchmarks.jar -rf json -rff results.json -wi 5 -i 10 -f 3
```

Or use the repo script:

```bash
../../scripts/run-jmh.sh RouteRegistry
```

## Available benchmark classes

| Class | Path claim | Key assertion |
|---|---|---|
| `RouteRegistryBenchmark` | Route lookup | O(1) dispatch, no allocation |
| `JsonCodecBenchmark` | JSON encode/decode | Zero-alloc on hot encode path |
| `RequestWrapperBenchmark` | Request construction | Lazy zero-copy header access |
| `ResponseBuilderBenchmark` | Response builder | Minimal allocation per response |
| `SslEngineTlsBenchmark` | TLS 1.3 record path (JDK SSLEngine) | Comparative baseline B3 |
| `NettyTcNativeTlsBenchmark` | TLS 1.3 Netty pipeline path (`SslHandler` + `EmbeddedChannel` over netty-tcnative) | Comparative baseline B4 |
| `ExerisCommunityTlsBenchmark` | TLS 1.3 record path (Exeris SPI-native `TlsEngine`, Community FD-owner/socket harness) | Comparative variant B6 (SPI-native, includes kernel I/O) |
| `OffHeapTlsEngineMemoryBioBenchmark` | TLS 1.3 OffHeapTlsEngine engine-level lens (neutral in-process Memory-BIO harness) | Comparative variant B5 (engine-level in-process BIO lens) |

## Primary comparative set

For TCP TLS 1.3 record-path analysis, use `B3`/`B4`/`B5` as the primary
engine-level comparator set: `SslEngineTlsBenchmark`, `NettyTcNativeTlsBenchmark`,
and `OffHeapTlsEngineMemoryBioBenchmark`.
Use `B6` as an integration-level lens with explicit transport wiring caveats.
`B4` in this repository is the pipeline path (`SslHandler` +
`EmbeddedChannel`) and is not split into B4a/B4b.

## Mandatory comparative evidence (B3/B4/B5/B6)

- JMH throughput (ops/s)
- JMH sample-time latency (us/op with p50/p95/p99 where available)
- heap allocation (`gc.alloc.rate.norm`)
- JFR allocation evidence (`ObjectAllocationSample` stacks)
- CPU hotspot profile (top methods / percent)
- RSS and native footprint snapshot
- native footprint setup delta: RSS at trial @Setup completion vs RSS at measurement end
- allocator model label per row (GC-managed / pooled-direct / off-heap)
- explicit buffer model, transport model, and allocator model labels (all three required per row)

Do not publish cross-row claims when these dimensions are missing.

## TLS SPI-native harness contract

The old unified TLS comparative harness was split into a shared support base plus
tier-specific transport harnesses:

- `AbstractExerisTlsBenchmarkSupport`: shared static setup helpers, provider/memory
   resolution, and common benchmark support utilities.
- `AbstractCommunityTlsBenchmark` (B6): FD-owner socket transport. OpenSSL is bound
   to a real socket fd via `SSL_set_fd`; setup uses loopback
   `ServerSocketChannel` + `SocketChannel`, fd reflection extraction,
   `bindFileDescriptor(int fd)`, `notifyBound()`, and virtual-thread handshake.
   A persistent drain thread prevents send-buffer saturation in
   `wrapThroughput`.
Benchmark exposure by tier:

- `ExerisCommunityTlsBenchmark` (B6): `wrapThroughput` only.

Property resolution order is always tier-specific first, then global fallback.

Provider class lookup:

1. `exeris.tls.<tier>.cryptoProviderClass`
2. `exeris.tls.cryptoProviderClass`
3. Backward-compatible alias: `exeris.tls.<tier>.providerClass`, then `exeris.tls.providerClass`
4. Backward-compatible alias: `exeris.tls.<tier>.provider`, then `exeris.tls.provider`

Memory provider class lookup:

1. `exeris.tls.<tier>.memoryProviderClass`
2. `exeris.tls.memoryProviderClass`
3. Backward-compatible alias: `exeris.tls.<tier>.memoryProvider`, then `exeris.tls.memoryProvider`

Additional config values (same precedence rule):

1. `certPem` (`exeris.tls.<tier>.certPem`, `exeris.tls.certPem`) - required
2. `keyPem` (`exeris.tls.<tier>.keyPem`, `exeris.tls.keyPem`) - required

Examples:

```bash
java \
   -Dexeris.tls.community.cryptoProviderClass=com.acme.bench.CommunityKernelCryptoProvider \
   -Dexeris.tls.community.memoryProviderClass=com.acme.bench.CommunityMemoryProvider \
   -Dexeris.tls.community.certPem=/tmp/community-cert.pem \
   -Dexeris.tls.community.keyPem=/tmp/community-key.pem \
   -jar target/benchmarks.jar ExerisCommunityTlsBenchmark

## Comparative caveat: B3/B4 vs B6/B5

- `B3` and `B4` remain fixed external baselines, but they do not use the same wiring: `B3` is direct JDK `SSLEngine`, `B4` is Netty `SslHandler` on `EmbeddedChannel` backed by netty-tcnative.
- `B6` and `B5` are Exeris SPI-native `TlsEngine` variants and are only valid when provider wiring is explicitly configured.
- Do not collapse B3/B4 and B6/B5 conclusions without stating implementation and wiring differences, and do not treat B3 vs B4 as a handler-free apples-to-apples comparison.

## Wiring to real Exeris API

All benchmark classes contain `// TODO: replace with ExerisXxx(...)` stubs.
To wire up real Exeris code:

1. Uncomment the dependency block in `pom.xml` for the relevant module.
2. Ensure the Exeris artifact is installed in your local Maven repo:
   ```bash
   cd path/to/exeris-kernel
   mvn install -DskipTests
   ```
3. Replace the stub bodies in each benchmark class with the real API calls.
4. Rebuild and verify: `mvn clean package -DskipTests && java -jar target/benchmarks.jar -wi 1 -i 1 -f 1`

## JVM flags used

```
-XX:+UseG1GC
-XX:+AlwaysPreTouch
-Xms256m -Xmx256m
```

Fixed heap prevents GC mode switching between forks. Adjust size for modules
that require a larger working set.

## Important notes

- Always use **≥ 3 forks** for results stored in `baselines/`.
- Single-fork (`-f 1`) is fine for local development iteration only.
- For TLS benchmarks: keep handshake lifecycle deterministic and
   close all `AutoCloseable` SPI resources (`TlsEngine`, `LoanedBuffer`,
   allocator/provider handles) at trial teardown.
  (See `debugging.md` note in user memory.)
