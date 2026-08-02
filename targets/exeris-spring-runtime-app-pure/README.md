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
- **Public docs path**: **excluded**, same as `exeris-spring-runtime-app-comp`. Measurements
  are Community + H1, internal-only publication.
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

## Verified behaviour (local smoke, 2026-08-01)

Against the scenario seed (1000 users) on `postgres:16.2`:

| Endpoint | Result |
|---|---|
| `GET /api/v1/users` (heavy) | 200 — **byte-identical** to both other arms (sha256 match, 10205 B) |
| `GET /db/ping` | 200 `{"status":"ok"}` |
| `GET /health` | 200 |
| `GET /api/v1/user?id=1` (light) | **404 — blocked, see below** |

Heavy issues the same 3-query aggregate as the other arms, and the process shows no Tomcat and
no compat-dispatcher class: ingress is `NativeTcpCarrier` (`mode=auto`, `active=posix-hybrid`).

## Blocker: pure mode cannot route a request that carries a query string

`GET /api/v1/user?id=1` returns 404 with an empty body. The route is registered and the handler
is reachable — `GET /api/v1/user` with no query string reaches it and returns this target's own
400 for the missing `id`. Only the query-bearing form fails, and it fails before the handler.

Cause, from `exeris-spring-runtime-web` 0.5.0-SNAPSHOT:

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

BudgetHQ's workaround is POST-with-body for anything that needs parameters. **That workaround is
not available to this target**: the light contract is `GET /api/v1/user?id=1`, served in exactly
that shape by every other arm. Changing this one arm to POST-with-body would change the method,
the parsing path and the driver script — a different workload, not a comparable one.

Worth noting for the upstream fix: DEC-046 flags its own surviving GET-with-query handlers as
"empirically-untested today" and has a probe sprint queued. The smoke result above is that
missing evidence — `/api/v1/user` reaches the handler (400) while `/api/v1/user?id=1` does not
(404) isolates the failure to route resolution, with nothing else varying.

This is a host-runtime gap, not a benchmark-harness one: per the repository boundary rule the
fix belongs in `exeris-spring-runtime`, not here. Nothing in this repo can work around it — route
resolution happens before application code runs. Once the query-strip patch lands, this arm
serves the light contract with no change to the code committed here.

Minimal reproduction: build this target, launch it, then

```bash
curl -i 'http://localhost:9005/api/v1/user'        # 400 — handler reached
curl -i 'http://localhost:9005/api/v1/user?id=1'   # 404 — route not resolved
```

**Consequence for the campaign**: the heavy contract
(`fixed_contract_cross_runtime_h1_v2`) is runnable on this arm today. The light contract
(`fixed_contract_cross_runtime_h1_single_read_v1`) is not, until the runtime resolves paths
without the query string.

## Not implemented

- `GET /graph/ping` — the entity-read-by-id harness never probes it (only `/health`,
  `/db/ping`, `/api/v1/users`). Required, along with a graph probe service, before this
  target is used for any graph-backed scenario.
- The shop-order saga endpoints. This target is scoped to `entity-read-by-id`; it carries no
  `exeris-spring-runtime-flow` dependency, so its footprint is **not** comparable to the
  compat arm's for RSS purposes. Do not publish an RSS delta between arms 2 and 3 without
  either adding the flow/saga beans here or stating this difference.

## Harness wiring status

Wired **heavy-only**, and that restriction is enforced by the harness rather than left to
convention.

- `runtime/drivers/target-asset-matrix.json` — registered as `spring-on-exeris-pure`,
  `asset_state: runnable`, `mode: pure`, health on :9005.
- `scenarios/entity-read-by-id/comparative-pair-manifest.json` — listed in
  `compatible_targets` with an `eligible_contracts` array, and paired against both other arms
  (`spring-hibernate__spring-on-exeris-pure`, `spring-on-exeris__spring-on-exeris-pure`).
- `scripts/run-comparative.sh` — the `target_contract_scope` check rejects any run whose
  `--contract-id` is outside a target's `eligible_contracts`, before the targets are launched.
  The pair is marked non-eligible with the reason recorded in the readiness artefact.

`eligible_contracts` lists the nine heavy contracts and omits the three single-read ones. The
split is derived from the contract endpoints, not chosen by hand: every heavy contract targets
`GET /api/v1/users`, every omitted one targets `GET /api/v1/user?id=1`. When the upstream
query-strip patch lands, the three move up into the list and nothing in this target changes.

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
