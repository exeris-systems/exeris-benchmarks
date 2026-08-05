# Spring Benchmark App — Spring-on-Exeris (Pure Mode, Native Persistence)

Fourth arm of the Spring hosting comparison for the `entity-read-by-id` scenario, and the only
one that is pure on **both** axes: the HTTP layer *and* the persistence layer are written
against the Exeris-native API.

This README is the only documentation surface for the target.

## Why this target exists

`spring-on-exeris-pure` is named "pure", but it is pure on the web axis only. It still runs
Spring Data JPA + Hibernate 6.6 on top of `exeris-spring-runtime-data`'s `ExerisDataSource` —
the **compatibility** DataSource — via `exeris.runtime.data.compat-datasource.enabled=true`.
Below the controller it is byte-identical to the compat arm.

That turned out to matter. The 2026-08-05 triad measured pure and compat as indistinguishable:

| pair (heavy, ab) | RPS delta vs Tomcat | CPU/req delta |
|---|---:|---:|
| `spring-hibernate` → `spring-on-exeris` (compat) | +10.9 % | −9.4 % |
| `spring-hibernate` → `spring-on-exeris-pure` | +10.94 % | −9.5 % |

The two Exeris arms differ *only* in HTTP dispatch, and `entity-read-by-id` is dominated by ORM
and JDBC — roughly 1 ms of CPU per request, of which the web layer is a small slice. There was
nothing for pure mode to win. This target moves the layer that actually dominates.

## Track classification

- **Tier**: Community.
- **Pure-vs-Compat**: **Pure on both axes.** `exeris.runtime.web.mode` is not set, so
  `ExerisCompatAutoConfiguration` stays off; and `exeris-spring-runtime-data` is not a
  dependency at all, so there is no `ExerisDataSource`, no JPA, no Hibernate, no Spring
  `DataSource` and no `JdbcTemplate`.
- **Public docs path**: **excluded**, same as the other `spring-on-exeris` arms. Community +
  H1, internal-only publication.
- **Protocol**: H1 plaintext only.

## The four arms

| Arm | Target | Web layer | Persistence layer |
|---|---|---|---|
| 1 | `spring-hibernate` | Tomcat + Spring MVC | Spring Data JPA + Hibernate 7.2 |
| 2 | `spring-on-exeris` | Spring MVC over compat dispatcher | Spring Data JPA + Hibernate 6.6 over `ExerisDataSource` |
| 3 | `spring-on-exeris-pure` | native `ExerisRequestHandler` | Spring Data JPA + Hibernate 6.6 over `ExerisDataSource` |
| 4 | `spring-on-exeris-pure-native` (this) | native `ExerisRequestHandler` | kernel-native `TransactionalExecutor` |

Which means the axes decompose cleanly:

- **2 → 3** isolates the compat-dispatcher seam (web axis).
- **3 → 4** isolates persistence (this target's reason to exist). Same app, same runtime, same
  kernel line, same pool, same SQL results — only the fetch mechanism changes.
- **1 → 4** is the full-stack swap and is **not** decomposable. Report it as a whole-stack
  figure or not at all.

## What "native" does and does not mean

**Does**: repositories call `eu.exeris.kernel.spi.persistence.TransactionalExecutor` directly,
preparing statements and reading typed columns off a `RowCursor`. No entity hydration, no
persistence context, no `EntityManager`.

**Does not**: this is not a native wire protocol. Community persistence is
`CommunityPersistenceProvider` = JDBC + HikariCP; the off-heap PgWire engine is Enterprise-only
(priority 100 > 0). pgjdbc and Hikari are still on the classpath and still in the measured path,
and the boot log still shows one `exeris-community-shared` Hikari pool. **Never label a run here
"Exeris native persistence" without that qualifier.**

## How the kernel engine reaches a Spring bean

`exeris-spring-runtime` exposes `PersistenceEngineProvider` but **no** `TransactionalExecutor`
bean, so `ExerisPersistenceConfiguration` supplies one. The subtlety is that
`PersistenceEngineProvider#get()` resolves `KernelProviders.PERSISTENCE_ENGINE`, a `ScopedValue`
bound per request — calling it at bean-creation time throws "ScopedValue not bound", and caching
its result would pin one request's engine forever.

So the singleton is a `PersistenceEngine` **adapter** that re-resolves the provider on every
call, with a `TransactionOrchestrator` (kernel-core) built over it. This is an app-side
workaround for a runtime-side gap: if the runtime ever contributes a `TransactionalExecutor`
bean, delete the class and inject it — then re-verify that the measured path did not change.

Consequence, inherited from the same ScopedValue rule that bit the compat security filter and
the Flow worker: **any DB access must run inside the kernel provider scope.** Request handlers
are fine. A bare `Thread.ofVirtual().start()` is not.

## Transaction demarcation differs from the ORM arm, deliberately

`UserService` carries no `@Transactional`. The read boundary lives inside the repository —
`inReadSession` for the heavy contract (one connection, all three queries), `query` for the
light one. Layering Spring's `ExerisPlatformTransactionManager` on top would demarcate a second,
outer transaction and acquire a second connection per request.

This is a real difference from arm 3, not a free variable: demarcation *is* part of what the
persistence layer is on each side. But it means the 3 → 4 delta covers demarcation + mapping +
statement handling, not entity hydration alone. State that with any number.

## SQL provenance

Every statement in `UserRepository` is copied **verbatim** from
`targets/exeris-community-app`'s `UserRepository`, so this arm and `exeris-community` issue
byte-identical SQL to Postgres. That is what makes the
`exeris-community__spring-on-exeris-pure-native` pair meaningful.

**If a query changes in either file it must change in both, in the same commit**, or a runtime
comparison silently becomes a query-plan comparison.

One inherited quirk is preserved rather than fixed: the single-user friends/interests reads bind
strings against `CAST(? AS BIGINT)`, while the batch reads bind typed int8 against plain
placeholders. The community arm's 2026-07-20 bind-equalisation pass covered the batch paths and
the by-id path but not those two. Fix both targets together or neither.

## Build

```bash
cd targets/exeris-spring-runtime-app-pure-native
mvn -q -B clean package -DskipTests
```

Kernel versions are pinned **inline on the dependencies**, not via the kernel BOM:
`exeris-spring-runtime-bom` inherits a `dependencyManagement` section from its own parent that
pins `eu.exeris:exeris-kernel-*` to a newer line, and because it is imported first it beats a
later kernel-BOM import. A version on the dependency itself outranks any `dependencyManagement`
entry, so that is the only placement that holds.

Always verify parity against the sibling arms after a build:

```bash
unzip -l target/spring-benchmark-app-pure-native-1.0.0-SNAPSHOT.jar | grep exeris-kernel
```

Expected (matched to the arms measured on 2026-08-05): `exeris-kernel-community`,
`exeris-kernel-core`, `exeris-kernel-spi`, all at **0.10.2**.

`exeris-kernel-community` is declared at **runtime scope**. The other arms get it transitively
through `exeris-spring-runtime-data`; dropping that module dropped the edition driver with it,
and without a `SubsystemProvider` on the classpath the kernel starts with no persistence
subsystem. Runtime scope keeps the target edition-swappable — application code must never
import `community.*` or `enterprise.*`, the edition is resolved by `ServiceLoader`.

> **Drift warning.** The other three arms carry *no* kernel pin and will follow whatever the
> runtime BOM's parent resolves on their next rebuild. Pin them, or rebuild all four together
> and re-verify, before comparing any freshly built arm against an older one.

## Status

Built and jar-verified 2026-08-05. **Not yet boot-verified against a database** — no benchmark
Postgres was available on the authoring host. Before using any leaf from this target, run the
Stage-4 preflight and confirm all endpoints answer: `/health`, `/db/ping`, `/api/v1/users`
(heavy) and `/api/v1/user?id=N` (light).

Also confirm the boot log shows the eight kernel subsystems initialising and a single
`exeris-community-shared` Hikari pool, and that **no** `HikariPool-1`, `EntityManagerFactory` or
`Hibernate ORM core version` line appears — any of those would mean a JPA path crept back onto
the classpath and the axis is broken.
