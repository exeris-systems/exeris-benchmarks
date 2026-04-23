import http from 'k6/http';
import { check } from 'k6';
import { Rate, Trend } from 'k6/metrics';

// Scenario: concurrent-32
// Concurrency: 32 VUs
// Purpose: Low/medium contention behavior and latency tail at 32 concurrent connections.
// Protocols: H1, H2, H3 (driver substitution per protocol)

const errorRate = new Rate('errors');
const latencyTrend = new Trend('request_latency', true);
const BASE_URL = __ENV.BASE_URL || 'http://localhost:8080';

export const options = {
  stages: [
    { duration: '30s',  target: 16 },  // ramp-up to half concurrency
    { duration: '60s',  target: 32 },  // warmup at full concurrency
    { duration: '120s', target: 32 },  // measurement window
    { duration: '10s',  target: 0  },  // ramp-down
  ],
  thresholds: {
    http_req_failed:   ['rate<0.01'],
    http_req_duration: ['p(99)<15'],
    errors:            ['rate<0.01'],
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
