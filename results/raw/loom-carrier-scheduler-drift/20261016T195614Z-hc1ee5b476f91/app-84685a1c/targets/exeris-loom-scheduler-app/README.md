# exeris-loom-scheduler-app

Benchmark target for the kernel research track `research/loom-carrier-scheduler`, which compares
the custom Loom `VirtualThreadScheduler`
`eu.exeris.kernel.core.transport.scheduler.locality.ExerisCarrierScheduler` against the stock
`ForkJoinPool` scheduler.

The workload follows the shape of the Netty virtual-thread scheduler benchmark
(<https://github.com/franz1981/Netty-VirtualThread-Scheduler>): a server handler running on a
virtual thread makes a blocking call to a mock backend that answers after a think time, then
responds. Two JVMs take part:

| Main class | Role |
|:-----------|:-----|
| `eu.exeris.benchmarks.targets.loomscheduler.LoomSchedulerServer` | The server under test. Its scheduler is whatever the JVM is started with. |
| `eu.exeris.benchmarks.targets.loomscheduler.MockBackend` | The backend. Runs on the stock scheduler, in its own JVM, so its latency does not depend on the arm being measured. |

Both boot the Exeris kernel HTTP/1.1 server with the subsystems `memory,transport,http` (the
kernel adds `crypto` as a dependency of `transport`). Every hop is plaintext: both processes set
`exeris.transport.tls=false`, because with a crypto provider bound the kernel's HTTP client would
otherwise dial TLS.

## Endpoints

### LoomSchedulerServer

| Endpoint | Behaviour |
|:---------|:----------|
| `GET /plaintext` | 200, body `Hello, World!`. Never leaves the handler; the no-backend baseline. |
| `GET /backend` | One blocking `GET /mock` to the backend from the handler's virtual thread, reading the full response; then 200 with the backend's body length in decimal (`104`). 502 when the backend call failed; the first failure's cause is printed to stderr. |
| anything else | 404 |

### MockBackend

| Endpoint | Behaviour |
|:---------|:----------|
| `GET /mock` | Sleeps `loom.bench.mock.thinkMs` on the request's virtual thread, then 200 with a fixed 104-byte JSON document (`content-type: application/json`). |
| anything else | 404 |

The think time is a virtual-thread sleep, which holds no carrier, so the backend's capacity is set
by its request rate, not by think time × carriers. Whether it stays off the critical path at a
given rate and CPU budget is for the harness to check (load `/mock` directly on the CPUs the
backend is given).

## Backends of `/backend`

`-Dloom.bench.backend` is required and is checked before the kernel boots: a missing or unknown
value fails startup without binding the port.

### `jdk` — blocking `java.net.Socket`

Blocking reads and writes on `java.net.Socket` from a virtual thread park that thread through the
JDK's `sun.nio.ch.Poller`, which is the path the custom scheduler has to service when a virtual
thread waits on I/O it does not own. `java.net.http.HttpClient` is not used on purpose: it runs its
own `SelectorManager` thread, so the virtual thread would wait on a future completed by that thread
and the poller would never be in the loop.

The client keeps `loom.bench.backend.pool` connection slots (default 128). A call borrows a slot
(most recently returned first; when all are in use the caller parks until one is returned, so the
pool size bounds backend concurrency), writes `GET /mock HTTP/1.1` with `Host` and
`Connection: keep-alive`, reads the status line and headers, then exactly `Content-Length` body
bytes, and returns the slot. Each slot opens its socket lazily on the first virtual thread that
borrows it, keeps one reusable read buffer, and closes its socket on any I/O error; a failure on a
reused keep-alive socket is retried once on a fresh one. A non-200 answer is a failure (502) and is
not retried.

### `kernel` — the kernel's own HTTP client

`eu.exeris.kernel.core.http.client.KernelWebClient` over the client engine the kernel binds when
`exeris.http.mode=DUAL` (`HttpKernelProviders.httpClientEngine()`), addressed with
`withAuthority(host:port)`. The outbound wait goes through the kernel transport instead of the JDK
poller. The response is read in full; the body is not decoded, only its size is returned. The
connection pool is the Community client engine's own: one keep-alive pool per peer, at most
`min(exeris.http.maxConnections, 64)` idle connections kept, and `exeris.http.maxConnections`
(default 4096) is shared with the server side's connection limit. `loom.bench.backend.pool` does not
apply to this backend.

## System properties

### LoomSchedulerServer

| Property | Default | Meaning |
|:---------|:--------|:--------|
| `exeris.http.port` | `8080` | Listen port |
| `exeris.http.bindHost` | `0.0.0.0` | Listen address (read by the kernel) |
| `loom.bench.backend` | — (required) | `jdk` or `kernel` |
| `loom.bench.backend.host` | `127.0.0.1` | Backend host |
| `loom.bench.backend.port` | `9090` | Backend port |
| `loom.bench.backend.pool` | `128` | Connection slots of the `jdk` backend |

The scheduler and the carrier set-up are JVM / kernel flags, passed through unchanged and echoed at
startup: `jdk.virtualThreadScheduler.implClass`, `jdk.virtualThreadScheduler.parallelism`,
`jdk.pollerMode`, `exeris.carrier.count`, `exeris.carrier.affinity`, `exeris.transport.locality`,
`exeris.locality.allVthreads`.

### MockBackend

| Property | Default | Meaning |
|:---------|:--------|:--------|
| `exeris.http.port` | `9090` | Listen port |
| `exeris.http.bindHost` | `0.0.0.0` | Listen address (read by the kernel) |
| `loom.bench.mock.thinkMs` | `1` | Think time in milliseconds; fractional values allowed, `0` answers at once |
| `jdk.virtualThreadScheduler.parallelism` | JDK default | Carrier count of the stock scheduler |

### JVM flags both processes need

```
--add-opens java.base/sun.nio.ch=ALL-UNNAMED
--add-opens java.base/java.io=ALL-UNNAMED
--enable-native-access=ALL-UNNAMED
```

Without the two `--add-opens`, the Community transport cannot reach socket file descriptors and
falls back to NIO. The kernel logs which socket backend is active at boot; a run is on the
FFM socket path only when that line reads `active=posix-hybrid, ffmArmed=true`:

```
INFO: [NativeTcpCarrier] Community socket backend mode=auto, active=posix-hybrid, ffmArmed=true - ...
```

## Startup output

LoomSchedulerServer prints, before the kernel boots:

```
LOOM-BENCH pid=<pid>
LOOM-BENCH jdk=<java.vm.version>
LOOM-BENCH scheduler.implClass=<class or <stock>> scheduler.parallelism=<n or <default>>
LOOM-BENCH jdk.pollerMode=<mode or <default>>
LOOM-BENCH exeris.carrier.count=... exeris.carrier.affinity=... exeris.transport.locality=... exeris.locality.allVthreads=...
```

then, once the kernel is up, the backend line and exactly one readiness line:

```
LOOM-BENCH backend=jdk(java.net.Socket) pool=128 target=127.0.0.1:9090
LOOM-BENCH READY port=<port>
```

and, on the first request it serves, the thread the handler ran on — the measurement assumes it is
virtual, and this line shows the scheduler's carrier name:

```
LOOM-BENCH handler thread virtual=true name=VirtualThread[#52,...]/runnable@exeris-carrier-0
```

MockBackend prints `LOOM-MOCK pid=<pid> thinkMs=... bodyBytes=104 scheduler.implClass=... scheduler.parallelism=...`
and then `LOOM-MOCK READY port=<port>`.

A ready line is printed after the kernel's boot has completed and the handler is installed;
requests that arrive before then are answered 503.

## Build

```
JAVA_HOME=<Loom EA JDK> KERNEL_CP=<classpath> [APP_TARGET_DIR=<dir>] ./build.sh
```

`KERNEL_CP` is required: the absolute paths of the `exeris-kernel-spi`, `exeris-kernel-core` and
`exeris-kernel-community` classes directories built from the kernel commit under test, plus their
third-party dependency jars. Every entry must exist. The script never searches a local Maven
repository, because a classpath assembled from whatever is installed there cannot be tied to the
commit a measurement claims to measure.

The sources compile with `--release 28` and without `--enable-preview`, matching the kernel on the
research branch. Output:

- `$APP_TARGET_DIR/classes` (default `target/classes`)
- `$APP_TARGET_DIR/app-classpath.txt` = `$APP_TARGET_DIR/classes:$KERNEL_CP`, absolute paths

## Run

```
CP=$(cat target/app-classpath.txt)
JF="--add-opens java.base/sun.nio.ch=ALL-UNNAMED --add-opens java.base/java.io=ALL-UNNAMED --enable-native-access=ALL-UNNAMED"

java $JF -Djdk.virtualThreadScheduler.parallelism=2 -Dexeris.http.port=9090 \
     -cp "$CP" eu.exeris.benchmarks.targets.loomscheduler.MockBackend

java $JF -Dexeris.http.port=8080 -Dloom.bench.backend=jdk -Dloom.bench.backend.port=9090 \
     -Djdk.virtualThreadScheduler.implClass=eu.exeris.kernel.core.transport.scheduler.locality.ExerisCarrierScheduler \
     -Dexeris.locality.allVthreads=true -Dexeris.carrier.count=2 -Dexeris.transport.locality=true \
     -cp "$CP" eu.exeris.benchmarks.targets.loomscheduler.LoomSchedulerServer
```

Omit the `implClass` line and the `exeris.*` carrier flags for the stock-scheduler arm.
