import http from 'k6/http';
import { check } from 'k6';
import { Rate, Trend } from 'k6/metrics';

// Scenario: plaintext hello world
// Path: GET /plaintext
// Expected response: 200 OK, body "plaintext" (15 bytes)
// Purpose: TechEmpower-equivalent baseline for RPS comparison

const errorRate = new Rate('errors');
const latencyTrend = new Trend('request_latency', true);

// Override BASE_URL via K6_ENV or --env BASE_URL=http://...
const BASE_URL = __ENV.BASE_URL || 'http://localhost:8080';

export const options = {
  stages: [
    { duration: '30s', target: 50  },  // ramp-up (not measured)
    { duration: '60s', target: 100 },  // warmup  (not measured)
    { duration: '60s', target: 100 },  // measurement window
    { duration: '10s', target: 0   },  // ramp-down
  ],
  thresholds: {
    http_req_failed:   ['rate<0.01'],           // < 1% error rate
    http_req_duration: ['p(99)<10'],            // p99 < 10ms
    errors:            ['rate<0.01'],
  },
};

export default function () {
  const res = http.get(`${BASE_URL}/plaintext`);

  const ok = check(res, {
    'status is 200': (r) => r.status === 200,
    'body is plaintext': (r) => r.body === 'plaintext',
  });

  errorRate.add(!ok);
  latencyTrend.add(res.timings.duration);
}
