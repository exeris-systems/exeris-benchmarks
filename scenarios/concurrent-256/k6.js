import http from 'k6/http';
import { check } from 'k6';
import { Rate, Trend } from 'k6/metrics';

// Scenario: concurrent-256
// Concurrency: 256 VUs
// Purpose: High contention behavior, queueing, and backpressure interaction at 256 concurrent connections.
// NOTE: 256 VUs on loopback will likely saturate the target. claim_scope=exploratory until perf-box run.

const errorRate = new Rate('errors');
const latencyTrend = new Trend('request_latency', true);
const BASE_URL = __ENV.BASE_URL || 'http://localhost:8080';

export const options = {
  stages: [
    { duration: '30s',  target: 64  },  // ramp-up phase 1
    { duration: '30s',  target: 128 },  // ramp-up phase 2
    { duration: '60s',  target: 256 },  // warmup at full concurrency
    { duration: '120s', target: 256 },  // measurement window
    { duration: '10s',  target: 0   },  // ramp-down
  ],
  thresholds: {
    http_req_failed:   ['rate<0.05'],  // wider tolerance at high concurrency
    http_req_duration: ['p(99)<100'], // latency tail expected to widen
    errors:            ['rate<0.05'],
  },
};

export default function () {
  const res = http.get(`${BASE_URL}/plaintext`);

  const ok = check(res, {
    'status is 200': (r) => r.status === 200,
  });

  errorRate.add(!ok);
  latencyTrend.add(res.timings.duration);
}
