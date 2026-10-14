#!/usr/bin/env python3
"""A low-rate latency probe with a timeline: what wrk2 reports only as a histogram.

Sends GET requests on a fixed schedule over a few keep-alive connections and records, for every
request, the time it was due to be sent and how long it took from then. Measuring from the
scheduled time rather than the actual send keeps a stall from hiding the requests queued behind it
on the same connection (the coordinated-omission correction wrk2 applies). Times are
CLOCK_MONOTONIC seconds, the clock the scheduler trace is recorded on.

Output CSV: conn,due_mono,latency_ms,status   (status 0 = connection error)
"""
import argparse
import http.client
import threading
import time
from urllib.parse import urlsplit


def worker(idx, host, port, path, period, offset, start, end, rows):
    conn = None
    k = 0
    while True:
        due = start + offset + k * period
        if due >= end:
            break
        k += 1
        delay = due - time.monotonic()
        if delay > 0:
            time.sleep(delay)
        status = 0
        try:
            if conn is None:
                conn = http.client.HTTPConnection(host, port, timeout=10)
            conn.request("GET", path)
            resp = conn.getresponse()
            resp.read()
            status = resp.status
        except (OSError, http.client.HTTPException):
            if conn is not None:
                conn.close()
            conn = None
        rows.append((idx, due, (time.monotonic() - due) * 1000.0, status))
    if conn is not None:
        conn.close()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--url", required=True)
    ap.add_argument("--rate", type=float, required=True, help="total requests per second")
    ap.add_argument("--duration", type=float, required=True)
    ap.add_argument("--connections", type=int, default=4)
    ap.add_argument("--out", required=True)
    a = ap.parse_args()

    u = urlsplit(a.url)
    period = a.connections / a.rate
    start = time.monotonic() + 0.2
    end = start + a.duration
    rows_by_conn = [[] for _ in range(a.connections)]
    threads = [threading.Thread(target=worker, daemon=True,
                                args=(i, u.hostname, u.port, u.path or "/", period, i * period / a.connections,
                                      start, end, rows_by_conn[i]))
               for i in range(a.connections)]
    for t in threads:
        t.start()
    for t in threads:
        t.join()

    rows = sorted((r for rs in rows_by_conn for r in rs), key=lambda r: r[1])
    with open(a.out, "w") as f:
        f.write("conn,due_mono,latency_ms,status\n")
        for c, due, lat, st in rows:
            f.write(f"{c},{due:.6f},{lat:.3f},{st}\n")
    lat = sorted(r[2] for r in rows if r[3] == 200)
    if lat:
        print(f"probe: {len(rows)} requests, {len(rows) - len(lat)} failed, "
              f"p50 {lat[len(lat) // 2]:.1f} ms, p99 {lat[int(len(lat) * 0.99)]:.1f} ms, max {lat[-1]:.1f} ms")


if __name__ == "__main__":
    main()
