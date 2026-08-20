#!/usr/bin/env bash
# Payment-gateway negative control for the saga scenario.
#
# WHY: the stub does IDENTICAL work for every arm - same arrival rate, same 100 ms sleep,
# same container, same code. Its cost is therefore a control: it should be indistinguishable
# across arms, and any spread means the arms are not offering it the same load.
#
# It is NOT indistinguishable. Measured on the 2026-08-20 shape-B campaign, gateway CPU per
# saga: exeris-community 1.165 ms, restate 1.276, quarkus-lra-jdbc 1.278,
# spring-axon-embedded-jdbc 1.393, spring-axon-jdbc 1.457 - a 25.1 % spread, against
# within-arm repeat spreads of under 2 %. Note the direction: the spread FAVOURS
# exeris-community, which is exactly why it needs checking rather than waving through.
#
# WHAT THIS SEPARATES: the stub counts requests and callbacks. requests/saga must be 1.000
# on every arm. Same count with more CPU means a costlier request (connection churn, header
# size, protocol); a higher count means an arm dispatches payment more than once and the
# arms are genuinely not running the same workload - a §2 fairness violation, not a
# performance result.
#
# Counters reset when the stack restarts between reps, so each rep is a clean window.
#
#   tools/saga/gateway-control.sh [out.csv] [interval_s] [stats_url]
set -uo pipefail
OUT="${1:-gateway-stats.csv}"
INTERVAL="${2:-30}"
URL="${3:-http://127.0.0.1:9300/stats}"
echo "ts_utc,requests,callbacks_ok,callbacks_failed,authorized,declined" > "$OUT"
while true; do
  TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  BODY="$(curl -s --max-time 5 "$URL" 2>/dev/null)"
  if [ -n "$BODY" ]; then
    printf '%s' "$BODY" | python3 -c "
import sys, json
d = json.load(sys.stdin)
print('${TS},%d,%d,%d,%d,%d' % (d.get('requests',0), d.get('callbacks_ok',0),
                                d.get('callbacks_failed',0), d.get('authorized',0),
                                d.get('declined',0)))
" >> "$OUT" 2>/dev/null
  fi
  sleep "$INTERVAL"
done
