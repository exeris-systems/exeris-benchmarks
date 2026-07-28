# Reverse normalization — does the §8 conclusion depend on which fetch mode you equalize to?

**Scope:** `exploratory` (robustness test) · **Date:** 2026-07-28 · HEAVY aggregate `GET /api/v1/users`,
1024 MB budget / 256 m heap / pool 32 / cpuset 0-1,8-9 / 120 s warmup + 300 s measure, both arms.

**This is a robustness test, not an alternative primary normalization.** Fetch-all remains the setting
appropriate to the workload: the 10×10×10 aggregate is serialized whole, so every row is wanted; adaptive
fetch exists for streaming large sets consumed incrementally. The question is therefore **not** "which
normalization is correct" but **"does the conclusion depend on the choice"** — because the natural reader
objection to §8 is *"you normalized to the setting that favours exeris."*

## Result — the ranking is independent of normalization direction

| fetch mode (identical on both arms) | exeris | quarkus-tuned | rps gap | CPU/req |
|---|---:|---:|---:|---|
| **fetch-all** `defaultRowFetchSize=0, adaptiveFetch=false` | 14308 rps / 206.0 µs | 13872 / 231.6 µs | **+3.1 %** | qtuned +12.4 % heavier |
| **adaptive** `defaultRowFetchSize=100, adaptiveFetch=true` | 12427 rps / 240.9 µs | 11869 / 274.2 µs | **+4.7 %** | qtuned +13.8 % heavier |

**exeris leads in both fetch modes, on both throughput and CPU/req — and the margin is slightly *wider*
under the reverse setting.** The §8 conclusion does not depend on the direction of normalization; the
"you picked the setting that favours exeris" objection is answered directly, with data.

Secondary, and it corroborates the framing rather than the ranking: **cursor mode costs both arms**
(exeris −13.1 % rps, quarkus-tuned −14.4 %). Fetch-all is the better setting *for this workload for both
runtimes*, which is why it is the primary normalization — not because it favours one arm.

## Scope limit on the magnitude (important)

§8's "+5–7 %" comes from the **comparative-gate harness** (promotion campaign, its own windows and gating).
This test runs the **constrained runner**, where the heavy fetch-all gap is consistently ~+3.1–3.5 %
(cf. the pool-32 legs of `../20260724-entity-read-by-id-pool-downslope-waits/`: 14358 vs 13877 = +3.5 %).
So **what transfers from this run is the sign and the robustness of the conclusion, not §8's magnitude.**
Do not quote +3.1 %/+4.7 % as a restatement of §8's number; the two harnesses are not directly comparable.

## Design notes (two traps that would have invalidated this)

1. **Flipping only the boolean would have been vacuous.** `run-entity-read-by-id.sh` documents fetch-all as
   `defaultRowFetchSize=0 → unnamed portal, no cursor`, and pgjdbc's `adaptiveFetch` tunes a *cursor's*
   fetch size. With no cursor there is nothing to tune, so `adaptiveFetch=true` alone is a **no-op** — it
   would have produced a byte-identical query wire and a confident "no difference" that looks exactly like
   a passing robustness test while testing nothing. The reverse arm therefore uses
   `defaultRowFetchSize=100 & adaptiveFetch=true`, i.e. genuine cursor mode. That both arms lose 13–14 %
   under it is independent confirmation the setting actually changed the query wire.
   The value 100 is a free parameter but is **identical on both arms**, so the ranking comparison holds
   whatever it is.
2. **The fetch-all control was re-measured in this same session**, not reused from an earlier campaign: the
   counterbalanced cell showed ~1–2 % session-to-session offsets, the same order as the effect under test.
   Arm order was reversed between configs (exeris→qtuned, then qtuned→exeris) so within-pair order effects
   partly cancel when the two *gaps* are compared.
3. The runner echoes the applied parameter string and the script **fail-closes on a mismatch**; all four
   legs verified the requested params reached the target (see `reverse-normalization.txt`).

## Caveats
- n=1 per cell. Harness run-to-run noise is ~0.2 % (counterbalance internal control), so the +3.1 % and
  +4.7 % gaps and the 13–14 % cursor cost are all well outside noise, but the 1.6 pp *widening* of the gap
  is a single observation and should not be over-read.
- Loopback; exploratory scope, not gated. Heavy only — light is fetch-insensitive (single row).

## Files
`reverse-normalization.txt` (raw, incl. per-leg param verification), per-leg `result.json` +
`resource-metrics.json`, `reverse-normalization.sh`.
