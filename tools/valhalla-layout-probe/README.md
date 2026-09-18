# Valhalla layout probes (JDK 28 EA, JEP 401 preview)

Four self-contained probes that produced §5.3 and §5.4 of
`results/reports/2026-08-26-valhalla-carrier-sweep-on-an-off-heap-runtime.md`. They take no
arguments and touch nothing outside the JVM they run in — the point is that a reader can re-run
them on their own JDK and get the same table rather than trust the report's transcription.

Run every one with `--enable-preview`. `--source 28` is needed only in source-file mode.

| probe | question it answers |
|---|---|
| `ValueCheck.java` | is `MemorySegment` sealed, what does it permit, and is any `java.lang.foreign` type a value class? |
| `ValueClassCensus.java` | how many value classes does `java.base` actually contain, and how many of them are in the `foreign` packages? |
| `LayoutProbe.java` | which of the four `LayoutKind`s does HotSpot generate per carrier shape, and what flattens in a **field** vs an **array**? |
| `NRProbe.java` | does a **null-restricted** array flatten a carrier that a plain array will not? |

```bash
JDK=/opt/jdk28

# 1-2: value-ness of java.lang.foreign, and the java.base census
$JDK/bin/java --enable-preview --source 28 ValueCheck.java
$JDK/bin/java --enable-preview --source 28 ValueClassCensus.java

# 3: field and array layouts. The flags are diagnostic, hence the unlock.
$JDK/bin/javac --enable-preview --release 28 -d /tmp/lp LayoutProbe.java
$JDK/bin/java  --enable-preview -XX:+UnlockDiagnosticVMOptions \
               -XX:+PrintFieldLayout -XX:+PrintFlatArrayLayout \
               -cp /tmp/lp LayoutProbe

# 4: null-restricted arrays, via the internal API (no language syntax yet — JEP draft 8316779)
$JDK/bin/javac --enable-preview --release 28 -d /tmp/nr NRProbe.java
$JDK/bin/java  --enable-preview -XX:+UnlockDiagnosticVMOptions -XX:+PrintFlatArrayLayout \
               -cp /tmp/nr NRProbe
```

## Reading `LayoutProbe` output

HotSpot prints all four candidate layouts per value class. A `-/-` means **HotSpot did not
generate that kind for this class**, not that the layout is impossible — `NRProbe` demonstrates
the difference: asking for a *non-atomic* null-restricted array of an 8-byte carrier yields
`NULL_FREE_ATOMIC_FLAT`, because at that size the atomic layout is achievable in one word and the
non-atomic variant is never needed.

What the probes established on `28-ea+10-569`:

- a field flattens **only when the enclosing class is itself a value class** — an identity-class
  holder lays out value-typed fields as plain references, whatever their size;
- `NULLABLE_NON_ATOMIC_FLAT` (the kind used for fields inside value classes) has **no size limit**;
- arrays are bound by the atomic rule instead: **≤ 8 bytes per element**, so a plain
  `HttpHeader[]` does not flatten, and `FlatArrayElementMaxOops = 4` is necessary but not
  sufficient;
- null restriction lifts arrays to the 8-byte payload limit and no further.

Results are JDK-build-specific. Re-run rather than quote if you are on a different build.
