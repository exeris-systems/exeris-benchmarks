import http from 'k6/http';
import { check } from 'k6';
import exec from 'k6/execution';
import { Rate, Trend, Counter } from 'k6/metrics';

// =============================================================================
// entity-read-by-id — k6 mixed-traffic SOAK config (EXPLORATORY-ONLY)
// =============================================================================
//
// CLAIM SCOPE — read before running or citing results:
//
//   * EXPLORATORY-ONLY. The k6 driver is NOT the wrk-defined comparison
//     contract for this scenario. The frozen cross-runtime contract
//     (fixed_contract_cross_runtime_h1_v1: wrk/wrk2/h2load, threads=4,
//     connections=128, warmup 60s, measure 120s) lives in wrk.env / wrk2.env /
//     h2load.flags and scenario.json. Output from this script is NEVER
//     comparison-eligible: no cross-target comparative claims, no baseline
//     updates, no p99-stable claims (p99-stable is wrk2-only per
//     scenarios/entity-read-by-id/README.md). Use this script for hours-scale
//     soak / survivability observation only: throughput stability, error
//     trends, latency drift, leak signals.
//
//   * All executors below are 'constant-arrival-rate' (open-loop), so the
//     script passes bench_k6_assert_arrival_rate_executor
//     (tools/bench/lib/k6.sh) and avoids closed-loop coordinated-omission
//     contamination. Latency trends recorded here are still descriptive
//     observations, not publishable percentile claims.
//
//   * Transport label: results must carry the transport mode actually used.
//     Default label is loopback-h1; override K6_TRANSPORT_MODE (e.g.
//     'private-net-h1' for the DO droplet pair) when the client is not
//     co-located with the target.
//
// TRAFFIC MIX (every endpoint exists on all cross-runtime targets):
//   * GET /api/v1/users?id=<n>  — the frozen scenario endpoint. Response is the
//     fixed aggregate profile users-aggregate-10x10x10-v1 (10 users, each with
//     10 friends and 10 interests). Weight: K6_USERS_WEIGHT (default 0.90).
//   * GET /db/ping              — DB liveness read. K6_DB_PING_WEIGHT (0.05).
//   * GET /health               — process liveness.  K6_HEALTH_WEIGHT  (0.05).
//
// HOT/COLD ID MIX — HONESTY CAVEAT (do not skip):
//   The seeded id space is users 1..1000 (seed/entities.sql; seed-manifest.json
//   id_range {min:1, max:1000}). There is NO per-id route on the targets: the
//   handlers serve the fixed users aggregate and IGNORE the `id` query
//   parameter (the same query-string form the cold-start-ttfr first-request
//   probe uses). The hot/cold selector below therefore shapes the URL/request
//   stream over the seeded id range — it does NOT vary DB row selection today.
//   Never describe results from this script as "per-id read distribution"
//   behavior; label them as fixed-aggregate reads under an id-shaped URL
//   stream. K6_HOT_RATIO (default 0.8) of users requests draw an id from the
//   hot set [K6_ID_MIN .. K6_ID_MIN+K6_HOT_SET_SIZE-1]; the remainder draw
//   uniformly over the full seeded range [K6_ID_MIN .. K6_ID_MAX].
//
// PHASES: three k6 scenarios named exactly warmup / measurement / cooldown
//   (tagged phase=...), so BENCH_K6_TIMESERIES=1 plus
//   tools/aggregate-k6-throughput.sh can reconstruct the per-second throughput
//   series bucketed by the k6 `scenario` CSV column. The soak window is the
//   `measurement` phase (K6_RATE / K6_SOAK_DURATION / K6_PREALLOC_VUS /
//   K6_MAX_VUS).
//
// RUNNING (driver: scripts/run-k6.sh — it does NOT source k6.env; every knob
// must reach the script as a `--env KEY=value` arg, which run-k6.sh splices
// into `k6 run`):
//
//   # Seed + verify first (mandatory — results are invalid otherwise):
//   PGPASSWORD=benchmark bash scenarios/entity-read-by-id/seed/verify-seed.sh
//
//   # Default soak (1h measurement window) against loopback:
//   ./scripts/run-k6.sh scenarios/entity-read-by-id --env BASE_URL=http://localhost:8080
//
//   # 24h soak at 100 req/s with the per-second series enabled:
//   BENCH_K6_TIMESERIES=1 ./scripts/run-k6.sh scenarios/entity-read-by-id \
//     --env BASE_URL=http://<target>:8080 --env K6_RATE=100 --env K6_SOAK_DURATION=24h \
//     --env K6_TRANSPORT_MODE=private-net-h1
//
// WARNING — duration knob naming (empirically verified on k6 v1.4.2):
//   K6_DURATION / K6_VUS / K6_ITERATIONS / K6_STAGES are k6 SYSTEM options.
//   k6 merges them into its config layer even when passed via `--env` (not
//   just OS env), which REPLACES the arrival-rate scenarios below with a
//   plain closed-loop default run — silently reintroducing the coordinated-
//   omission contamination this script exists to avoid (same hazard class
//   bench_read_k6_defaults blocklists). Therefore:
//     * the soak duration knob is K6_SOAK_DURATION (collision-free);
//     * __ENV.K6_DURATION is still read as a fallback alias, but any run in
//       which those system keys reached k6's config layer FAILS CLOSED: the
//       setup() guard below aborts the test the moment the consolidated
//       options no longer contain the three constant-arrival-rate scenarios.
//   Never export any K6_* system key into the OS environment either.
// =============================================================================

// Override BASE_URL via --env BASE_URL=...; K6_BASE_URL is kept as secondary
// compatibility input (repo convention).
const BASE_URL = __ENV.BASE_URL || __ENV.K6_BASE_URL || 'http://localhost:8080';

// --- Soak-window knobs (measurement phase) ----------------------------------
// Sizing note: with an open-loop arrival rate R and mean latency L seconds, the
// executor needs ~R*L in-flight VUs; K6_MAX_VUS is the hard cap. If VUs run
// out, k6 reports `dropped_iterations` — a non-zero dropped_iterations count
// means the offered rate was NOT sustained; say so in any write-up.
const RATE = Number.parseInt(__ENV.K6_RATE || '50', 10);
// K6_SOAK_DURATION is primary (e.g. '24h'); K6_DURATION is a fallback alias
// only — see the duration-knob WARNING in the header before using it.
const DURATION = __ENV.K6_SOAK_DURATION || __ENV.K6_DURATION || '1h';
const PREALLOC_VUS = Number.parseInt(__ENV.K6_PREALLOC_VUS || '20', 10);
const MAX_VUS = Number.parseInt(__ENV.K6_MAX_VUS || '100', 10);

// --- Warmup / cooldown knobs -------------------------------------------------
const WARMUP_RATE = Number.parseInt(__ENV.K6_WARMUP_RATE || String(RATE), 10);
const WARMUP_DURATION = __ENV.K6_WARMUP_DURATION || '120s';
const COOLDOWN_RATE = Number.parseInt(__ENV.K6_COOLDOWN_RATE || String(RATE), 10);
const COOLDOWN_DURATION = __ENV.K6_COOLDOWN_DURATION || '60s';

// --- Traffic-mix knobs -------------------------------------------------------
const HOT_RATIO = Number.parseFloat(__ENV.K6_HOT_RATIO || '0.8');
const HOT_SET_SIZE = Number.parseInt(__ENV.K6_HOT_SET_SIZE || '50', 10);
const ID_MIN = Number.parseInt(__ENV.K6_ID_MIN || '1', 10); // seed-manifest id_range.min
const ID_MAX = Number.parseInt(__ENV.K6_ID_MAX || '1000', 10); // seed-manifest id_range.max
const USERS_WEIGHT = Number.parseFloat(__ENV.K6_USERS_WEIGHT || '0.90');
const DB_PING_WEIGHT = Number.parseFloat(__ENV.K6_DB_PING_WEIGHT || '0.05');
const HEALTH_WEIGHT = Number.parseFloat(__ENV.K6_HEALTH_WEIGHT || '0.05');

const REQUEST_TIMEOUT = __ENV.K6_TIMEOUT || '10s';
const TRANSPORT_MODE = __ENV.K6_TRANSPORT_MODE || 'loopback-h1';

// Normalized cumulative cutoffs for the endpoint draw.
const _weightTotal = USERS_WEIGHT + DB_PING_WEIGHT + HEALTH_WEIGHT;
const USERS_CUT = USERS_WEIGHT / _weightTotal;
const DB_PING_CUT = USERS_CUT + DB_PING_WEIGHT / _weightTotal;

// Hot set clamped to the seeded range so K6_HOT_SET_SIZE can never draw
// un-seeded ids.
const ID_SPAN = ID_MAX - ID_MIN + 1;
const HOT_SPAN = Math.max(1, Math.min(HOT_SET_SIZE, ID_SPAN));

// --- Custom metrics ----------------------------------------------------------
const errorRate = new Rate('errors'); // threshold signal
const errorCounter = new Counter('soak_errors'); // absolute error count over the soak
const timedOutCounter = new Counter('soak_req_timed_out'); // status 0 (timeout / conn refused)
const failedOtherCounter = new Counter('soak_req_failed_other'); // any other non-200
const usersLatency = new Trend('users_read_latency_ms', true);
const usersHotLatency = new Trend('users_read_hot_latency_ms', true);
const usersColdLatency = new Trend('users_read_cold_latency_ms', true);
const dbPingLatency = new Trend('db_ping_latency_ms', true);
const healthLatency = new Trend('health_latency_ms', true);
const hotRequests = new Counter('users_hot_requests'); // realized-mix audit
const coldRequests = new Counter('users_cold_requests');

// Parse a k6 duration string ('120s', '2m', '1m30s', '24h', '1d') to seconds so
// phase start times can be computed by summation rather than hard-coded.
// NOTE: 'ms' is truncated — keep durations whole-second to avoid phase drift.
function durationToSeconds(d) {
  if (!d) return 0;
  let total = 0;
  const re = /(\d+)(ms|d|h|m|s)/g;
  let m;
  while ((m = re.exec(d)) !== null) {
    const n = Number.parseInt(m[1], 10);
    if (m[2] === 'd') total += n * 86400;
    else if (m[2] === 'h') total += n * 3600;
    else if (m[2] === 'm') total += n * 60;
    else if (m[2] === 's') total += n;
    // 'ms' ignored for whole-second scheduling
  }
  return total;
}
const MEASURE_START = `${durationToSeconds(WARMUP_DURATION)}s`;
const COOLDOWN_START = `${durationToSeconds(WARMUP_DURATION) + durationToSeconds(DURATION)}s`;

export const options = {
  insecureSkipTLSVerify: true,
  // run-k6.sh warns when the summary export lacks http_req_duration p(99), so
  // export it — as a descriptive soak observation only. Per the claim-scope
  // header this is never a publishable p99 claim (p99-stable is wrk2-only).
  summaryTrendStats: ['avg', 'min', 'med', 'max', 'p(90)', 'p(95)', 'p(99)'],
  // Constant traceability labels (low-cardinality, applied to every sample).
  tags: {
    scenario_id: 'entity-read-by-id',
    claim_scope: 'exploratory',
    transport_mode: TRANSPORT_MODE,
  },
  scenarios: {
    // Warmup: excluded from soak analysis (filter phase=warmup out).
    warmup: {
      executor: 'constant-arrival-rate',
      rate: WARMUP_RATE,
      timeUnit: '1s',
      duration: WARMUP_DURATION,
      preAllocatedVUs: PREALLOC_VUS,
      maxVUs: MAX_VUS,
      gracefulStop: '10s',
      tags: { phase: 'warmup' },
    },
    // The soak window — all trend/error observations are read from this phase.
    measurement: {
      executor: 'constant-arrival-rate',
      startTime: MEASURE_START,
      rate: RATE,
      timeUnit: '1s',
      duration: DURATION,
      preAllocatedVUs: PREALLOC_VUS,
      maxVUs: MAX_VUS,
      gracefulStop: '30s',
      tags: { phase: 'measurement' },
    },
    // Cooldown: drains in-flight requests so run-shutdown effects do not
    // contaminate the measurement tail. Excluded from analysis.
    cooldown: {
      executor: 'constant-arrival-rate',
      startTime: COOLDOWN_START,
      rate: COOLDOWN_RATE,
      timeUnit: '1s',
      duration: COOLDOWN_DURATION,
      preAllocatedVUs: PREALLOC_VUS,
      maxVUs: MAX_VUS,
      gracefulStop: '30s',
      tags: { phase: 'cooldown' },
    },
  },
  // `proto` is required by run-k6.sh's protocol honesty guard; `scenario` is
  // required by tools/aggregate-k6-throughput.sh phase bucketing.
  systemTags: [
    'status',
    'method',
    'name',
    'group',
    'check',
    'scenario',
    'expected_response',
    'error_code',
    'proto',
  ],
  // Lenient, observational thresholds: a soak should record degradation, not
  // die on it. These gate nothing comparative (exploratory-only, see header).
  thresholds: {
    http_req_failed: ['rate<0.05'],
    errors: ['rate<0.05'],
  },
};

// Fail-closed executor guard (runtime counterpart of the static
// bench_k6_assert_arrival_rate_executor grep): if a k6 system option
// (K6_DURATION / K6_VUS / K6_ITERATIONS / K6_STAGES — via OS env, or via
// --env on k6 versions that merge --env into the config layer, e.g. v1.4.2)
// clobbered the scenarios above, k6 would silently run a closed-loop default
// scenario and every latency observation would be CO-contaminated. Abort
// instead of producing dishonest output.
const EXPECTED_SCENARIOS = ['warmup', 'measurement', 'cooldown'];
export function setup() {
  const consolidated = (exec.test.options && exec.test.options.scenarios) || {};
  const intact = EXPECTED_SCENARIOS.every(
    (name) => consolidated[name] && consolidated[name].executor === 'constant-arrival-rate'
  );
  if (!intact) {
    exec.test.abort(
      'entity-read-by-id soak: arrival-rate scenarios were overridden by k6 system-level ' +
        'config (K6_DURATION/K6_VUS/K6_ITERATIONS/K6_STAGES reached the k6 config layer). ' +
        'The run would be closed-loop and CO-contaminated. Use --env K6_SOAK_DURATION=... ' +
        'instead, and keep K6_* system keys out of the OS environment.'
    );
  }
}

// Hot/cold id selection over the seeded id space (see HONESTY CAVEAT above:
// the handlers ignore `id`; this shapes the URL stream only).
function pickUserId() {
  if (Math.random() < HOT_RATIO) {
    return { id: ID_MIN + Math.floor(Math.random() * HOT_SPAN), hot: true };
  }
  return { id: ID_MIN + Math.floor(Math.random() * ID_SPAN), hot: false };
}

// Shared outcome accounting: error Rate (threshold), error Counter (absolute
// soak count), and a status-0-vs-other split for triage.
function recordOutcome(res, label) {
  const ok = check(res, { [`${label}: status 200`]: (r) => r.status === 200 });
  errorRate.add(!ok);
  if (!ok) {
    errorCounter.add(1);
    if (res.status === 0) {
      timedOutCounter.add(1); // timeout / connection-level failure
    } else {
      failedOtherCounter.add(1); // unexpected HTTP status
    }
  }
  return ok;
}

export default function () {
  const draw = Math.random();

  if (draw < USERS_CUT) {
    const { id, hot } = pickUserId();
    // tags.name caps URL cardinality (one metrics bucket for all ids);
    // id_class has exactly two values (hot|cold) for split analysis.
    const res = http.get(`${BASE_URL}/api/v1/users?id=${id}`, {
      timeout: REQUEST_TIMEOUT,
      tags: { name: 'GET /api/v1/users?id=:id', id_class: hot ? 'hot' : 'cold' },
    });
    usersLatency.add(res.timings.duration);
    if (hot) {
      hotRequests.add(1);
      usersHotLatency.add(res.timings.duration);
    } else {
      coldRequests.add(1);
      usersColdLatency.add(res.timings.duration);
    }
    recordOutcome(res, 'users read');
  } else if (draw < DB_PING_CUT) {
    const res = http.get(`${BASE_URL}/db/ping`, {
      timeout: REQUEST_TIMEOUT,
      tags: { name: 'GET /db/ping' },
    });
    dbPingLatency.add(res.timings.duration);
    recordOutcome(res, 'db ping');
  } else {
    const res = http.get(`${BASE_URL}/health`, {
      timeout: REQUEST_TIMEOUT,
      tags: { name: 'GET /health' },
    });
    healthLatency.add(res.timings.duration);
    recordOutcome(res, 'health');
  }
}
