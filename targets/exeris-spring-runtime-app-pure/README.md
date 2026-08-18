# Spring Benchmark App — Spring-on-Exeris (Pure Mode)

Third arm of the Spring hosting comparison for the `entity-read-by-id` scenario. Same Spring
application (DI + Spring Data JPA + Hibernate + HikariCP + pgjdbc) as the other two arms; the
HTTP layer is written against the Exeris-native API instead of Spring MVC.

This README is the only documentation surface for the target.

## Track classification

- **Tier**: Community.
- **Pure-vs-Compat**: **Pure**. `exeris.runtime.web.mode` is deliberately *not* set, so
  `ExerisCompatAutoConfiguration` stays off and there is no `ExerisCompatDispatcher`,
  `ExerisSpringMvcBridge`, `ExerisHandlerMethodRegistry` or MVC argument resolver on the
  request path. `ExerisWebAutoConfiguration`'s native `ExerisHttpDispatcher` serves every
  request against `@ExerisRoute`-annotated `ExerisRequestHandler` beans.
- **Public docs path**: **included** — publishable, same as `exeris-spring-runtime-app-comp`.
  Measurements are Community + H1. The former internal-only stamp was withdrawn on
  2026-08-11: it derived from a CLAUDE.md line naming a path that never existed in this
  repo, and Exeris Spring Runtime has never been confidential.
- **Protocol**: H1 plaintext only.

## The three arms

| Arm | Target | Ingress | Web layer |
|---|---|---|---|
| 1 | `spring-hibernate` | Tomcat | Spring MVC `@RestController` |
| 2 | `spring-on-exeris` (compat) | Exeris | Spring MVC `@RestController` over the compat dispatcher |
| 3 | `spring-on-exeris-pure` (this) | Exeris | native `ExerisRequestHandler` |

Arm 1 → 2 is the total hosting swap. Arm 2 → 3 isolates the compat-dispatcher seam. Arm 1 → 3
is the best case for hosting this application on Exeris.

Everything below the web layer is held constant on purpose: the persistence and DTO classes
are copied verbatim from the compat target, `application.properties` repeats its datasource,
threading and JPA settings unchanged, and the pom pins the same Spring Boot, runtime and
Neo4j lines. **Change one arm, change the others** or the axis quietly gains a second
variable.

Serialisation is held constant the same way: pure mode has no MVC message converters, so
`JsonEncoder` encodes explicitly — but through the same autoconfigured Jackson `ObjectMapper`
the compat arm's converter uses.

## Verified behaviour (local smoke, 2026-08-02)

Against the scenario seed (1000 users) on `postgres:16.2`, built on
exeris-spring-runtime-web 0.5.0-SNAPSHOT with kernel 0.10.2:

| Endpoint | Result |
|---|---|
| `GET /api/v1/users` (heavy) | 200 — **byte-identical** to both other arms (`11744c70…`, 10205 B) |
| `GET /api/v1/user?id=1` (light) | 200 — **byte-identical** to both other arms (`4bee4801…`, 40 B) |
| `GET /api/v1/user` (no `id`) | 400 |
| `GET /api/v1/user?id=abc` | 400 |
| `GET /api/v1/user?id=999999` | 404 — no such row |
| `GET /db/ping` | 200 `{"status":"ok"}` |
| `GET /health` | 200 |

The two 404s are worth keeping distinct. `?id=999999` is a *semantic* 404 from the handler;
before runtime #50 the same status came from route resolution and the handler never ran. Both
read "404" in a driver log, so a light result from this target is only meaningful once the
runtime version is known — see the build requirement below.

Heavy issues the same 3-query aggregate as the other arms, and the process shows no Tomcat and
no compat-dispatcher class: ingress is `NativeTcpCarrier` (`mode=auto`, `active=posix-hybrid`).

## Resolved: pure mode could not route a request carrying a query string

**Fixed upstream by `exeris-spring-runtime` #50** ("strip query string before pure-mode route
lookup"), verified here on 2026-08-02. `ExerisRouteRegistry.resolve` now normalises the request
target before the map lookup, so the fix covers every caller of the registry rather than the
dispatcher alone. The section below is kept because it explains what to check if a light result
from this target ever looks wrong again.

### Build requirement (this is the part that can still bite)

Light eligibility is a property of the **runtime build**, not of this target's source. A jar
built against a pre-#50 runtime passes every heavy contract and fails only the light ones — and
it fails as a 404, which is also a legitimate response for a missing row. Nothing in this
repository can detect that from the outside. Before trusting a light result here, confirm the
bundled runtime has the fix:

```bash
unzip -p target/spring-benchmark-app-pure-1.0.0-SNAPSHOT.jar \
  'BOOT-INF/lib/exeris-spring-runtime-web-*.jar' > /tmp/w.jar && \
unzip -p /tmp/w.jar 'eu/exeris/spring/runtime/web/ExerisRouteRegistry.class' > /tmp/r.class && \
javap -p /tmp/r.class | grep stripQueryString    # present => fix included
```

`#50` also raised the kernel from 0.8.1 to 0.10.2 (this target's jars moved 0.9.0 → 0.10.2).
**Rebuild `exeris-spring-runtime-app-comp` together with this target**: the two are the arms of
the compat-seam pair, and rebuilding one alone puts a kernel-version difference inside a
measurement whose whole purpose is to isolate the compat dispatcher.

### What the defect was

Cause, from `exeris-spring-runtime-web` 0.5.0-SNAPSHOT before #50:

- `ExerisHttpDispatcher.dispatchWithScope` calls
  `routeRegistry.resolve(request.method(), request.path())` and responds `NOT_FOUND` on null.
  It never normalises the path.
- `ExerisRouteRegistry.resolve` is an exact two-level map lookup: `routes.get(method).get(path)`.
  No query stripping, no path variables.
- `HttpRequest` is a record whose single `path()` component carries the raw request target,
  query string included. (`exeris-community-app` relies on exactly this: it registers
  `/api/v1/user` on the *kernel* router — which does strip the query when matching — and then
  recovers `id` via `path.indexOf('?')`.)

So the kernel router and the Spring-side `ExerisRouteRegistry` disagree about what a path is.
Any query-bearing route is unreachable in pure mode.

### Independently confirmed: BudgetHQ DEC-046

This is not a benchmark-only artefact. BudgetHQ — a production application on the same
`exeris-spring-runtime` 0.5.0-SNAPSHOT in Pure Mode — hit it three times and codified it as
**DEC-046 "Pure Mode HTTP query-string routing"** (Accepted, 2026-05-21). It names the same
mechanism and, usefully, the fix site:

> Upstream `exeris-spring-runtime-web` Pure Mode HTTP dispatcher passes the FULL
> request-target (including query string) to `ExerisRouteRegistry.resolve`, which does
> exact-match `HashMap.get(path)`. […] **Compatibility-mode dispatcher already strips query at
> `ExerisHandlerMethodRegistry.java:149`; Pure-Mode dispatcher missed the same strip. This is a
> behaviour gap between Compat and Pure modes, NOT a documented intentional divergence.**

BudgetHQ's workaround was POST-with-body for anything that needed parameters. **That workaround
was never available to this target**: the light contract is `GET /api/v1/user?id=1`, served in
exactly that shape by every other arm, so switching one arm to POST-with-body would have changed
the method, the parsing path and the driver script — a different workload, not a comparable one.
Waiting for the upstream fix was therefore the only correct option, and it was the right call.

DEC-046 also flagged its own surviving GET-with-query handlers as "empirically-untested today".
The smoke on this target supplied that missing evidence in both directions: before #50,
`/api/v1/user` reached the handler (400) while `/api/v1/user?id=1` did not (404), isolating the
failure to route resolution with nothing else varying; after #50, the same two requests return
400 and 200. DEC-046 and its POST-with-body workaround can now be revisited upstream.

The fix landed where the boundary rule said it belonged — in `exeris-spring-runtime`, not here —
and this arm serves the light contract with **no change to the code committed in this repo**.

Regression check (pre-#50 behaviour on the left, current on the right):

```bash
curl -i 'http://localhost:9005/api/v1/user'        # 400 both before and after — handler reached
curl -i 'http://localhost:9005/api/v1/user?id=1'   # was 404 (route unresolved), now 200
```

**Consequence for the campaign**: both the heavy and the light contract families are runnable
on this arm.

## Not implemented

- `GET /graph/ping` — the entity-read-by-id harness never probes it (only `/health`,
  `/db/ping`, `/api/v1/users`). Required, along with a graph probe service, before this
  target is used for any graph-backed scenario.
- The shop-order saga endpoints. This target is scoped to `entity-read-by-id` and carries no
  `exeris-spring-runtime-flow` dependency.

### Footprint: RSS *is* comparable with the compat arm

An earlier version of this README said the opposite, reasoning that the missing flow
dependency left subsystems unstarted. That reasoning was wrong, and the boot log says so
directly — **both arms** run:

```
8 subsystem(s) in registry: [memory, crypto, persistence, events, graph, transport, http, flow]
Selector resolved 8 subsystem(s): memory, crypto, persistence, events, graph, transport, http, flow
```

`Selector=ALL`. The kernel's `flow` and `events` subsystems are not the Spring
`exeris-spring-runtime-flow` module; dropping the Maven dependency removes Spring beans, not
subsystems. This matches `exeris-community-app`, which starts the same eight while serving the
same read-only endpoints.

What actually differs is the Spring-side saga/graph surface — 45 source files against this
target's 24. Measured locally (n=1, identical flags `-Xms256m -Xmx1280m`, identical read-only
warmup of 3000 heavy + 3000 light, two forced full GCs before reading):

| | compat | pure | delta |
|---|---|---|---|
| RSS | 483 MB | 485 MB | +2 MB (pure higher) |
| Heap used | 28 MB | 27 MB | −1 MB |
| Metaspace | 77.34 MB | 74.75 MB | −2.59 MB |
| Loaded classes | 16 094 | 15 543 | −551 |

The whole structural difference is ~2.6 MB of metaspace, about 0.5 % of RSS — and the RSS
reading came out marginally *higher* on this arm, i.e. below run-to-run noise and opposite in
direction to what the retired caveat predicted. Publish per-arm campaign RSS as usual; what is
retired is the claim that the two arms' footprints cannot be compared.

## Harness wiring status

Wired for the **full contract family**, heavy and light.

- `runtime/drivers/target-asset-matrix.json` — registered as `spring-on-exeris-pure`,
  `asset_state: runnable`, `mode: pure`, health on :9005.
- `scenarios/entity-read-by-id/comparative-pair-manifest.json` — listed in
  `compatible_targets` and paired against both other arms
  (`spring-hibernate__spring-on-exeris-pure`, `spring-on-exeris__spring-on-exeris-pure`).
- `scripts/run-comparative.sh` — the `target_contract_scope` check remains available: a
  `compatible_targets` entry carrying `eligible_contracts` restricts that target to the listed
  contracts, rejected before launch with the reason recorded in the readiness artefact. No
  target currently declares it; this one did while the query-string blocker was open.

Note the two senses of `mode: pure` on this axis. `spring-hibernate` is pure because it never
touches Exeris at all (Tomcat + Spring MVC); this target is pure because it bypasses Exeris's
*compatibility layer* while still being hosted by Exeris. Both sit on the pure side of the
Pure-vs-Compat axis, and neither may be blended with the compat row without the caveat.

## Build and run

```bash
mvn -f targets/exeris-spring-runtime-app-pure/pom.xml clean package -DskipTests

EXERIS_PORT=9005 \
EXERIS_DB_JDBC_URL='jdbc:postgresql://localhost:5432/benchmark_db?prepareThreshold=1&defaultRowFetchSize=0&adaptiveFetch=false&preferQueryMode=extended' \
EXERIS_DB_USERNAME=benchmark EXERIS_DB_PASSWORD=benchmark \
java -Xms256m -Xmx1280m \
  --add-opens java.base/sun.nio.ch=ALL-UNNAMED --add-opens java.base/java.io=ALL-UNNAMED \
  --enable-native-access=ALL-UNNAMED --enable-preview -Dspring.classformat.ignore=true \
  -jar targets/exeris-spring-runtime-app-pure/target/spring-benchmark-app-pure-1.0.0-SNAPSHOT.jar
```

`--enable-preview` is mandatory: the kernel classes are compiled with preview features
(class file version 70.65535) and the runtime lifecycle fails to start without it.
