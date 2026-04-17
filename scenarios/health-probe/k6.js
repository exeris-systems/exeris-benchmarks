import http from 'k6/http';
import { check, sleep } from 'k6';

const baseUrl = __ENV.BASE_URL || 'http://127.0.0.1:18080';
const expectedStatus = Number(__ENV.EXPECT_STATUS || 200);
const closeConnection = (__ENV.CONNECTION_CLOSE || 'true').toLowerCase() !== 'false';

export const options = {
  stages: [
    { duration: '30s', target: 10 },  // ramp-up / warmup (not measured)
    { duration: '60s', target: 50 },  // measurement window
    { duration: '10s', target: 0  },  // ramp-down
  ],
  thresholds: {
    checks: ['rate>0.99'],
    http_req_failed: ['rate<0.01'],
  },
};

export default function () {
  const params = closeConnection
    ? {
        headers: {
          Connection: 'close',
        },
      }
    : {};

  const response = http.get(`${baseUrl}/health`, params);

  check(response, {
    'status is expected': (r) => r.status === expectedStatus,
  });

  sleep(0.05);
}
