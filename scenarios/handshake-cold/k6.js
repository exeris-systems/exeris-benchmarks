import http from 'k6/http';
import { check } from 'k6';
import { Rate, Trend } from 'k6/metrics';

// Scenario: handshake-cold
// Purpose: Cold TLS handshake latency measurement.
// Primary: HTTPS/H2+TLS baseline (H3/QUIC pending toolchain).
// Measures: TLS handshake duration as reported by http_req_tls_handshaking metric.
// NOTE: k6 does not expose per-handshake crypto detail. Use JFR/async-profiler for crypto breakdown.

const errorRate = new Rate('errors');
const tlsHandshakeTrend = new Trend('tls_handshake_ms', true);
const BASE_URL = __ENV.BASE_URL || __ENV.K6_BASE_URL || 'https://localhost:8443';

export const options = {
  stages: [
    { duration: '30s',  target: 10 },  // ramp-up
    { duration: '60s',  target: 20 },  // warmup — JVM/server state stabilisation (Connection: close forces new TLS per request)
    { duration: '120s', target: 20 },  // measurement — each request forces a new TCP+TLS handshake via Connection: close
    { duration: '10s',  target: 0  },  // ramp-down
  ],
  thresholds: {
    http_req_failed:          ['rate<0.01'],
    http_req_tls_handshaking: ['p(99)<100'],  // cold TLS p99 < 100ms on loopback
    errors:                   ['rate<0.01'],
  },
  insecureSkipTLSVerify: true,
};

export default function () {
  // Connection: close ensures each request triggers a new TLS handshake
  const res = http.get(`${BASE_URL}/plaintext`, {
    headers: { 'Connection': 'close' },
  });

  const ok = check(res, {
    'status is 200': (r) => r.status === 200,
  });

  errorRate.add(!ok);
  tlsHandshakeTrend.add(res.timings.tls_handshaking);
}
