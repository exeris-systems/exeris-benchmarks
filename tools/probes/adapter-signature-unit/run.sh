#!/usr/bin/env bash
# Does adaptorCount grow per CLASS or per SIGNATURE? Measured on the JDK 28 build
# that ran the Valhalla arms.
set -u
J=/opt/jdk28
cd "$(dirname "$0")"
"$J/bin/javac" -d . Baseline.java SameSig.java DistinctSig.java HighArity.java || exit 1

read_adaptors() {  # $1 = jfr file
  "$J/bin/jfr" print --events CodeCacheStatistics "$1" 2>/dev/null \
    | awk '/adaptorCount/ {gsub(/[^0-9]/,"",$2); if ($2 != "") last=last" "$2} END{print last}'
}

for cls in Baseline SameSig DistinctSig HighArity; do
  for rep in 1 2 3; do
    f="/tmp/sig-$cls-$rep.jfr"
    rm -f "$f"
    "$J/bin/java" -XX:StartFlightRecording:settings=profile,filename=$f,dumponexit=true \
        -XX:+UnlockDiagnosticVMOptions "$cls" > /dev/null 2>&1
    # sum the per-heap adaptorCount of the LAST sample set
    total=$("$J/bin/jfr" print --events CodeCacheStatistics "$f" 2>/dev/null \
      | grep -E 'startTime|adaptorCount' \
      | paste - - | tail -3 | awk '{gsub(/[^0-9]/,"",$NF); s+=$NF} END{print s}')
    echo "$cls rep$rep adaptors_total=$total"
  done
done
