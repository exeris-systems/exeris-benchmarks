package eu.exeris.benchmarks.targets.quarkusapp.axon;

import jakarta.enterprise.context.ApplicationScoped;

import java.util.function.Supplier;

/**
 * CONTRACT-v2 §5 pinned transient-fault retry policy: max 3 attempts total (1 initial
 * + 2 retries), exponential backoff with 50 ms initial delay, factor 2, no jitter
 * (determinism). Configured explicitly here — framework defaults are not trusted.
 *
 * <p>Scope: transient infrastructure faults (§4.2) only. A §4.1 business-terminal
 * payment decline is a return value, not an exception, so it never reaches this
 * policy — declined payments are routed to compensation with zero retries. Transient
 * fault injection itself is out of scope in this phase; this class pins the machinery.
 */
@ApplicationScoped
public class OrderSagaRetryPolicy {

    static final int MAX_ATTEMPTS = 3;
    static final long INITIAL_BACKOFF_MILLIS = 50L;
    static final long BACKOFF_FACTOR = 2L;

    public void run(String stepId, Runnable step) {
        get(stepId, () -> {
            step.run();
            return null;
        });
    }

    public <T> T get(String stepId, Supplier<T> step) {
        long backoffMillis = INITIAL_BACKOFF_MILLIS;
        RuntimeException lastFailure = null;
        for (int attempt = 1; attempt <= MAX_ATTEMPTS; attempt++) {
            try {
                return step.get();
            } catch (RuntimeException e) {
                lastFailure = e;
            }
            if (attempt < MAX_ATTEMPTS) {
                if (!backOff(backoffMillis)) {
                    break;
                }
                backoffMillis *= BACKOFF_FACTOR;
            }
        }
        throw new RetryExhaustedException(stepId, lastFailure);
    }

    private static boolean backOff(long millis) {
        try {
            Thread.sleep(millis);
            return true;
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
            return false;
        }
    }

    /** Signals §5 retry-budget exhaustion for a single saga step. */
    public static class RetryExhaustedException extends RuntimeException {
        RetryExhaustedException(String stepId, Throwable lastFailure) {
            super("Retry budget exhausted for saga step '" + stepId + "' (max " + MAX_ATTEMPTS
                    + " attempts, CONTRACT-v2 §5)", lastFailure);
        }
    }
}
