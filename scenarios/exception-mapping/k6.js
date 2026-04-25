import http from 'k6/http';
import { check } from 'k6';
import { Rate, Trend } from 'k6/metrics';

// Scenario: exception-mapping
// Path: GET /throw
// Expected: 422 Unprocessable Entity, JSON error body
// Purpose: Exception-to-response mapping overhead (handler throws mapped exception)

const errorRate = new Rate('errors');
const latencyTrend = new Trend('request_latency', true);
const BASE_URL = __ENV.BASE_URL || __ENV.K6_BASE_URL || 'http://localhost:8080';

export const options = {
  stages: [
    { duration: '30s', target: 50  },  // ramp-up (not measured)
    { duration: '60s', target: 100 },  // warmup (not measured)
    { duration: '60s', target: 100 },  // measurement window
    { duration: '10s', target: 0   },  // ramp-down
  ],
  thresholds: {
    http_req_duration: ['p(99)<20'],  // exception mapping must be fast
    errors:            ['rate<0.01'],
  },
};

export default function () {
  const res = http.get(`${BASE_URL}/throw`);

  const ok = check(res, {
    'status is 422': (r) => r.status === 422,
    'body is JSON': (r) => {
      try { JSON.parse(r.body); return true; } catch { return false; }
    },
  });

  errorRate.add(!ok);
  latencyTrend.add(res.timings.duration);
}
