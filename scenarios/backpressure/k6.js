import http from 'k6/http';
import { check } from 'k6';
import { Rate } from 'k6/metrics';

// Scenario: backpressure / load-shed
// Purpose: Measure error rate and latency tail when target is pushed beyond capacity.
//          Target must not OOM or deadlock. Graceful degradation is the pass criterion.

const errorRate = new Rate('errors');
const BASE_URL = __ENV.BASE_URL || 'http://localhost:8080';
// Max acceptable error rate before we consider load-shed broken
const MAX_ERROR_RATE = parseFloat(__ENV.MAX_ERROR_RATE || '0.30');  // 30%

export const options = {
  stages: [
    { duration: '30s', target: 100 },   // baseline load
    { duration: '30s', target: 500 },   // ramp to overload
    { duration: '60s', target: 500 },   // sustain overload — measure shed behavior
    { duration: '30s', target: 100 },   // recover
    { duration: '30s', target: 100 },   // confirm recovery (must return to baseline RPS)
  ],
  thresholds: {
    // During overload, errors are expected — but must stay bounded
    errors: [`rate<${MAX_ERROR_RATE}`],
    // Target must not crash — even degraded responses are valid
    http_req_failed: [`rate<${MAX_ERROR_RATE}`],
  },
};

export default function () {
  const res = http.get(`${BASE_URL}/plaintext`, { timeout: '5s' });

  // Under backpressure, 503 / 429 / 200 are all acceptable; crashes are not.
  const ok = check(res, {
    'not a 500': (r) => r.status !== 500,
    'not a timeout': (r) => r.timings.duration < 5000,
  });

  errorRate.add(!ok);
}
