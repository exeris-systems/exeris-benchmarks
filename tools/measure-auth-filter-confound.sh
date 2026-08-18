#!/usr/bin/env bash
# measure-auth-confound.sh
#
# Isolates the per-request cost of the compat security filter — the confound
# that sits inside every spring-on-exeris vs spring-on-exeris-pure number.
#
# A = spring-on-exeris as built            (JwtDecoder bean present ->
#                                           ExerisCompatAutoConfiguration's
#                                           SecurityFilterConfiguration is
#                                           @ConditionalOnBean(JwtDecoder) ->
#                                           ExerisSecurityContextFilter runs)
# B = same jar, JwtDecoder @Bean removed   (no JwtDecoder anywhere: this target
#                                           sets no spring.security.oauth2.*
#                                           properties, so the runtime's own
#                                           ExerisCompatJwtDecoderFactory does
#                                           not supply one either -> filter
#                                           never activates)
#
# Everything else is identical: same source, same dispatcher, same kernel, same
# heap, same pinning, same DB. The A-B delta therefore IS the filter cost, not
# a hosting difference.
#
# Light contract endpoint, because that is where the confound matters: a 40-byte
# single read is dominated by per-request fixed cost, which is exactly what a
# security filter adds.
set -euo pipefail
cd /home/bench/exeris-benchmarks

OUT=/tmp/auth-confound
rm -rf "$OUT"; mkdir -p "$OUT"

SRC=targets/exeris-spring-runtime-app-comp
VAR=/tmp/comp-nosec
JDBC='jdbc:postgresql://localhost:5432/benchmark_db?prepareThreshold=1&defaultRowFetchSize=0&adaptiveFetch=false&preferQueryMode=extended'
JVM="-Xms1280m -Xmx1280m -XX:MaxRAM=2048m --add-opens java.base/sun.nio.ch=ALL-UNNAMED --add-opens java.base/java.io=ALL-UNNAMED --enable-native-access=ALL-UNNAMED --enable-preview -Dspring.classformat.ignore=true"
SERVER_CPUS=0-1,8-9      # identical to the campaign's fairness profile
LOADGEN_CPUS=2-3,10-11
WARMUP=30
MEASURE=90
ROUNDS=2

# ---- build variant B --------------------------------------------------------
rm -rf "$VAR"; cp -r "$SRC" "$VAR"
SC="$VAR/src/main/java/eu/exeris/benchmarks/targets/springapp/application/SecurityConfig.java"
python3 - "$SC" <<'PY'
import re, sys
p = sys.argv[1]
s = open(p).read()

# Remove EXACTLY the JwtDecoder factory method and nothing else. A lazy regex
# spanning from "@Bean" to "public JwtDecoder" is wrong: the beans are declared
# rsaKey / jwtEncoder / jwtDecoder / converter, so such a match starts at the
# @Bean above jwtEncoder and swallows it too. AuthTokenService injects
# JwtEncoder, so losing it fails the context and the run measures nothing.
# Anchor on the signature, walk back to its own @Bean, then brace-match forward.
m = re.search(r'^[ \t]*public\s+JwtDecoder\s+\w+\s*\(', s, re.M)
if not m:
    sys.exit("no JwtDecoder factory method found — aborting")

start = s.rfind('@Bean', 0, m.start())
if start == -1:
    sys.exit("JwtDecoder method has no preceding @Bean — aborting")
line_start = s.rfind('\n', 0, start) + 1

i = s.index('{', m.end() - 1)
depth = 0
while True:
    if s[i] == '{': depth += 1
    elif s[i] == '}':
        depth -= 1
        if depth == 0: break
    i += 1
end = s.index('\n', i) + 1

s2 = s[:line_start] + s[end:]
if 'JwtDecoder' in re.sub(r'/\*.*?\*/', '', s2, flags=re.S).replace('import ', ''):
    pass  # residual mentions in imports/javadoc are harmless
if 'public JwtEncoder' not in s2 or 'public RSAKey' not in s2:
    sys.exit("removal damaged JwtEncoder/RSAKey — aborting")
open(p, 'w').write(s2)
print("variant B: JwtDecoder bean removed (JwtEncoder + RSAKey retained)")
PY

mvn -q -f "$VAR/pom.xml" clean package -DskipTests > "$OUT/build-B.log" 2>&1 \
  || { echo "variant B build FAILED"; tail -15 "$OUT/build-B.log"; exit 1; }
echo "variant B built"

JAR_A="$SRC/target/spring-benchmark-app-1.0.0-SNAPSHOT.jar"
JAR_B="$VAR/target/spring-benchmark-app-1.0.0-SNAPSHOT.jar"
[ -f "$JAR_A" ] || { echo "variant A jar missing — build $SRC first"; exit 1; }

# Static proof that the two jars really sit on opposite sides of the axis.
# A log line would not prove it — the filter does not announce itself — but the
# compiled SecurityConfig either has a jwtDecoder factory method or it does not,
# and SecurityFilterConfiguration is @ConditionalOnBean(JwtDecoder).
prove_variants() {
  local tmp=/tmp/proof; rm -rf "$tmp"; mkdir -p "$tmp/A" "$tmp/B"
  local cls='BOOT-INF/classes/eu/exeris/benchmarks/targets/springapp/application/SecurityConfig.class'
  ( cd "$tmp/A" && unzip -o -q "$OLDPWD/$JAR_A" "$cls" 2>/dev/null ) || true
  ( cd "$tmp/B" && unzip -o -q "$JAR_B" "$cls" 2>/dev/null ) || true
  local a b
  a=$(javap -p "$tmp/A/$cls" 2>/dev/null | grep -c 'JwtDecoder' || true)
  b=$(javap -p "$tmp/B/$cls" 2>/dev/null | grep -c 'JwtDecoder' || true)
  # Two-sided: the earlier version asserted only that B lost JwtDecoder, which a
  # too-greedy edit satisfied while ALSO deleting JwtEncoder — the context then
  # failed to start and the run measured nothing. Assert what must survive too.
  local benc brsa
  benc=$(javap -p "$tmp/B/$cls" 2>/dev/null | grep -c 'JwtEncoder' || true)
  brsa=$(javap -p "$tmp/B/$cls" 2>/dev/null | grep -c 'RSAKey' || true)
  echo "  proof: A JwtDecoder methods = ${a} (expect >=1)"
  echo "  proof: B JwtDecoder methods = ${b} (expect 0)"
  echo "  proof: B JwtEncoder present = ${benc} (expect >=1), RSAKey = ${brsa} (expect >=1)"
  if [ "${a:-0}" -lt 1 ] || [ "${b:-0}" -ne 0 ] || [ "${benc:-0}" -lt 1 ] || [ "${brsa:-0}" -lt 1 ]; then
    echo "  ABORT: variants are not a clean single-axis difference." >&2
    exit 1
  fi
}
prove_variants

run_arm() {
  local label="$1" jar="$2" round="$3"
  local log="$OUT/${label}-r${round}.app.log"

  EXERIS_PORT=9004 EXERIS_DB_JDBC_URL="$JDBC" \
  EXERIS_DB_USERNAME=benchmark EXERIS_DB_PASSWORD=benchmark \
  EXERIS_DB_POOL_MIN_SIZE=16 EXERIS_DB_POOL_MAX_SIZE=256 \
    nohup taskset -c "$SERVER_CPUS" java $JVM -jar "$jar" > "$log" 2>&1 &
  local pid=$!

  for _ in $(seq 1 90); do
    curl -sf -o /dev/null http://localhost:9004/health 2>/dev/null && break
    sleep 1
  done
  curl -sf -o /dev/null http://localhost:9004/health || { echo "$label r$round: NEVER READY"; kill -9 $pid 2>/dev/null; return 1; }

  taskset -c "$LOADGEN_CPUS" wrk -t4 -c128 -d${WARMUP}s "http://localhost:9004/api/v1/user?id=1" > /dev/null 2>&1 || true
  taskset -c "$LOADGEN_CPUS" wrk -t4 -c128 -d${MEASURE}s --latency \
    "http://localhost:9004/api/v1/user?id=1" > "$OUT/${label}-r${round}.wrk.txt" 2>&1 || true

  # kill on an already-exited pid returns non-zero; under `set -e` that killed
  # an earlier version of this script right after the first arm finished.
  kill -TERM $pid 2>/dev/null || true
  sleep 5
  kill -KILL $pid 2>/dev/null || true
  sleep 3
}

for r in $(seq 1 $ROUNDS); do
  echo "=== round $r ==="
  run_arm A "$JAR_A" "$r"
  run_arm B "$JAR_B" "$r"
done

echo
echo "=============================================================="
echo " AUTH-FILTER CONFOUND — light contract (GET /api/v1/user?id=1)"
echo " A = compat WITH ExerisSecurityContextFilter"
echo " B = same jar, filter inactive (JwtDecoder bean removed)"
echo "=============================================================="
printf '%-6s %-8s %14s %12s %12s\n' ARM ROUND REQ/S P50 P99
for r in $(seq 1 $ROUNDS); do
  for a in A B; do
    f="$OUT/${a}-r${r}.wrk.txt"
    [ -f "$f" ] || continue
    rps=$(grep -E '^Requests/sec' "$f" | awk '{print $2}')
    p50=$(grep -E '^\s+50%' "$f" | awk '{print $2}')
    p99=$(grep -E '^\s+99%' "$f" | awk '{print $2}')
    printf '%-6s %-8s %14s %12s %12s\n' "$a" "$r" "${rps:-?}" "${p50:-?}" "${p99:-?}"
  done
done
echo
python3 - "$OUT" "$ROUNDS" <<'PY'
import sys, re, os, statistics
out, rounds = sys.argv[1], int(sys.argv[2])
def rps(a, r):
    f = os.path.join(out, f"{a}-r{r}.wrk.txt")
    if not os.path.exists(f): return None
    m = re.search(r'^Requests/sec:\s+([\d.]+)', open(f).read(), re.M)
    return float(m.group(1)) if m else None
A = [v for v in (rps('A', r) for r in range(1, rounds+1)) if v]
B = [v for v in (rps('B', r) for r in range(1, rounds+1)) if v]
if not A or not B:
    print("insufficient data"); raise SystemExit
ma, mb = statistics.mean(A), statistics.mean(B)
print(f"mean A (with filter)    {ma:10.1f} req/s   rounds={['%.0f'%x for x in A]}")
print(f"mean B (filter absent)  {mb:10.1f} req/s   rounds={['%.0f'%x for x in B]}")
print(f"\nCONFOUND = {(mb-ma)/ma*100:+.2f}%  (B faster by this much => this is the amount")
print( "           by which spring-on-exeris-pure is flattered on the light contract")
print( "           for reasons that are NOT the compat dispatcher)")
if len(A) > 1 and len(B) > 1:
    spread = max(abs(A[0]-A[1])/statistics.mean(A), abs(B[0]-B[1])/statistics.mean(B))*100
    print(f"\nrun-to-run spread within an arm: {spread:.2f}%  — the confound is only")
    print( "meaningful if it exceeds this.")
PY
