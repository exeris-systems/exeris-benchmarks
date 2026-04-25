import http from 'k6/http';
import { check } from 'k6';
import { Rate } from 'k6/metrics';

// Scenario: routing 404 fast-path
// Path: GET /does-not-exist
// Purpose: Measure cost of negative routing — the kernel must return 404
//          without traversing the full route trie.

const errorRate = new Rate('errors');
const BASE_URL = __ENV.BASE_URL || __ENV.K6_BASE_URL || 'http://localhost:8080';

export const options = {
  stages: [
    { duration: '30s', target: 50  },
    { duration: '60s', target: 100 },  // warmup
    { duration: '60s', target: 100 },  // measure
    { duration: '10s', target: 0   },
  ],
  thresholds: {
    http_req_failed:   ['rate<0.01'],
    http_req_duration: ['p(99)<5'],   // 404 fast-path should be very cheap
    errors:            ['rate<0.01'],
  },
};

export default function () {
  const res = http.get(`${BASE_URL}/does-not-exist`);

  const ok = check(res, {
    'status is 404': (r) => r.status === 404,
  });

  errorRate.add(!ok);
}
