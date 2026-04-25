import http from 'k6/http';
import { check } from 'k6';
import { Rate } from 'k6/metrics';

// Scenario: 1 KB JSON echo
// Path: POST /echo
// Request: application/json, ~1 KB body
// Response: echo of the same body
// Purpose: JSON parse + serialize cost at small payload

const errorRate = new Rate('errors');
const BASE_URL = __ENV.BASE_URL || __ENV.K6_BASE_URL || 'http://localhost:8080';

// ~1 KB JSON payload
const PAYLOAD = JSON.stringify({
  id: 'bench-0001',
  type: 'echo_request',
  timestamp: '2026-01-01T00:00:00Z',
  payload: {
    name: 'benchmark-user',
    email: 'bench@exeris.io',
    region: 'eu-west',
    tier: 'community',
    roles: ['user', 'reader'],
    metadata: {
      created: '2026-01-01',
      version: '1.0.0',
      flags: ['flag_a', 'flag_b', 'flag_c'],
    },
    data: 'x'.repeat(700),  // pad to ~1 KB
  },
});

const PARAMS = {
  headers: { 'Content-Type': 'application/json' },
};

export const options = {
  stages: [
    { duration: '30s', target: 50  },
    { duration: '60s', target: 100 },  // warmup
    { duration: '60s', target: 100 },  // measure
    { duration: '10s', target: 0   },
  ],
  thresholds: {
    http_req_failed:   ['rate<0.01'],
    http_req_duration: ['p(99)<20'],
    errors:            ['rate<0.01'],
  },
};

export default function () {
  const res = http.post(`${BASE_URL}/echo`, PAYLOAD, PARAMS);

  const ok = check(res, {
    'status is 200': (r) => r.status === 200,
    'body is JSON': (r) => {
      try { JSON.parse(r.body); return true; } catch { return false; }
    },
  });

  errorRate.add(!ok);
}
