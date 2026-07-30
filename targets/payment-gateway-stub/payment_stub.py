#!/usr/bin/env python3
"""External payment gateway stub for e2e-shop-order-saga (parking workload).

Receives a payment request, answers 202 immediately, then calls back
asynchronously after a configured delay. This is what makes `charge-payment` a
step the saga must PARK on rather than complete inline.

Deliberately dependency-free (stdlib only) and identical for every stack: the
whole point is that all targets pay the same external latency and face the same
decline decision, so no stack can shortcut the wait.

CONTRACT-v2 §4.1 — the decline rule lives HERE now, bit-identical to the rule the
targets used to evaluate in-process:

    decline(orderId) := fnv1a64(orderId) mod 1000 < 30   (unsigned, UTF-8 bytes)

Keeping the rule deterministic and orderId-keyed is what lets the exact
compensation oracle (tools/bench/lib/fnv1a64.py) keep working unchanged: the
expected compensation count over the issued population is still an exact
integer.

Config (env):
  PAYMENT_STUB_PORT            listen port (default 9300)
  PAYMENT_STUB_DELAY_MS        callback delay; the workload parameter that sets
                               parked concurrency (parked ~= rate x delay).
                               100 for perf runs, 1000 for crash runs.
  PAYMENT_STUB_DELAY_JITTER_MS uniform jitter added to the delay (default 0).
                               Keep 0 unless the contract says otherwise —
                               jitter changes the parked-concurrency
                               distribution and must be identical across stacks.
  PAYMENT_STUB_FAULT_MODE      terminal (default) applies the §4.1 decline rule;
                               off authorizes everything. This is the parking-shape
                               home of EXERIS_SAGA_FAULT_MODE: once the decline
                               moved out of the targets, the per-target env var
                               stopped being able to switch faults off, and a knob
                               that silently no-ops is worse than no knob. The
                               baseline passes EXERIS_SAGA_FAULT_MODE through to
                               this variable.
"""
import json
import os
import threading
import time
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

FNV_OFFSET_BASIS = 0xCBF29CE484222325
FNV_PRIME = 0x100000001B3
MASK64 = 0xFFFFFFFFFFFFFFFF
DECLINE_MODULUS = 1000
DECLINE_THRESHOLD = 30

PORT = int(os.environ.get("PAYMENT_STUB_PORT", "9300"))
DELAY_MS = int(os.environ.get("PAYMENT_STUB_DELAY_MS", "100"))
JITTER_MS = int(os.environ.get("PAYMENT_STUB_DELAY_JITTER_MS", "0"))

_RAW_FAULT_MODE = os.environ.get("PAYMENT_STUB_FAULT_MODE", "terminal").strip().lower()
if _RAW_FAULT_MODE not in ("terminal", "off"):
    print(f"payment-gateway-stub WARN: PAYMENT_STUB_FAULT_MODE='{_RAW_FAULT_MODE}' "
          f"(expected terminal|off); defaulting to terminal", flush=True)
    _RAW_FAULT_MODE = "terminal"
FAULT_MODE = _RAW_FAULT_MODE


def fnv1a64(value: str) -> int:
    h = FNV_OFFSET_BASIS
    for byte in value.encode("utf-8"):
        h ^= byte
        h = (h * FNV_PRIME) & MASK64
    return h


def declined(order_id: str) -> bool:
    """CONTRACT-v2 §4.1 — same constants as fnv1a64.py and every target.

    Gated on FAULT_MODE so `off` really disables business-fault injection. The
    §7 compensation oracle must be told the same thing: under `off` the expected
    compensation count is 0, not the FNV-derived integer.
    """
    if FAULT_MODE == "off":
        return False
    return (fnv1a64(order_id) % DECLINE_MODULUS) < DECLINE_THRESHOLD


_stats_lock = threading.Lock()
_stats = {"requests": 0, "callbacks_ok": 0, "callbacks_failed": 0,
          "authorized": 0, "declined": 0}


def _bump(key, n=1):
    with _stats_lock:
        _stats[key] += n


def _deliver(callback_url: str, payload: dict, delay_s: float):
    if delay_s > 0:
        time.sleep(delay_s)
    body = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(
        callback_url, data=body, method="POST",
        headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            resp.read()
        _bump("callbacks_ok")
    except Exception:
        # A failed callback strands a parked saga. Counted, never retried:
        # retrying here would silently mask a target that cannot accept the
        # callback, and the stub must not be the thing that hides that.
        _bump("callbacks_failed")


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *_args):
        pass  # stdout noise would distort nothing but is useless at this rate

    def do_GET(self):
        if self.path.startswith("/health"):
            # fault_mode is advertised here so the baseline can assert what the
            # run actually injected instead of trusting the env it thinks it set.
            self._json(200, {"status": "UP", "delay_ms": DELAY_MS,
                             "fault_mode": FAULT_MODE})
        elif self.path.startswith("/stats"):
            with _stats_lock:
                self._json(200, dict(_stats, delay_ms=DELAY_MS, jitter_ms=JITTER_MS,
                                     fault_mode=FAULT_MODE))
        else:
            self._json(404, {"error": "not_found"})

    def do_POST(self):
        if not self.path.startswith("/payments"):
            self._json(404, {"error": "not_found"})
            return
        try:
            length = int(self.headers.get("Content-Length", "0"))
            req = json.loads(self.rfile.read(length) or b"{}")
        except Exception:
            self._json(400, {"error": "invalid_request"})
            return

        order_id = str(req.get("order_id", "")).strip()
        callback_url = req.get("callback_url")
        if not order_id or not callback_url:
            self._json(400, {"error": "order_id and callback_url are required"})
            return

        _bump("requests")
        is_declined = declined(order_id)
        _bump("declined" if is_declined else "authorized")

        payload = {
            "order_id": order_id,
            "saga_id": req.get("saga_id"),
            "outcome": "DECLINED" if is_declined else "AUTHORIZED",
            "decline_rule": "fnv1a64(orderId) mod 1000 < 30",
        }
        delay_s = DELAY_MS / 1000.0
        if JITTER_MS > 0:
            # Deterministic per-order jitter, NOT random: two runs over the same
            # issued population must produce the same schedule, or the workload
            # stops being reproducible.
            delay_s += ((fnv1a64(order_id) >> 17) % (JITTER_MS + 1)) / 1000.0
        threading.Thread(target=_deliver, args=(callback_url, payload, delay_s),
                         daemon=True).start()

        # 202: the saga parks on this. The outcome arrives via the callback.
        self._json(202, {"order_id": order_id, "status": "PENDING"})

    def _json(self, code, obj):
        body = json.dumps(obj).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


def main():
    server = ThreadingHTTPServer(("0.0.0.0", PORT), Handler)
    server.daemon_threads = True
    print(f"payment-gateway-stub listening on {PORT} "
          f"(delay={DELAY_MS}ms jitter={JITTER_MS}ms fault_mode={FAULT_MODE})", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
