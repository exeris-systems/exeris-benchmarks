#!/usr/bin/env python3
"""
radamsa_attack.py — shared attack engine for the radamsa destructive drivers.

WHY THIS EXISTS
---------------
`radamsa-h1-attacker.py` and `radamsa-h2-attacker.py` were written as two
copies of one design. The H1 copy ran for the first time on 2026-08-26 and
five defects surfaced; the H2 copy has never run and still carries every one
of them, plus its own. Fixing the same taxonomy twice is how the pair drifted
apart in the first place, so the engine now lives once and each protocol
driver supplies only what is actually protocol-specific: the seed bytes, the
"is this payload a complete request" predicate, and any per-connection
preamble.

OUTCOME TAXONOMY (one definition, both protocols)
-------------------------------------------------
The distinction that matters is WHERE the failure happens, and — for
timeouts — WHETHER THE TARGET WAS EVER OBLIGED TO ANSWER.

  refused          connect() failed. The listener is gone, the backlog is
                   exhausted, or the process died. REAL SIGNAL.
  rejected         Closed, reset, or answered nothing AFTER connect. Closing
                   the connection on an unparseable request is specified
                   behaviour (RFC 9112 s2.2), not a crash.
  response         The target answered.
  5xx              The target answered with a 5xx status.
  incomplete-wait  The read timed out AND the mutant does not terminate a
                   request. The target is correctly waiting for the rest of
                   it; the ATTACKER gave up first. NOT a finding.
  hang             The read timed out AND the mutant does terminate a
                   request, so the target owed an answer and did not produce
                   one inside the window. CANDIDATE SIGNAL.

`incomplete-wait` is the timeout-side twin of the `rejected` correction that
landed in #29. Measured on the first H1 campaign: 60 of 410 mutants timed out
at a 2 s socket deadline and all 60 were counted as `hang_count`, while the
target answered /health in 8 ms throughout. A server's header-read timeout is
conventionally 5-60 s, so a 2 s attacker deadline fires on EVERY truncated
mutant regardless of the target's health -- the counter measured the
attacker's patience, not the target's liveness.

Note what `incomplete-wait` does NOT establish: it is not proof the target is
healthy. Whether a target ever times out an incomplete request is precisely
what `destructive-slowloris-h1` measures, and this driver cannot answer it.

THROUGHPUT
----------
The first H1 campaign requested 500 rps and achieved 3.4. Measured on the
perf box, the cause is not mutant generation -- `radamsa` costs 3.1 ms per
spawn, 1.3 s of a 120 s window (1.1 %). It is that the loop was sequential
and every `incomplete-wait` blocked it for the full socket deadline:
60 x 2.0 s = 120.0 s, the entire window. A mean period of
(1 - 60/410) x 3.6 ms + (60/410) x 2000 ms = 295.8 ms predicts the observed
292.7 ms to 1.1 %.

So the engine fires from a worker pool: one slow connection costs one worker,
not the campaign. Batched generation is kept as well -- at 500 rps, 3.1 ms of
spawn per mutant is 1.55 CPU-seconds per wall second and would cap a single
generator thread near 320 rps on its own -- but it is the second-order fix.

CONCURRENCY IS PART OF THE CAMPAIGN'S IDENTITY. Firing N connections at once
is a different stimulus from firing them one at a time, so `workers` is
reported in the summary and belongs in any comparison.

REPRODUCIBILITY
---------------
Batched generation produces a DIFFERENT byte stream from the previous
per-iteration seeding, for the same `--radamsa-seed`. That is unavoidable and
is why the summary carries `mutant_stream`: runs stamped `per-iteration-v1`
(everything up to and including 20260826) are not byte-comparable with
`batched-v2`. Within `batched-v2`, the stream is a pure function of
(seed, chunk_size, index), so the same three reproduce the same bytes.
"""

import ipaddress
import os
import queue
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import time
from concurrent.futures import ThreadPoolExecutor

# Outcome constants — string values are what lands in the JSON summary.
REFUSED = "refused"
REJECTED = "rejected"
RESPONSE = "response"
FIVE_XX = "5xx"
INCOMPLETE_WAIT = "incomplete-wait"
HANG = "hang"

MUTANT_STREAM_ID = "batched-v2"


def radamsa_binary() -> str | None:
    """Locate radamsa. RADAMSA_BIN overrides PATH lookup.

    The perf box installs it to ~/.local/bin, which is absent from a
    non-interactive ssh PATH — an override beats debugging that per host.
    """
    override = os.environ.get("RADAMSA_BIN")
    if override:
        return override if os.path.isfile(override) else None
    return shutil.which("radamsa")


def assert_loopback_or_die(host: str, allow_non_loopback: bool) -> None:
    """Refuse to attack anything that does not resolve to loopback.

    These drivers are benchmark instruments, not general-purpose attack
    tools. The opt-in flag exists for authorized lab targets only.
    """
    try:
        infos = socket.getaddrinfo(host, None)
    except socket.gaierror as exc:
        print(f"ERROR: cannot resolve '{host}': {exc}", file=sys.stderr)
        sys.exit(2)
    for info in infos:
        addr = info[4][0]
        try:
            if not ipaddress.ip_address(addr).is_loopback and not allow_non_loopback:
                print(
                    f"ERROR: '{host}' resolves to non-loopback {addr}. "
                    f"Refusing. Pass --allow-non-loopback to override "
                    f"(e.g. authorized lab targets).",
                    file=sys.stderr,
                )
                sys.exit(2)
        except ValueError:
            print(f"ERROR: cannot parse resolved address '{addr}'",
                  file=sys.stderr)
            sys.exit(2)


class MutantPool:
    """Deterministic mutant stream, generated by radamsa in batches.

    One `radamsa -n <chunk> -s <seed>` invocation replaces <chunk> spawns:
    1.13 ms per mutant against 3.1 ms per spawn, measured on the perf box.

    Generation runs on a BACKGROUND thread feeding a bounded queue. Inline
    refill would have stalled the firing loop for the length of a whole
    chunk -- 2048 mutants x 1.13 ms = 2.3 s -- every 2048 iterations, which
    at 500 rps is a multi-second hole every four seconds. Overlapping it with
    firing is what makes the declared profile reachable at all.

    The per-chunk seed is derived from the base seed and the chunk index
    rather than relying on radamsa's `--seek`, whose resume semantics are not
    something this harness should depend on. Same (base seed, chunk size,
    index) always yields the same bytes, and chunks are consumed in order, so
    the stream is reproducible end to end.
    """

    def __init__(self, seed_bytes: bytes, base_seed: int, chunk_size: int,
                 binary: str, gen_timeout: float = 300.0):
        self._seed_bytes = seed_bytes
        self._base_seed = base_seed
        self._chunk_size = chunk_size
        self._binary = binary
        self._gen_timeout = gen_timeout
        self._queue: queue.Queue = queue.Queue(maxsize=chunk_size * 2)
        self._stop = threading.Event()
        self._proc: subprocess.Popen | None = None
        self._failures = 0
        self._failures_lock = threading.Lock()
        self.mutants_generated = 0
        self._thread = threading.Thread(target=self._produce, daemon=True)
        self._thread.start()

    @property
    def generator_failures(self) -> int:
        with self._failures_lock:
            return self._failures

    def _generate_chunk(self, index: int) -> list[bytes]:
        chunk_seed = (self._base_seed * 1_000_003 + index) % (2 ** 31 - 1)
        # ignore_cleanup_errors: the directory is torn down while a radamsa
        # child may still be writing into it, which raced to
        # "OSError: [Errno 39] Directory not empty" at interpreter exit.
        # close() now reaps the child, but a stale temp dir must never be
        # able to fail a campaign that already produced its result.
        with tempfile.TemporaryDirectory(prefix="radamsa-chunk-",
                                         ignore_cleanup_errors=True) as tmp:
            pattern = os.path.join(tmp, "m-%n")
            try:
                proc = subprocess.Popen(
                    [self._binary, "-s", str(chunk_seed),
                     "-n", str(self._chunk_size), "-o", pattern],
                    stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                )
                self._proc = proc
                try:
                    proc.communicate(input=self._seed_bytes,
                                     timeout=self._gen_timeout)
                finally:
                    self._proc = None
                if proc.returncode != 0:
                    raise subprocess.CalledProcessError(
                        proc.returncode, self._binary)
            except (subprocess.CalledProcessError, subprocess.TimeoutExpired) as exc:
                if self._stop.is_set():
                    # close() kills the in-flight child on purpose. Counting
                    # that as a generator failure reports a normal shutdown as
                    # an attacker-side fault -- the first campaign after the
                    # reaping fix logged exactly one such phantom
                    # ("chunk 31 died with SIGKILL") at the end of its window.
                    return []
                # A genuine generator failure is an ATTACKER-side fault. It is
                # counted and surfaced, never folded into a target-side counter
                # -- the previous drivers charged it to hang_count.
                with self._failures_lock:
                    self._failures += 1
                print(f"WARN: radamsa chunk {index} failed: {exc}", file=sys.stderr)
                return []
            out = []
            for name in sorted(os.listdir(tmp)):
                with open(os.path.join(tmp, name), "rb") as fh:
                    out.append(fh.read())
            return out

    def _produce(self) -> None:
        index = 0
        consecutive_failures = 0
        while not self._stop.is_set():
            mutants = self._generate_chunk(index)
            index += 1
            if not mutants:
                consecutive_failures += 1
                # radamsa failing three chunks running is a configuration
                # fault, not a transient. Stop rather than spin.
                if consecutive_failures >= 3:
                    return
                continue
            consecutive_failures = 0
            self.mutants_generated += len(mutants)
            for m in mutants:
                while not self._stop.is_set():
                    try:
                        self._queue.put(m, timeout=0.5)
                        break
                    except queue.Full:
                        continue
                if self._stop.is_set():
                    return

    def next(self, timeout: float = 10.0) -> bytes | None:
        try:
            return self._queue.get(timeout=timeout)
        except queue.Empty:
            return None

    def close(self, join_timeout: float = 5.0) -> None:
        """Stop generating and reap the child before the interpreter exits.

        Setting the flag alone was not enough: the producer is a daemon
        thread, so if it sat in radamsa when main() returned, the thread was
        killed while its child kept writing files -- which is what raised
        "Directory not empty" out of a tempfile finalizer, after the campaign
        summary had already been printed.
        """
        self._stop.set()
        proc = self._proc
        if proc is not None and proc.poll() is None:
            try:
                proc.kill()
            except OSError:
                pass
        self._thread.join(timeout=join_timeout)


def read_outcome_http1(sock, framing_complete: bool):
    """Default classifier: the first bytes back decide the outcome.

    Sound for HTTP/1.x, where a server sends nothing until it has something
    to say. NOT sound for HTTP/2 -- see read_outcome_h2 in the H2 driver.
    """
    data = sock.recv(4096)
    if not data:
        return REJECTED
    if data.startswith(b"HTTP/1.") and b" 5" in data[:32]:
        return FIVE_XX
    return RESPONSE


def fire_one(host: str, port: int, payload: bytes, timeout: float,
             framing_complete: bool, preamble: bytes = b"",
             read_outcome=read_outcome_http1):
    """Classify ONE attack outcome from the TARGET's point of view.

    Returns either an outcome string or an (outcome, detail) pair; the detail
    is a free-form label the caller histograms (H2 uses it for GOAWAY codes).
    """
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    sock.settimeout(timeout)
    try:
        try:
            sock.connect((host, port))
        except OSError:
            return REFUSED
        try:
            sock.sendall(preamble + payload)
            return read_outcome(sock, framing_complete)
        except socket.timeout:
            # The target owed an answer only if the mutant completed a
            # request. Otherwise it is correctly waiting for the rest.
            return HANG if framing_complete else INCOMPLETE_WAIT
        except (ConnectionResetError, BrokenPipeError):
            return REJECTED
        except OSError:
            return REJECTED
    finally:
        try:
            sock.close()
        except OSError:
            pass


def run_campaign(*, host: str, port: int, pool: MutantPool, rps: int,
                 duration: float, socket_timeout: float, workers: int,
                 is_complete, preamble: bytes = b"",
                 read_outcome=read_outcome_http1) -> dict:
    """Fire a paced, concurrent campaign and return the JSON summary.

    Pacing submits one task every 1/rps seconds. When every worker is busy
    the submission falls behind rather than queueing without bound; the gap
    between requested and achieved rate is reported instead of hidden, so a
    campaign that could not reach its declared profile says so.
    """
    counts = {REFUSED: 0, REJECTED: 0, RESPONSE: 0, FIVE_XX: 0,
              INCOMPLETE_WAIT: 0, HANG: 0}
    # Free-form per-outcome detail, histogrammed. H2 uses it to record which
    # GOAWAY error code the target answered with, i.e. which parser layer
    # rejected the mutant -- the one thing a pure "0 crashes" cannot say.
    details: dict = {}
    counts_lock = threading.Lock()
    exhausted = threading.Event()
    # In-flight work is tracked with a semaphore, not by rescanning a list of
    # futures. The list form is O(pending) per submission -- at 300 000
    # iterations against a 1024-deep queue that is ~3e8 operations spent on
    # bookkeeping, which would have made arena-lifecycle-leak generator-bound
    # for reasons having nothing to do with the target.
    max_inflight = max(workers * 4, 64)
    slots = threading.Semaphore(max_inflight)

    def task(payload: bytes, complete: bool) -> None:
        try:
            outcome = fire_one(host, port, payload, socket_timeout, complete,
                               preamble, read_outcome)
            detail = None
            if isinstance(outcome, tuple):
                outcome, detail = outcome
            with counts_lock:
                counts[outcome] += 1
                if detail is not None:
                    details[detail] = details.get(detail, 0) + 1
        finally:
            slots.release()

    start = time.monotonic()
    deadline = start + duration
    period = 1.0 / rps if rps > 0 else 0.0
    submitted = 0
    backlog_skips = 0

    with ThreadPoolExecutor(max_workers=workers) as pool_exec:
        next_send = start
        while time.monotonic() < deadline:
            now = time.monotonic()
            if now < next_send:
                time.sleep(min(next_send - now, deadline - now))
                continue
            next_send += period

            if not slots.acquire(blocking=False):
                backlog_skips += 1
                continue

            payload = pool.next()
            if payload is None:
                slots.release()
                exhausted.set()
                break
            pool_exec.submit(task, payload, is_complete(payload))
            submitted += 1
        # Leaving the `with` drains in-flight work, which can take up to one
        # socket timeout. That drain is NOT part of the attack window, so the
        # rate is computed over the window and the drain reported separately
        # -- otherwise a campaign looks slower than it ran.
        window_seconds = time.monotonic() - start
    pool.close()

    elapsed = time.monotonic() - start
    total = sum(counts.values())
    return {
        "iterations_total": total,
        # crash_count is connect-failure only. A close after connect is the
        # target refusing bad input, which is what it is supposed to do.
        "crash_count": counts[REFUSED],
        "hang_count": counts[HANG],
        "incomplete_wait_count": counts[INCOMPLETE_WAIT],
        "rejected_count": counts[REJECTED],
        "response_count": counts[RESPONSE],
        "five_xx_count": counts[FIVE_XX],
        "oom_count": 0,
        "duration_seconds": window_seconds,
        "drain_seconds": elapsed - window_seconds,
        "requested_rps": rps,
        "achieved_rps": (total / window_seconds) if window_seconds > 0 else 0.0,
        "workers": workers,
        "socket_timeout_seconds": socket_timeout,
        "submitted": submitted,
        "backlog_skips": backlog_skips,
        "generator_failures": pool.generator_failures,
        "mutant_pool_exhausted": exhausted.is_set(),
        "mutant_stream": MUTANT_STREAM_ID,
        "outcome_details": dict(sorted(details.items())),
    }
