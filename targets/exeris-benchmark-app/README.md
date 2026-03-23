# targets/exeris-benchmark-app

This module is a scaffold for a future extraction-ready benchmark target application.
It defines a minimal, edition-blind contract boundary for benchmark bootstrap, metadata
labeling, routing, seeding, telemetry, and readiness surfaces, and now includes a first
SPI+CORE launch path for a jar-based benchmark target process.

## Purpose

- Provide a public-safe contract boundary for a benchmark target application that can be
  extracted later as a standalone deliverable.
- Keep benchmark labeling requirements explicit so fairness and reproducibility metadata
  remain stable across Community, Enterprise, and future runtime adapters.
- Isolate benchmark target concepts from provider-specific implementation details.

This remains a transitional Option A scaffold. The phase 2 implementation is intentionally
limited to a public-safe SPI+CORE bootstrap path and should not be treated as evidence of
full provider resolution, multi-tier runtime coverage, or complete benchmark behavior.

## Package Layout

| Package | Role |
| --- | --- |
| `api` | Edition-blind runtime, capability, lifecycle, metadata, and provisioning contracts |
| `bootstrap` | Bootstrap request, resolution, selection, configuration, and report types |
| `http` | Small HTTP routing and request/response abstractions |
| `app` | Application assembly, startup manifest, readiness, and placeholder entry point |
| `seed` | Seed planning, execution, fingerprint, and reset policy contracts |
| `telemetry` | Diagnostic sink, snapshots, telemetry profile, and metrics endpoint policy |
| `bootstrap.spi` | SPI+CORE config loading, capability selection, runtime resolution, and logical seed planning |
| `runtime.spi` | SPI+CORE lifecycle, target-level route binding/dispatch, scenario catalog, and logical seed wiring |

## Phase 3 to 6 Status

The current implementation includes phase 3 through phase 6 scaffolding on top of the original phase 2 bootstrap path:

- Configuration loading from system properties and selected environment variables
- SPI+CORE runtime resolution using `KernelBootstrap`, `BootstrapSelector`,
  `KernelProviders`, and `HttpKernelProviders`
- A jar-based lifecycle that stays edition-blind and uses the same subsystem-selection
  rules as `runtime/launchers/CommunityStackLauncher.java`
- Target-level handler binding for `/health`, `/health/live`, `/health/ready`, and `/db/ping`
- In-process dispatch through the target HTTP abstractions using bound `BenchmarkHttpHandler`
  implementations and phase 6 export into a real SPI `HttpServerEngine` via
  `HttpServerEngine.setHandler(...)` before engine start when the selected runtime path binds HTTP
- Logical seed planning and deterministic seed fingerprinting derived from runtime and scenario
  metadata, plus phase 5 physical persistence manifest materialization only when persistence is selected
  and bound
- Concrete SPI+CORE scenario catalog and non-empty seed dataset surfaces in the runtime contract

This should not be interpreted as complete provider-resolved benchmark target behavior.
The current implementation provides a first SPI+CORE launch path only.

Handler binding is implemented at the benchmark abstraction layer and bridged into SPI `HttpHandler`
for the SPI+CORE path. Effective runtime export still depends on selected subsystem activation and
successful engine startup.

Seed reporting remains evidence-bounded. The runtime computes a deterministic logical seed
fingerprint for each run. If persistence is selected and bound, phase 5 persists the seed manifest
row transactionally and marks physical application as true. If persistence is not selected/bound,
the seed remains logical-only with physical application false and explicit notes.

## Still Deferred

- Full provider resolution across Community, Enterprise, Spring Runtime, and future stacks
- Telemetry adapter binding and exporter wiring
- Schema creation, graph wiring, and broader persistence orchestration
- Spring runtime adapter support and other non-SPI provider integrations
- Scenario execution semantics beyond the currently bound health and db-ping target surfaces

`BenchmarkTargetMain` performs a SPI+CORE bootstrap, prints route and seed dataset summary
information, and keeps statements proportional to observable startup state.

## Metadata Expectations

The current SPI+CORE path emits a runtime descriptor whose labels remain explicit in startup metadata. Future
runtime adapters should preserve the same explicit labels in benchmark artifacts.
At minimum, the descriptor carries:

- `tier`
- `runtimeFamily`
- `protocolModeSelected`
- `implementationVariant`
- `providerId`
- `bootstrapContractVersion`
- `scenarioCatalogVersion`
- `telemetryProfile`
- `publicationPolicy`

Benchmark bootstrap requests should also make the requested mode and execution context
explicit, including benchmark mode, runtime family, protocol mode, implementation variant,
execution class, seed dataset id, and configuration overrides.

As later phases add provider resolution and richer adapters, emitted result and environment
artifacts should continue to align with repository schemas and reproducibility expectations,
including stable labeling of tier, runtime family, protocol mode selection, and seed
fingerprinting.

## Transitional Status

This directory remains intended as a transitional Option A scaffold that can be extracted
later with minimal contract churn. The current implementation establishes a jar-based SPI+CORE
bootstrap path with runtime SPI HTTP export and physical persistence seed manifest support, while
provider resolution breadth and fuller runtime adapters remain follow-up work.
