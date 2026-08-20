#!/usr/bin/env python3
"""Analyse tools/saga/foreign-core-work.sh output: foreign work per measured core set.

    foreign(set) = busy(cores, /proc/stat) - SUM(cpu.stat usage of cgroups confined to that set)

FIRST RESULT, 2026-08-20, 316 s window during a spring-axon-jdbc rep:

    [backend] 6+7+14+15   busy 269.21 core-s (21.3% of capacity)
        postgres 205.53 · axonserver 44.44 · payment-gateway 17.12 · restate-server 2.86
        · lra-coordinator 0.51   =>  SUM 270.46
        FOREIGN  -1.25 core-s  =  -0.5% of busy

Foreign work on the backend set is ZERO within sampling granularity — the negative sign is
cgroup-vs-jiffies rounding, which is what a true zero looks like here. So unpinned root daemons
(dockerd, containerd, rsyslogd, all at affinity 0-15 and unpinnable from this account) do not in
fact land on the cores carrying the measured containers. The housekeeping confound is CLOSED by
measurement rather than bounded, no root and no repin required, and the gateway-spread control
goes back to separating two hypotheses instead of three.

What this does NOT say: it does not say there is no contention. It says there is no THIRD-PARTY
CPU on the set. Mutual interference between the measured containers themselves — a coordinator
crowded onto the two physical cores its own Postgres occupies — is untouched by this result and
remains the reason for disjoint pin sets.

LIMITATION of the target and loadgen rows: the target JVM and k6 are bare processes, not
containers, so they have no docker cgroup to subtract and their sets report ~100% "foreign".
That is the analyser not knowing about them, not a finding. Only the backend row, where every
occupant is a container, is interpretable as written.
"""
import csv, sys, collections
F=sys.argv[1] if len(sys.argv)>1 else "/tmp/fcw.csv"
rows=list(csv.DictReader(open(F)))
ts=sorted(set(r["ts_utc"] for r in rows))
if len(ts)<2:
    print("only %d sample(s) so far (%s) - need 2" % (len(ts), ts)); sys.exit(0)
a,b=ts[0],ts[-1]
def pick(t,kind):
    return {r["name"]:r for r in rows if r["ts_utc"]==t and r["kind"]==kind}
ca,cb=pick(a,"coreset"),pick(b,"coreset")
ga,gb=pick(a,"cgroup"),pick(b,"cgroup")
from datetime import datetime
span=(datetime.strptime(b,"%Y-%m-%dT%H:%M:%SZ")-datetime.strptime(a,"%Y-%m-%dT%H:%M:%SZ")).total_seconds()
print("window %s -> %s  (%.0f s)\n" % (a,b,span))
SETS={"target":8,"loadgen":4,"backend":4}
def d(x,y,k): return float(y[k])-float(x[k])
for s,width in SETS.items():
    if s not in ca or s not in cb: continue
    busy=d(ca[s],cb[s],"busy_s"); sirq=d(ca[s],cb[s],"softirq_s"); sysd=d(ca[s],cb[s],"system_s")
    cores=set(cb[s]["cores"].split("+"))
    own=0.0; members=[]
    for n in gb:
        if n not in ga: continue
        cs=gb[n]["cores"].replace("-","+")
        expanded=set()
        for part in gb[n]["cores"].split("+"):
            if "-" in part:
                lo,hi=part.split("-"); expanded|={str(i) for i in range(int(lo),int(hi)+1)}
            else: expanded.add(part)
        if expanded and expanded <= cores:
            v=d(ga[n],gb[n],"busy_s"); own+=v; members.append((n,v))
    foreign=busy-own
    print("[%s]  %d threads, capacity %.0f core-s over the window" % (s,width,width*span))
    print("   busy            %9.2f core-s   (%.2f%% of capacity)" % (busy, 100*busy/(width*span)))
    print("   of which system %9.2f   softirq %9.2f" % (sysd, sirq))
    for n,v in sorted(members,key=lambda x:-x[1]): print("     cgroup %-42s %8.2f" % (n,v))
    print("   SUM cgroups     %9.2f core-s" % own)
    print("   FOREIGN         %9.2f core-s   = %.1f%% of busy on this set" % (foreign, 100*foreign/busy if busy else 0))
    print()
