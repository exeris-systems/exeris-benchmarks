import http from 'k6/http';
import { check } from 'k6';
import { Rate, Trend } from 'k6/metrics';

// Scenario: cold-connect-single
// Purpose: Connection setup + single request cost.
// Each VU opens a fresh connection, sends one request, reads response, closes.
// This isolates connection establishment overhead from connection reuse.
// Protocol: H1 (use Connection: close to force fresh connection per request)

const errorRate = new Rate('errors');
const connectLatency = new Trend('connect_latency_ms', true);
const ttfbLatency = new Trend('ttfb_ms', true);
const BASE_URL = __ENV.BASE_URL || __ENV.K6_BASE_URL || 'http://localhost:8080';

export const options = {
  stages: [
    { duration: '30s', target: 10 },   // ramp-up — cold connect at low rate
    { duration: '60s', target: 20 },   // warmup — JIT and stack stabilization
    { duration: '120s', target: 20 },  // measurement window
    { duration: '10s',  target: 0  },  // ramp-down
  ],
  thresholds: {
    http_req_failed:     ['rate<0.01'],
    http_req_connecting: ['p(99)<50'],   // connect latency p99 < 50ms (loopback)
    http_req_duration:   ['p(99)<100'],
    errors:              ['rate<0.01'],
  },
};

export default function () {
  // Force a fresh TCP connection for each request
  const res = http.get(`${BASE_URL}/plaintext`, {
    headers: { 'Connection': 'close' },
  });

  const ok = check(res, {
    'status is 200': (r) => r.status === 200,
  });

  errorRate.add(!ok);
  connectLatency.add(res.timings.connecting);
  ttfbLatency.add(res.timings.waiting);
}
