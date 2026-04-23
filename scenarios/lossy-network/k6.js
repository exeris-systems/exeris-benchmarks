import http from 'k6/http';
import { check } from 'k6';
import { Rate, Trend } from 'k6/metrics';

// Scenario: lossy-network
// Purpose: Degraded network sensitivity — packet loss, RTT, and jitter.
// PREREQUISITE: Network impairment must be applied BEFORE this script runs:
//   sudo tc qdisc add dev lo root netem delay ${NETEM_DELAY_MS}ms loss ${NETEM_LOSS_PCT}%
// REQUIRED METADATA: NETEM_DELAY_MS and NETEM_LOSS_PCT must be captured in run metadata.
// WARNING: Omitting netem parameters from result metadata makes results invalid for comparison.

const errorRate = new Rate('errors');
const latencyTrend = new Trend('request_latency', true);
const BASE_URL = __ENV.BASE_URL || 'http://localhost:8080';

// Capture impairment profile from env — required for metadata
const NETEM_DELAY_MS  = __ENV.NETEM_DELAY_MS  || 'MISSING';
const NETEM_LOSS_PCT  = __ENV.NETEM_LOSS_PCT   || 'MISSING';
const NETEM_JITTER_MS = __ENV.NETEM_JITTER_MS  || '0';

export const options = {
  stages: [
    { duration: '30s',  target: 20 },  // ramp-up under impairment
    { duration: '60s',  target: 50 },  // warmup
    { duration: '120s', target: 50 },  // measurement window under sustained impairment
    { duration: '10s',  target: 0  },  // ramp-down
  ],
  thresholds: {
    http_req_failed: ['rate<0.10'],  // 10% tolerance — loss is induced
    errors:          ['rate<0.10'],
  },
};

export function setup() {
  if (NETEM_DELAY_MS === 'MISSING' || NETEM_LOSS_PCT === 'MISSING') {
    throw new Error('FATAL: NETEM_DELAY_MS and NETEM_LOSS_PCT must be set. Refusing to run without required impairment metadata.');
  }
  return {
    netem_delay_ms:  NETEM_DELAY_MS,
    netem_loss_pct:  NETEM_LOSS_PCT,
    netem_jitter_ms: NETEM_JITTER_MS,
  };
}

export default function runLossyNetworkScenario(data) {
  const res = http.get(`${BASE_URL}/plaintext`);

  const ok = check(res, {
    'status is 200 or 503': (r) => r.status === 200 || r.status === 503,
    'not a connection error': (r) => r.status !== 0,
  });

  errorRate.add(!ok);
  latencyTrend.add(res.timings.duration);
}
