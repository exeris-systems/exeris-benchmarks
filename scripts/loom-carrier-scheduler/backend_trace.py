#!/usr/bin/env python3
"""Count the connections on both sides of the server once a second, on CLOCK_MONOTONIC.

Pool side (destination port = the mock's): the server's backend pool holds the client end of every
backend connection, so ESTABLISHED sockets are the pool's open slots, CLOSE_WAIT sockets are slots
the mock has closed and the pool has not yet noticed, and TIME_WAIT sockets are slots the pool
closed within the last minute.

Client side (source port = the server's): the server's end of every load-generator connection, so
a reconnect wave from the load generator, or connections the server closes, show up here.

Output: "mono pool_est pool_close_wait pool_time_wait client_est client_close_wait client_time_wait"

Usage: backend_trace.py <mock-port> <server-port> <seconds>
"""
import subprocess
import sys
import time


def count(state, flt):
    out = subprocess.run(["ss", "-Htn", "state", state, flt], capture_output=True, text=True).stdout
    return sum(1 for line in out.splitlines() if line.strip())


def main(mock_port, server_port, seconds):
    pool, client = f"( dport = :{mock_port} )", f"( sport = :{server_port} )"
    start = time.monotonic()
    print("mono pool_est pool_close_wait pool_time_wait client_est client_close_wait client_time_wait", flush=True)
    for i in range(seconds):
        time.sleep(max(0.0, start + i - time.monotonic()))
        counts = [count(st, f) for f in (pool, client) for st in ("established", "close-wait", "time-wait")]
        print(f"{time.monotonic():.3f} " + " ".join(map(str, counts)), flush=True)


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2], int(sys.argv[3]))
