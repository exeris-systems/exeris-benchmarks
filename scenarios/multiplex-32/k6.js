import http from 'k6/http';
import { check } from 'k6';
import { Rate, Trend } from 'k6/metrics';

// Scenario: multiplex-32
// Protocols: H2, H3 ONLY. H1 does not support stream multiplexing.
// Driver note: k6 does NOT expose H2 stream-level concurrency control.
//   This script simulates 32 concurrent requests via 32 VUs sharing HTTP/2 connections.
//   This is NOT equivalent to h2load -c 1 -m 32 (true stream multiplexing).
//   For stream-level multiplexing claims, use h2load results only.
// Purpose: Observe multiplexing behavior — throughput, latency tail, and HOL-blocking signals.

const errorRate = new Rate('errors');
const latencyTrend = new Trend('request_latency', true);
const BASE_URL = __ENV.BASE_URL || __ENV.K6_BASE_URL || 'http://localhost:8080';

export const options = {
  stages: [
    { duration: '30s',  target: 16 },  // ramp-up
    { duration: '60s',  target: 32 },  // warmup at 32 VUs
    { duration: '120s', target: 32 },  // measurement
    { duration: '10s',  target: 0  },  // ramp-down
  ],
  thresholds: {
    http_req_failed:   ['rate<0.01'],
    http_req_duration: ['p(99)<20'],
    errors:            ['rate<0.01'],
  },
};

export default function () {
  // Small response workload to stress stream multiplexing, not payload processing
  const res = http.get(`${BASE_URL}/plaintext`);

  const ok = check(res, {
    'status is 200': (r) => r.status === 200,
  });

  errorRate.add(!ok);
  latencyTrend.add(res.timings.duration);
}
