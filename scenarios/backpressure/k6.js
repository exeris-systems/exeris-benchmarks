import http from 'k6/http';
import { Rate } from 'k6/metrics';

// Scenario: backpressure / load-shed
// Purpose: Measure error rate and latency tail when target is pushed beyond capacity.
//          Target must not OOM or deadlock. Graceful degradation is the pass criterion.

const errorRate = new Rate('errors');
const shedRate = new Rate('shed_rate');
const crashRate = new Rate('crash_failures');
const BASE_URL = __ENV.BASE_URL || __ENV.K6_BASE_URL || 'http://localhost:8080';
const MAX_ERROR_RATE = Number.parseFloat(__ENV.MAX_ERROR_RATE || '0.30');
const BASELINE_RATE  = Number.parseInt(__ENV.EXERIS_BASELINE_RATE || __ENV.BASELINE_RATE  || '200',  10);  // RPS at baseline
const OVERLOAD_RATE  = Number.parseInt(__ENV.EXERIS_OVERLOAD_RATE || __ENV.OVERLOAD_RATE  || '2000', 10);  // RPS at overload peak
const ACCEPTABLE_STATUSES = http.expectedStatuses(200, 429, 503);

export const options = {
  scenarios: {
    overload: {
      executor: 'ramping-arrival-rate',
      startRate: BASELINE_RATE,
      timeUnit: '1s',
      preAllocatedVUs: 200,
      maxVUs: 1000,
      stages: [
        { duration: '30s', target: BASELINE_RATE  },  // baseline load
        { duration: '30s', target: OVERLOAD_RATE  },  // ramp to overload
        { duration: '60s', target: OVERLOAD_RATE  },  // sustain overload — measure shed behavior
        { duration: '30s', target: BASELINE_RATE  },  // recover
        { duration: '30s', target: BASELINE_RATE  },  // confirm recovery
      ],
    },
  },
  thresholds: {
    // During overload, non-200 responses are expected but must stay bounded.
    errors:         [`rate<${MAX_ERROR_RATE}`],
    shed_rate:      [`rate<${MAX_ERROR_RATE}`],
    // Crashes/transport failures are never acceptable in this scenario.
    crash_failures: ['rate==0'],
    http_req_failed: ['rate==0'],
  },
};

export default function backpressureDefault() {
  const res = http.get(`${BASE_URL}/plaintext`, {
    timeout: '5s',
    responseCallback: ACCEPTABLE_STATUSES,
  });

  const status = Number.isFinite(res?.status) ? res.status : null;
  const duration = Number.isFinite(res?.timings?.duration)
    ? res.timings.duration
    : Number.POSITIVE_INFINITY;

  const isShed = status === 429 || status === 503;
  const isCrash = status === 500 || duration >= 5000 || status === null || status <= 0;
  const isError = status !== 200;

  errorRate.add(isError);
  shedRate.add(isShed);
  crashRate.add(isCrash);
}
