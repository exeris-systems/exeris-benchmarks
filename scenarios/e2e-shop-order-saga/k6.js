import http from 'k6/http';
import { check, sleep } from 'k6';
import exec from 'k6/execution';
import { Rate, Trend, Counter } from 'k6/metrics';

// Scenario: end-to-end shop order saga
// Multi-step stateful workflow: register → recommendations → cart → order → saga poll
// Purpose: Cross-runtime comparison of distributed saga orchestration

// Custom metrics
const errorRate = new Rate('errors');
const authLatency = new Trend('auth_latency_ms', true);
const recommendLatency = new Trend('recommend_latency_ms', true);
const cartAddLatency = new Trend('cart_add_latency_ms', true);
const cartGetLatency = new Trend('cart_get_latency_ms', true);
const orderCreateLatency = new Trend('order_create_latency_ms', true);
const orderPollLatency = new Trend('order_poll_latency_ms', true);
const sagaSuccessRate = new Rate('saga_success');
const sagaCompensatedRate = new Rate('saga_compensated');
const sagaStatusResolvedRate = new Rate('saga_status_resolved');
const sagaUnresolvedRate = new Rate('saga_unresolved');
const sagaPoll404ExhaustedRate = new Rate('saga_poll_404_exhausted');
const sagaFailedRate = new Rate('saga_failed');
const orderCounter = new Counter('orders_initiated');
const pollsCompleted = new Counter('polls_completed');
const admissionRejectedRate = new Rate('admission_rejected');
const reqTimedOutRate = new Rate('req_timed_out');
const reqFailedOtherRate = new Rate('req_failed_other');
const http2Rate = new Rate('http2_rate');

// CONTRACT-v2 §8 outcome-split metrics — latency is reported SEPARATELY per terminal outcome
// population (COMPLETED vs COMPENSATED): mixing them blends two structurally different code
// paths (compensated sagas pay the backward-recovery path on top of the forward steps).
// Durations are client-observed wall-clock ms from order submit (request start) to terminal
// outcome. For async targets resolved via polling this includes the 1 s poll quantization;
// request-response targets (§3) resolve inside the order response itself.
// The pre-v2 Rate metrics above are kept unchanged for backward compat (run-summary.sh,
// baseline result.json merge read saga_success/saga_compensated).
const sagaCompletedDuration = new Trend('saga_completed_duration', true);
const sagaCompensatedDuration = new Trend('saga_compensated_duration', true);
const sagaCompletedTotal = new Counter('saga_completed_total');
const sagaCompensatedTotal = new Counter('saga_compensated_total');
const sagaFailedUnrecoveredTotal = new Counter('saga_failed_unrecovered_total');
const sagaIssuedTotal = new Counter('saga_issued_total');
// CONTRACT-v2 §7 O0 outcome accounting. Every issued orderId lands in exactly one of the
// five terminal buckets, and the harness asserts the identity
//
//   completed + compensated + unrecovered + unresolved + submit_rejected == issued
//
// WHY this exists rather than a lone compensation counter: a single counter cannot tell
// "the system did not compensate" from "the observer did not see it" — both read zero. A
// balanced set can, because a blind detector cannot satisfy the identity: the sagas it
// failed to classify have to land somewhere. The v1 zero-compensation defect was the
// second kind reported as the first.
//
// saga_not_submitted_total is deliberately OUTSIDE the identity: those iterations aborted
// BEFORE issuance (register/recommend/cart failure) and never incremented saga_issued_total,
// so adding them to a sum that equals issued would break the very check this exists to make.
// The review's O0 draft listed NOT_SUBMITTED inside the identity; that is the one place its
// formula does not survive contact with where sagaIssuedTotal.add() actually sits.
const sagaUnresolvedTotal = new Counter('saga_unresolved_total');
const sagaSubmitRejectedTotal = new Counter('saga_submit_rejected_total');
const sagaNotSubmittedTotal = new Counter('saga_not_submitted_total');

// Override BASE_URL via --env BASE_URL=...; K6_BASE_URL is kept as secondary compatibility input.
const BASE_URL = __ENV.BASE_URL || __ENV.K6_BASE_URL || 'http://localhost:8080';
const THINK_TIME_MIN = Number.parseInt(__ENV.K6_THINK_TIME_MIN || '800', 10);
const THINK_TIME_MAX = Number.parseInt(__ENV.K6_THINK_TIME_MAX || '2500', 10);
const MAX_POLL_ATTEMPTS = Number.parseInt(__ENV.K6_MAX_POLL_ATTEMPTS || '25', 10);  // Budget for compensation path to finish before marking unresolved
const REGISTER_MAX_ATTEMPTS = Number.parseInt(__ENV.K6_REGISTER_MAX_ATTEMPTS || '3', 10);
// FAILED_UNRECOVERED is the CONTRACT-v2 §5/§6 terminal-failure state (compensation retry
// budget exhausted); FAILED is kept for pre-v2 targets. COMPENSATING is non-terminal: saga
// rollback still in progress.
// CONTRACT-v2 §3.1 — the terminal vocabulary is DECLARED per stack in
// scenarios/e2e-shop-order-saga/scenario.json and passed in here by the harness.
// It is never inferred and never widened with a fallback.
//
// Why a declaration rather than accepting more spellings: broadening the match
// raises tolerance without removing the class — the next stack brings a third
// name. A declaration turns a silent non-match into a loud missing declaration.
// Two live examples of the class, both found on 2026-07-31:
//   - the inline path accepted `body.saga_status`, which NO stack emits. Dead
//     tolerance protects nothing today and hides the real mismatch tomorrow.
//   - 'FAILED' was accepted "for pre-v2 targets" though §3 never defines it, and
//     was bucketed as unrecovered — so a stack emitting it on a declined payment
//     would turn a MISSING COMPENSATION (a §6 G2 violation) into an O3 line item.
const SAGA_VOCABULARY = (() => {
  const raw = __ENV.K6_TERMINAL_VOCABULARY;
  if (!raw) {
    throw new Error(
      'K6_TERMINAL_VOCABULARY is not set. CONTRACT-v2 §3.1 requires the terminal ' +
      'vocabulary to be declared per stack and read by the harness; guessing it is ' +
      'what produced the v1 zero-compensation defect. Refusing to run.');
  }
  const v = JSON.parse(raw);
  const tokens = v.terminal_tokens || {};
  for (const required of ['COMPLETED', 'COMPENSATED', 'FAILED_UNRECOVERED']) {
    if (!tokens[required]) {
      throw new Error(`terminal_tokens.${required} missing from the declaration for this stack.`);
    }
  }
  if (!v.terminal_field) {
    throw new Error('terminal_field missing from the declaration for this stack.');
  }
  return {
    field: v.terminal_field,
    pollField: v.poll_terminal_field || v.terminal_field,
    completed: tokens.COMPLETED,
    compensated: tokens.COMPENSATED,
    unrecovered: tokens.FAILED_UNRECOVERED,
  };
})();

const TERMINAL_SAGA_STATUSES = new Set([
  SAGA_VOCABULARY.completed, SAGA_VOCABULARY.compensated, SAGA_VOCABULARY.unrecovered,
]);
const POLL_EXPECTED_STATUSES = http.expectedStatuses(200, 404);
// Set K6_EXPECTED_PROTO=HTTP/2.0 to enforce an http2_rate>0.99 threshold.
const EXPECTED_PROTO = __ENV.K6_EXPECTED_PROTO || '';

// CONTRACT-v2 §3 — seeded, deterministic, client-generated orderId.
// Format (normative for this harness):
//   `${ORDER_SEED}-${scenarioName}-i${iterationInTest}`   e.g. 'exeris-saga-v2-measurement-i42'
// exec.scenario.iterationInTest is a zero-based sequential per-scenario index (issued as a
// deterministic prefix 0..N-1) and the scenario names are fixed (warmup/measurement/cooldown),
// so with a fixed seed the SAME orderId set is issued in every run against every stack. This
// is the prerequisite for the §4.1 deterministic decline subset, computed SERVER-side over the
// UTF-8 bytes of exactly this string:
//   decline(orderId) := Long.remainderUnsigned(fnv1a64(orderId), 1000) < 30
//   fnv1a64 = FNV-1a 64-bit, offset_basis 0xcbf29ce484222325, prime 0x100000001b3, unsigned.
const ORDER_SEED = __ENV.K6_ORDER_SEED || 'exeris-saga-v2';

// CONTRACT-v2 §4.1 pinned business-terminal decline rate: exactly 3.0% of the deterministic
// orderId population is declined, per-orderId, SERVER-side. The client injects no payment
// randomness. saga_success/saga_compensated thresholds are pinned to this contract constant;
// the legacy knobs EXERIS_SAGA_PAYMENT_FAIL_RATE / K6_SAGA_EXPECTED_COMPENSATION_RATE are
// accepted but unused (warned once in setup()).
const CONTRACT_DECLINE_RATE = 0.03;

// CONTRACT-v2 §5 pinned transient-fault retry policy — declared explicitly so no default is
// trusted. §4.2 transient injection is out of scope in this phase, so these are configuration-
// of-record only (not yet exercised client-side). A §4.1 decline is business-terminal: zero
// retries — this client never re-submits an order after observing a terminal outcome.
const TRANSIENT_RETRY_MAX_ATTEMPTS_TOTAL = 3;   // 1 initial + 2 retries
const TRANSIENT_RETRY_BACKOFF_INITIAL_MS = 50;  // exponential backoff
const TRANSIENT_RETRY_BACKOFF_FACTOR = 2;       // factor 2, NO jitter (determinism)

// Tunable load parameters — override via --env on the k6 command line or K6_* env vars.
// Phase split (default 120s warmup / 180s measurement / 30s cooldown):
//   warmup      → let the JVM reach steady state (C2 done); EXCLUDED from analysis.
//   measurement → the only window throughput/p99 claims are computed from.
//   cooldown    → drains in-flight sagas without contaminating the measurement tail;
//                 EXCLUDED from analysis.
// Filter the per-second series / per-request samples by phase (or k6 `scenario`) tag.
const WARMUP_RATE       = Number.parseInt(__ENV.K6_WARMUP_RATE        || '2',   10);
const WARMUP_DURATION   = __ENV.K6_WARMUP_DURATION                    || '120s';
const WARMUP_VUS_PRE    = Number.parseInt(__ENV.K6_WARMUP_VUS_PRE     || '20',  10);
const WARMUP_VUS_MAX    = Number.parseInt(__ENV.K6_WARMUP_VUS_MAX     || '60',  10);
const MEASURE_RATE      = Number.parseInt(__ENV.K6_MEASURE_RATE       || '3',   10);
const MEASURE_DURATION  = __ENV.K6_MEASURE_DURATION                   || '180s';
const MEASURE_VUS_PRE   = Number.parseInt(__ENV.K6_MEASURE_VUS_PRE    || '30',  10);
const MEASURE_VUS_MAX   = Number.parseInt(__ENV.K6_MEASURE_VUS_MAX    || '100', 10);
const COOLDOWN_RATE     = Number.parseInt(__ENV.K6_COOLDOWN_RATE      || String(MEASURE_RATE), 10);
const COOLDOWN_DURATION = __ENV.K6_COOLDOWN_DURATION                  || '30s';
const COOLDOWN_VUS_PRE  = Number.parseInt(__ENV.K6_COOLDOWN_VUS_PRE   || String(MEASURE_VUS_PRE), 10);
const COOLDOWN_VUS_MAX  = Number.parseInt(__ENV.K6_COOLDOWN_VUS_MAX   || String(MEASURE_VUS_MAX), 10);

// Parse a k6 duration string ('120s', '2m', '1m30s', '500ms') to seconds so phase
// start times can be computed by summation rather than hard-coded. NOTE: 'ms' is
// truncated, not rounded — phase boundaries are whole seconds, so a sub-second
// component in WARMUP/MEASURE_DURATION would drift MEASURE_START/COOLDOWN_START.
// The defaults are whole seconds; keep them so to avoid that drift.
function durationToSeconds(d) {
  if (!d) return 0;
  let total = 0;
  const re = /(\d+)(ms|h|m|s)/g;
  let m;
  while ((m = re.exec(d)) !== null) {
    const n = Number.parseInt(m[1], 10);
    if (m[2] === 'h') total += n * 3600;
    else if (m[2] === 'm') total += n * 60;
    else if (m[2] === 's') total += n;
    // 'ms' ignored for whole-second scheduling
  }
  return total;
}
const MEASURE_START   = __ENV.K6_MEASURE_START || `${durationToSeconds(WARMUP_DURATION)}s`;
const COOLDOWN_START  = __ENV.K6_COOLDOWN_START
  || `${durationToSeconds(WARMUP_DURATION) + durationToSeconds(MEASURE_DURATION)}s`;

// Build thresholds dynamically — add http2_rate enforcement when K6_EXPECTED_PROTO=HTTP/2.0
const _thresholds = {
  http_req_failed:         ['rate<0.02'],
  http_req_duration:       ['p(99)<5000'],
  errors:                  ['rate<0.02'],
  saga_status_resolved:    ['rate>0.98'],
  saga_unresolved:         ['rate<0.01'],
  saga_poll_404_exhausted: ['rate<0.01'],
  // Pinned to CONTRACT-v2 §4.1 (deterministic 3.0% decline): rate>0.96 / rate<0.08
  saga_success:            [`rate>${(1 - CONTRACT_DECLINE_RATE - 0.01).toFixed(2)}`],
  saga_compensated:        [`rate<${(CONTRACT_DECLINE_RATE + 0.05).toFixed(2)}`],
  admission_rejected:      ['rate<0.05'],
  req_timed_out:           ['rate<0.02'],
  req_failed_other:        ['rate<0.02'],

  // CONTRACT-v2 phase scoping. The phase comment further down states that warmup and cooldown
  // are EXCLUDED from analysis and that consumers must filter by the `phase` tag - but k6's
  // end-of-test summary aggregates every phase, and the harness reads that summary. So the
  // published p95/p99 silently folded the cold-start ramp back in.
  //
  // Measured 2026-08-20, spring-axon-jdbc rep-1: whole-run p95 4654 ms vs measurement-window
  // p95 431 ms. All 2989 slow sagas sat in one contiguous 98 s window starting 11 s into the
  // run and never recurred; reps 2 and 3 of the same arm read 433/433 ms. The defect is
  // INVISIBLE on an arm with no cold-start transient (exeris: 129 ms either way), so it
  // survives review and penalises only the arm that has one.
  //
  // A threshold expression is the only way to make k6 emit a tag-scoped submetric into the
  // summary. These are deliberately non-failing - `p(99)>=0` always holds - because they
  // exist to CREATE the submetric, not to gate. Latency gating lives in the correctness and
  // comparative strict gates; adding one here would be a new policy, not a bug fix.
  'saga_completed_duration{phase:measurement}':   ['p(99)>=0'],
  'saga_compensated_duration{phase:measurement}': ['p(99)>=0'],
  'http_req_duration{phase:measurement}':         ['p(99)>=0'],
  'iteration_duration{phase:measurement}':        ['p(95)>=0'],
};
if (EXPECTED_PROTO === 'HTTP/2.0') {
  _thresholds['http2_rate'] = ['rate>0.99'];
}

export const options = {
  insecureSkipTLSVerify: true,
  scenarios: {
    // Warmup: excluded from comparative analysis
    warmup: {
      executor: 'constant-arrival-rate',
      rate: WARMUP_RATE,
      timeUnit: '1s',
      duration: WARMUP_DURATION,
      preAllocatedVUs: WARMUP_VUS_PRE,
      maxVUs: WARMUP_VUS_MAX,
      // 30s, matching the other two phases. It was 10s, and the measured iteration
      // duration is avg 6.7 s / p95 8.4 s / max 10.07 s - that max IS the gracefulStop,
      // i.e. iterations were being CUT at the warmup boundary rather than finishing. A
      // cut iteration has already incremented saga_issued_total and can then reach no
      // terminal bucket, which is exactly what the O0 identity reported: 244 of 7990
      // (3.05%) unclassified on the 2026-08-19 pinned run, over the 1% truncation bound,
      // failing the run as a detector fault. Warmup iterations that finish after the
      // boundary keep phase=warmup tags, so they add load during measurement - which is
      // what steady state means - without entering measurement's metrics.
      gracefulStop: '30s',
      tags: { phase: 'warmup' },
    },
    // Measurement window — filter by phase=measurement for p99 claims
    measurement: {
      executor: 'constant-arrival-rate',
      startTime: MEASURE_START,
      rate: MEASURE_RATE,
      timeUnit: '1s',
      duration: MEASURE_DURATION,
      preAllocatedVUs: MEASURE_VUS_PRE,
      maxVUs: MEASURE_VUS_MAX,
      gracefulStop: '30s',
      tags: { phase: 'measurement' },
    },
    // Cooldown: drains in-flight sagas after the measurement window so the tail of
    // the measurement window is not contaminated by run-shutdown effects. EXCLUDED
    // from comparative analysis (filter phase=cooldown out).
    cooldown: {
      executor: 'constant-arrival-rate',
      startTime: COOLDOWN_START,
      rate: COOLDOWN_RATE,
      timeUnit: '1s',
      duration: COOLDOWN_DURATION,
      preAllocatedVUs: COOLDOWN_VUS_PRE,
      maxVUs: COOLDOWN_VUS_MAX,
      gracefulStop: '30s',
      tags: { phase: 'cooldown' },
    },
  },
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
  thresholds: _thresholds,
};

// CONTRACT-v2 §4.1: payment decline is deterministic, per-orderId, and SERVER-side — the
// client no longer parametrizes any payment-failure expectation. The legacy env knobs are
// still accepted (k6.env keeps forwarding them for pre-v2 targets) but are unused here.
export function setup() {
  if (__ENV.EXERIS_SAGA_PAYMENT_FAIL_RATE !== undefined) {
    console.warn('CONTRACT-v2: EXERIS_SAGA_PAYMENT_FAIL_RATE is accepted but unused by k6.js — payment decline is deterministic per-orderId on the target (fnv1a64(orderId) mod 1000 < 30 = 3.0%).');
  }
  if (__ENV.K6_SAGA_EXPECTED_COMPENSATION_RATE !== undefined) {
    console.warn('CONTRACT-v2: K6_SAGA_EXPECTED_COMPENSATION_RATE is accepted but unused by k6.js — saga_success/saga_compensated thresholds are pinned to the contract decline rate 0.03.');
  }
}

// Helper function to generate a deterministic unique identity per test iteration
function generateIdentity() {
  // `exec.scenario.iterationInTest` counts PER SCENARIO and restarts at 0 for each of the
  // three phases, while k6 hands the same VU to different scenarios in turn. So a VU that
  // served warmup iteration 400 and later measurement iteration 400 produced the SAME
  // username twice, and `users.username` carries a unique index shared by every arm.
  //
  // The collisions were structural and hit every stack equally; what differed was the
  // answer. exeris returns 409, the other arms return 200/201 for an existing user, and the
  // session below aborts on any non-2xx — so the arm with the stricter REST semantics lost
  // 4.09% of its registrations (1 971 of 48 157) against 0.01% (3 of 46 745) for quarkus,
  // and roughly 1 100 sessions per rep never reached order submission at all. That is the
  // workload penalising a difference in conflict handling, not measuring anything.
  //
  // `iterationInInstance` is the VU's own counter and does not restart between scenarios, so
  // (vu, iteration) is unique for the whole test. Fixing the generator is the right layer:
  // the alternative — accepting 409 as success in the check — would hide a real conflict if
  // one ever occurred for a different reason.
  const iterationInVu = exec.vu.iterationInInstance;
  const vuId = exec.vu.idInTest;
  const username = `user_${vuId}_${iterationInVu}`;

  return {
    username,
    email: `${username}@shop.local`,
  };
}

function sleepRegisterRetry(attempt) {
  const baseDelayMs = 20 * attempt;
  const jitterMs = Math.random() * 30;
  sleep((baseDelayMs + jitterMs) / 1000);
}

function identityForAttempt(baseIdentity, attempt) {
  if (attempt === 1) {
    return baseIdentity;
  }

  const suffix = `_r${attempt}`;
  const atIndex = baseIdentity.email.indexOf('@');
  const emailLocalPart = atIndex >= 0 ? baseIdentity.email.slice(0, atIndex) : baseIdentity.email;
  const emailDomain = atIndex >= 0 ? baseIdentity.email.slice(atIndex) : '';

  return {
    username: `${baseIdentity.username}${suffix}`,
    email: `${emailLocalPart}${suffix}${emailDomain}`,
  };
}

function registerWithRetry(baseUrl, identity) {
  let lastResponse = null;
  let totalDurationMs = 0;

  for (let attempt = 1; attempt <= REGISTER_MAX_ATTEMPTS; attempt++) {
    const attemptIdentity = identityForAttempt(identity, attempt);
    const response = http.post(
      `${baseUrl}/api/v1/auth/register`,
      JSON.stringify({
        username: attemptIdentity.username,
        email: attemptIdentity.email,
        password: 'BenchPass123!',
      }),
      { headers: { 'Content-Type': 'application/json' } }
    );

    lastResponse = response;
    http2Rate.add(response.proto === 'HTTP/2.0');
    totalDurationMs += response.timings.duration;

    if (response.status === 201 || response.status === 200) {
      break;
    }

    if (response.status !== 409 || attempt === REGISTER_MAX_ATTEMPTS) {
      break;
    }

    sleepRegisterRetry(attempt);
  }

  return { response: lastResponse, totalDurationMs };
}

// Helper function to sleep with random jitter
function thinkTime() {
  const delay = THINK_TIME_MIN + Math.random() * (THINK_TIME_MAX - THINK_TIME_MIN);
  sleep(delay / 1000);  // sleep takes seconds
}

// Extract JWT token from response
function extractToken(response) {
  try {
    const body = JSON.parse(response.body);
    return body.token || body.access_token || null;
  } catch (e) {
    return null;
  }
}

// CONTRACT-v2 §3: deterministic, seeded, client-generated orderId — see ORDER_SEED above for
// the normative format. Same (seed, scenario, iteration) → same orderId, every run, every stack.
function generateOrderId() {
  return `${ORDER_SEED}-${exec.scenario.name}-i${exec.scenario.iterationInTest}`;
}

// Extract order ID from response
function extractOrderId(response) {
  try {
    const body = JSON.parse(response.body);
    return body.order_id || body.id || null;
  } catch (e) {
    return null;
  }
}

// CONTRACT-v2 §3 request-response model: the order response may carry the final saga outcome
// (COMPLETED | COMPENSATED | FAILED_UNRECOVERED) directly. Returns the terminal status string,
// or null when the response carries none (async 202-style targets → resolve via polling).
function extractTerminalStatus(response) {
  try {
    const body = JSON.parse(response.body);
    const status = body[SAGA_VOCABULARY.field] || null;
    return TERMINAL_SAGA_STATUSES.has(status) ? status : null;
  } catch (e) {
    return null;
  }
}

// Extract cart ID from response
function extractCartId(response) {
  try {
    const body = JSON.parse(response.body);
    return body.cart_id || body.id || null;
  } catch (e) {
    return null;
  }
}

// Extract product IDs from recommendations
function extractProductIds(response) {
  try {
    const body = JSON.parse(response.body);
    if (Array.isArray(body)) {
      return body.map(p => p.id).filter(id => id);
    }
    if (Array.isArray(body.products)) {
      return body.products.map(p => p.id).filter(id => id);
    }
    if (Array.isArray(body.data)) {
      return body.data.map(p => p.id).filter(id => id);
    }
    return [];
  } catch (e) {
    return [];
  }
}

// Poll saga status and track compensation
function pollSagaStatus(token, orderId, baseUrl) {
  let sagaStatus = 'PENDING';
  let pollCount = 0;
  let pollFailed = false;
  let sawOnly404 = true;

  while (pollCount < MAX_POLL_ATTEMPTS && !TERMINAL_SAGA_STATUSES.has(sagaStatus)) {
    const statusRes = http.get(
      `${baseUrl}/api/v1/orders/${orderId}/status`,
      {
        headers: { 'Authorization': `Bearer ${token}` },
        tags: { name: 'GET /api/v1/orders/:orderId/status' },
        responseCallback: POLL_EXPECTED_STATUSES,
      }
    );

    orderPollLatency.add(statusRes.timings.duration);
    pollsCompleted.add(1);
    pollCount++;
    http2Rate.add(statusRes.proto === 'HTTP/2.0');

    if (statusRes.status === 404) {
      if (pollCount < MAX_POLL_ATTEMPTS) {
        sleep(1);  // Wait 1 second before next poll
      }
      continue;
    }

    sawOnly404 = false;

    if (statusRes.status !== 200) {
      pollFailed = true;
      break;
    }

    try {
      const body = JSON.parse(statusRes.body);
      sagaStatus = body[SAGA_VOCABULARY.pollField] || 'UNKNOWN';
    } catch (e) {
      sagaStatus = 'PARSE_ERROR';
    }

    if (!TERMINAL_SAGA_STATUSES.has(sagaStatus) && pollCount < MAX_POLL_ATTEMPTS) {
      sleep(1);  // Wait 1 second before next poll
    }
  }

  const resolved = TERMINAL_SAGA_STATUSES.has(sagaStatus);
  const exhausted404 = !resolved && !pollFailed && pollCount >= MAX_POLL_ATTEMPTS && sawOnly404;

  return {
    resolved,
    exhausted404,
    pollFailed,
    sagaStatus,
    pollCount,
  };
}

// Classify early-exit failures by cause:
//   status === 0  → network failure (timeout, connection refused, etc.)
//   status === 503 → admission gate rejection (backpressure)
//   anything else  → unexpected HTTP error code
//
// All three Rates are recorded on EVERY classified outcome, not only on the matching one.
// They used to be one-sided (`.add(true)` and nothing else), which makes a k6 Rate degenerate:
// with no false samples the rate is 1.0 the moment a single occurrence lands, so a threshold
// like `rate<0.05` fires on the FIRST 503 and sets k6 exit 99. That is what produced
// runner_status=threshold_failure on all three quarkus-lra-jdbc reps of the 2026-08-20
// campaign. Measured 503 counts there were 1, 5 and 68 out of ~46 743 issued orders - a
// SINGLE 503 in rep-1 breached `rate<0.05` and failed the run, while `errors`, which is
// correctly two-sided, recorded that same event as 0.0021% and passed.
//
// The denominator is deliberately the same as `errors`: one sample per iteration outcome -
// a failed iteration classifies here, a completed one calls classifyIterationOk below. So
// `admission_rejected rate<0.05` reads as "fewer than 5% of iterations died on admission",
// which is what the threshold was always meant to say.
//
// These three Rates are NOT the O0 terms and must never be read as such. O0's submit-rejected
// bucket is the saga_submit_rejected_total Counter incremented at the order-submit failure
// path; a k6 Rate has passes/fails/value and no `count` at all, so reading `.count` off one
// silently yields 0 and manufactures a phantom O0 gap exactly the size of the 503 count.
function classifyFailure(res) {
  const timedOut = res.status === 0;
  const admissionRejected = res.status === 503;
  reqTimedOutRate.add(timedOut);
  admissionRejectedRate.add(admissionRejected);
  reqFailedOtherRate.add(!timedOut && !admissionRejected);
  errorRate.add(true);
}

// The false side of the three cause Rates above, recorded once per iteration that reached a
// terminal saga outcome. Without it those Rates have no denominator.
function classifyIterationOk() {
  reqTimedOutRate.add(false);
  admissionRejectedRate.add(false);
  reqFailedOtherRate.add(false);
}

export default function () {
  // Step 1: Register (JWT auth)
  const identity = generateIdentity();
  const { response: registerRes, totalDurationMs } = registerWithRetry(BASE_URL, identity);

  authLatency.add(totalDurationMs);

  const registerOk = check(registerRes, {
    'register: 201 Created': (r) => r.status === 201 || r.status === 200,
  });

  if (!registerOk) {
    sagaNotSubmittedTotal.add(1);
    classifyFailure(registerRes);
    return;  // Abort user session
  }

  const token = extractToken(registerRes);
  if (!token) {
    return;  // Cannot proceed without token
  }

  // Step 2: Think time
  thinkTime();

  // Step 3: Get recommendations (Graph traversal)
  const recommendRes = http.get(
    `${BASE_URL}/api/v1/products/recommended?limit=10`,
    { headers: { 'Authorization': `Bearer ${token}` } }
  );

  recommendLatency.add(recommendRes.timings.duration);
  http2Rate.add(recommendRes.proto === 'HTTP/2.0');

  const recommendOk = check(recommendRes, {
    'recommend: 200 OK': (r) => r.status === 200,
  });

  if (!recommendOk) {
    sagaNotSubmittedTotal.add(1);
    classifyFailure(recommendRes);
    return;
  }

  const productIds = extractProductIds(recommendRes);
  if (productIds.length === 0) {
    sagaNotSubmittedTotal.add(1);
    return;  // No products to add to cart
  }

  // Step 4: Think time
  thinkTime();

  // Step 5: Add random product to cart
  const randomProduct = productIds[Math.floor(Math.random() * productIds.length)];
  const cartAddRes = http.post(
    `${BASE_URL}/api/v1/cart/add`,
    JSON.stringify({
      product_id: randomProduct,
      quantity: 1,
    }),
    { headers: { 
      'Content-Type': 'application/json',
      'Authorization': `Bearer ${token}` 
    } }
  );

  cartAddLatency.add(cartAddRes.timings.duration);
  http2Rate.add(cartAddRes.proto === 'HTTP/2.0');

  const cartAddOk = check(cartAddRes, {
    'cart add: 201 Created': (r) => r.status === 201 || r.status === 200,
  });

  if (!cartAddOk) {
    sagaNotSubmittedTotal.add(1);
    classifyFailure(cartAddRes);
    return;
  }

  // Step 6: Think time
  thinkTime();

  // Step 7: Get cart (Graph traversal)
  const cartGetRes = http.get(
    `${BASE_URL}/api/v1/cart`,
    { headers: { 'Authorization': `Bearer ${token}` } }
  );

  cartGetLatency.add(cartGetRes.timings.duration);
  http2Rate.add(cartGetRes.proto === 'HTTP/2.0');

  const cartGetOk = check(cartGetRes, {
    'cart get: 200 OK': (r) => r.status === 200,
  });

  if (!cartGetOk) {
    sagaNotSubmittedTotal.add(1);
    classifyFailure(cartGetRes);
    return;
  }

  const cartId = extractCartId(cartGetRes);
  if (!cartId) {
    sagaNotSubmittedTotal.add(1);
    return;
  }

  // Step 8: Think time
  thinkTime();

  // Step 9: Place order (Trigger saga)
  // CONTRACT-v2 §3: the request carries the client-generated deterministic orderId, which
  // doubles as the idempotency key where the stack supports one (Restate: Idempotency-Key
  // header; Exeris: flow instance key; Axon: saga association value).
  const clientOrderId = generateOrderId();
  const orderSubmitStartMs = Date.now();
  const orderRes = http.post(
    `${BASE_URL}/api/v1/orders`,
    JSON.stringify({
      order_id: clientOrderId,
      cart_id: cartId,
      payment_method: 'CARD',
    }),
    { headers: {
      'Content-Type': 'application/json',
      'Authorization': `Bearer ${token}`,
      'Idempotency-Key': clientOrderId,
    } }
  );

  orderCreateLatency.add(orderRes.timings.duration);
  http2Rate.add(orderRes.proto === 'HTTP/2.0');
  orderCounter.add(1);
  // issued = this deterministic orderId was submitted; input to the §4.1 exact oracle
  // (observed_compensations == |declined ∩ issued|).
  //
  // The `oidx` tag carries the per-scenario iterationInTest index of THIS issuance, so the
  // harness can reconstruct the exactly-issued orderId list from the NDJSON stream
  // (`${seed}-${scenario}-i${oidx}`) and feed it to fnv1a64.py --ids-file. Without it the
  // oracle can only regenerate a *dense* 0..N-1 population from counts, which diverges from
  // reality as soon as one iteration aborts before order creation (register/cart failure) —
  // and the gate then fails closed, discarding an otherwise-valid run. One tag value per
  // issued order; identical in every stack, so it introduces no cross-stack asymmetry.
  sagaIssuedTotal.add(1, { oidx: String(exec.scenario.iterationInTest) });

  const orderOk = check(orderRes, {
    // 200 = CONTRACT-v2 §3 request-response (final outcome in the response body);
    // 202/201 = pre-v2 async accept, resolved via status polling.
    'order create: 200/201/202': (r) => r.status === 202 || r.status === 201 || r.status === 200,
  });

  if (!orderOk) {
    // Issued (saga_issued_total already incremented above) but the submission was
    // refused, so no terminal outcome can ever arrive. Counted, or the O0 identity
    // would not balance and every rejected submission would read as detector_fault.
    //
    // TAGGED with the same oidx as saga_issued_total, added 2026-08-21, because O0 balancing
    // was not the only thing these orders affect. The §4.1 expected-decline count is computed
    // by applying fnv1a64 to the WHOLE issued-id list, and a refused submission is in that
    // list — so a refused order whose hash marks it for decline inflates `expected` while
    // being structurally incapable of ever producing a compensation. The gate then reports a
    // shortfall the stack could not have avoided.
    //
    // Measured on quarkus-lra-jdbc, the only arm that gets any 503s: 1024m rep-3 had 68
    // submit-rejected and came up exactly 2 compensations short (68 x 0.03 = 2.04); 256m
    // rep-3 had 3 rejected and came up 1 short. Every rep with a small rejected count
    // (1, 5, 8, 13) passed. That is the §4.1 population being one order wider than the set
    // that can answer it, not a stack failing to compensate.
    //
    // The tag lets the gate subtract the declines among refused submissions from `expected`.
    sagaSubmitRejectedTotal.add(1, { oidx: String(exec.scenario.iterationInTest) });
    classifyFailure(orderRes);
    return;
  }

  // Step 10: Resolve final saga outcome (Compensation tracking)
  // CONTRACT-v2 §3: prefer the terminal outcome carried directly in the order response
  // (request-response model). Fall back to status polling for async targets; poll with the
  // server-echoed order id when present (pre-v2 targets key the status route on their own
  // id), else the client-generated orderId. Terminal outcomes — declines included — are
  // never retried by this client (§4.1/§5: zero retries on decline).
  const inlineStatus = extractTerminalStatus(orderRes);
  let pollResult;
  if (inlineStatus !== null) {
    pollResult = { resolved: true, exhausted404: false, pollFailed: false, sagaStatus: inlineStatus, pollCount: 0 };
  } else {
    const pollOrderId = extractOrderId(orderRes) || clientOrderId;
    pollResult = pollSagaStatus(token, pollOrderId, BASE_URL);
  }
  const sagaDurationMs = Date.now() - orderSubmitStartMs;

  const sagaSuccess = pollResult.sagaStatus === SAGA_VOCABULARY.completed;
  const sagaCompensated = pollResult.sagaStatus === SAGA_VOCABULARY.compensated;
  // FAILED_UNRECOVERED per CONTRACT-v2 §5 (compensation retry budget exhausted); FAILED kept
  // for pre-v2 targets — both count into the unrecovered-failure bucket.
  const sagaUnrecovered = pollResult.sagaStatus === SAGA_VOCABULARY.unrecovered;
  const sagaFailed = sagaUnrecovered || pollResult.pollFailed;
  const sagaUnresolved = !pollResult.resolved;

  // Pre-v2 metrics — kept unchanged for backward compat with existing consumers.
  sagaSuccessRate.add(sagaSuccess);
  sagaCompensatedRate.add(sagaCompensated);
  sagaFailedRate.add(sagaFailed);
  sagaUnresolvedRate.add(sagaUnresolved);
  sagaStatusResolvedRate.add(pollResult.resolved);
  sagaPoll404ExhaustedRate.add(pollResult.exhausted404);
  errorRate.add(!pollResult.resolved || pollResult.pollFailed || sagaUnrecovered);
  classifyIterationOk();

  // CONTRACT-v2 §8 outcome-split metrics: one duration Trend per terminal outcome population.
  if (sagaSuccess) {
    sagaCompletedTotal.add(1);
    sagaCompletedDuration.add(sagaDurationMs);
  } else if (sagaCompensated) {
    sagaCompensatedTotal.add(1);
    sagaCompensatedDuration.add(sagaDurationMs);
  } else if (sagaUnrecovered) {
    sagaFailedUnrecoveredTotal.add(1);
  } else {
    // The branch whose absence WAS the defect: a saga that resolved to nothing the
    // client recognised incremented no total at all, so an oracle reading
    // saga_compensated_total saw a clean zero. Counted now, and the O0 identity
    // has to balance.
    sagaUnresolvedTotal.add(1);
  }
}
