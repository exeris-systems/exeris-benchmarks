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
that require a larger working set (e.g., enterprise TLS benchmarks).

## Important notes

- Always use **≥ 3 forks** for results stored in `baselines/`.
- Single-fork (`-f 1`) is fine for local development iteration only.
- For Enterprise TLS benchmarks: **do not reuse `SSLEngine` across `@Benchmark`
  invocations within the same trial** — use `@Setup(Level.Invocation)` or a
  fresh harness per call to avoid native-state instability corrupting results.
  (See `debugging.md` note in user memory.)
