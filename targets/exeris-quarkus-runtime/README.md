# targets/exeris-quarkus-runtime

This module is a runnable Quarkus JVM adapter for `exeris-benchmark-app`.
The adapter uses `@QuarkusMain` + `QuarkusApplication` and delegates process
execution to `eu.exeris.kernel.benchmark.target.app.BenchmarkTargetMain`.

## Build

```bash
mvn -f targets/exeris-benchmark-app/pom.xml -DskipTests install
mvn -f targets/exeris-quarkus-runtime/pom.xml -DskipTests package
```

By default the module packages in JVM mode with uber-jar output.

## Docker image

```bash
docker build \
  -f targets/exeris-quarkus-runtime/Dockerfile \
  -t exeris-quarkus-runtime:latest \
  .
```

The Dockerfile performs a two-step Maven build:
1. Installs `targets/exeris-benchmark-app` into local Maven repository.
2. Packages `targets/exeris-quarkus-runtime` (uber-jar JVM mode).

## Runtime use in compose

`runtime/drivers/docker-compose/quarkus-runtime.yml` now includes a `build`
section with repository-root context and this module Dockerfile, while keeping
`EXERIS_QUARKUS_RUNTIME_IMAGE` for configurable image tags.
