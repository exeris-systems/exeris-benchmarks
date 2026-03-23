# targets/exeris-spring-runtime

This module is now a runnable Spring Boot adapter for `exeris-benchmark-app`.
It starts a Spring context in non-web mode and delegates process lifecycle to
`eu.exeris.kernel.benchmark.target.app.BenchmarkTargetMain`.

## What it does

- Uses `spring-boot-starter` for a real Spring runtime process.
- Disables web server startup (`WebApplicationType.NONE`) to avoid changing
  target HTTP handling semantics owned by `exeris-benchmark-app`.
- Keeps startup lightweight with banner off and lazy initialization enabled.

## Build

```bash
mvn -f targets/exeris-benchmark-app/pom.xml -DskipTests install
mvn -f targets/exeris-spring-runtime/pom.xml -DskipTests package
```

## Docker image

```bash
docker build \
  -f targets/exeris-spring-runtime/Dockerfile \
  -t exeris-spring-runtime:latest \
  .
```

The Dockerfile performs a two-step Maven build:
1. Installs `targets/exeris-benchmark-app` into local Maven repository.
2. Packages `targets/exeris-spring-runtime` and runs the produced jar.

## Runtime use in compose

`runtime/drivers/docker-compose/spring-runtime.yml` now includes a `build`
section with repository-root context and this module Dockerfile, while keeping
the image tag configurable via `EXERIS_SPRING_RUNTIME_IMAGE`.
