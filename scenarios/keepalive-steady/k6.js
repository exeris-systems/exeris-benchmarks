import http from 'k6/http';
import { check } from 'k6';
import { Rate, Trend } from 'k6/metrics';

// Scenario: keepalive-steady
// Path: GET /plaintext
// Purpose: Steady-state latency/throughput with long-lived keepalive connections.
//          k6 uses keepalive by default. Do NOT set Connection: close.

const errorRate = new Rate('errors');
const latencyTrend = new Trend('request_latency', true);
const BASE_URL = __ENV.BASE_URL || __ENV.K6_BASE_URL || 'http://localhost:8080';

export const options = {
  stages: [
    { duration: '30s',  target: 50  },  // ramp-up
    { duration: '60s',  target: 100 },  // warmup — connections established and stabilized
    { duration: '120s', target: 100 },  // measurement window — steady-state keepalive
    { duration: '10s',  target: 0   },  // ramp-down
  ],
  thresholds: {
    http_req_failed:   ['rate<0.01'],
    http_req_duration: ['p(99)<10'],
    errors:            ['rate<0.01'],
  },
};

export default function () {
  // No Connection: close header — keepalive is the test condition
  const res = http.get(`${BASE_URL}/plaintext`);

  const ok = check(res, {
    'status is 200': (r) => r.status === 200,
  });

  errorRate.add(!ok);
  latencyTrend.add(res.timings.duration);
}
