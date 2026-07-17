package eu.exeris.benchmarks.targets.restateapp.saga;

import dev.restate.sdk.common.RetryPolicy;
import dev.restate.sdk.endpoint.definition.InvocationRetryPolicy;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

import java.time.Duration;
import java.util.Map;

/**
 * CONTRACT-v2 §5 transient-fault retry policy, pinned identically in every
 * stack: max 3 attempts total (1 initial + 2 retries), exponential backoff,
 * initial 50 ms, factor 2, no jitter. The baseline runner exports
 * EXERIS_SAGA_RETRY_MAX_ATTEMPTS / _INITIAL_BACKOFF_MS / _BACKOFF_FACTOR /
 * _JITTER; the defaults below pin the identical values when unset.
 *
 * Jitter note: Restate's retry knobs (both the per-{@code ctx.run} RetryPolicy
 * and the service-level invocation retry policy) expose no jitter parameter —
 * backoff is deterministic exponential, which is exactly the §5 "no jitter"
 * requirement. EXERIS_SAGA_RETRY_JITTER=true therefore cannot be honored and
 * is warned-and-ignored.
 *
 * §4.1 interplay: the business-terminal decline is thrown as a
 * {@link dev.restate.sdk.common.TerminalException}, which Restate never
 * retries at either layer — zero retries on decline by construction.
 */
public record SagaRetryPolicyConfig(int maxAttempts, long initialBackoffMs, double backoffFactor) {

    public static final String MAX_ATTEMPTS_ENV = "EXERIS_SAGA_RETRY_MAX_ATTEMPTS";
    public static final String INITIAL_BACKOFF_MS_ENV = "EXERIS_SAGA_RETRY_INITIAL_BACKOFF_MS";
    public static final String BACKOFF_FACTOR_ENV = "EXERIS_SAGA_RETRY_BACKOFF_FACTOR";
    public static final String JITTER_ENV = "EXERIS_SAGA_RETRY_JITTER";

    private static final Logger log = LoggerFactory.getLogger(SagaRetryPolicyConfig.class);

    /** CONTRACT-v2 §5 pinned defaults: 3 attempts total, 50 ms initial, factor 2. */
    public static final SagaRetryPolicyConfig CONTRACT_DEFAULTS = new SagaRetryPolicyConfig(3, 50L, 2.0d);

    public static SagaRetryPolicyConfig fromEnv(Map<String, String> env) {
        int maxAttempts = parseInt(env.get(MAX_ATTEMPTS_ENV), CONTRACT_DEFAULTS.maxAttempts(), MAX_ATTEMPTS_ENV);
        long initialBackoffMs = parseLong(env.get(INITIAL_BACKOFF_MS_ENV), CONTRACT_DEFAULTS.initialBackoffMs(), INITIAL_BACKOFF_MS_ENV);
        double backoffFactor = parseDouble(env.get(BACKOFF_FACTOR_ENV), CONTRACT_DEFAULTS.backoffFactor(), BACKOFF_FACTOR_ENV);
        String jitter = env.get(JITTER_ENV);
        if (jitter != null && !jitter.isBlank() && Boolean.parseBoolean(jitter.trim())) {
            log.warn("{}=true is IGNORED: Restate retry backoff is deterministic exponential and exposes no jitter "
                    + "knob — this matches the CONTRACT-v2 §5 'no jitter' requirement", JITTER_ENV);
        }
        return new SagaRetryPolicyConfig(maxAttempts, initialBackoffMs, backoffFactor);
    }

    /**
     * Per-step ({@code ctx.run}) retry policy — governs the journaled side
     * effects of every forward and compensation step. On exhaustion the run
     * block throws TerminalException into the handler, which routes a forward
     * step to backward recovery and a compensation step to FAILED_UNRECOVERED
     * (CONTRACT-v2 §5).
     */
    public RetryPolicy toRunRetryPolicy() {
        return RetryPolicy.exponential(Duration.ofMillis(initialBackoffMs), (float) backoffFactor)
                .setMaxAttempts(maxAttempts);
    }

    /**
     * Service-level (whole-invocation) retry policy, pinned at bind time so
     * restate-server defaults (max-attempts=70) are never trusted
     * (CONTRACT-v2 §5: "defaults are not trusted"). KILL on exhaustion keeps
     * G3 termination observable instead of pausing the invocation.
     */
    public InvocationRetryPolicy toInvocationRetryPolicy() {
        return InvocationRetryPolicy.builder()
                .initialInterval(Duration.ofMillis(initialBackoffMs))
                .exponentiationFactor(backoffFactor)
                .maxAttempts(maxAttempts)
                .onMaxAttempts(InvocationRetryPolicy.OnMaxAttempts.KILL)
                .build();
    }

    private static int parseInt(String value, int fallback, String envName) {
        if (value == null || value.isBlank()) {
            return fallback;
        }
        try {
            return Integer.parseInt(value.trim());
        } catch (NumberFormatException e) {
            log.warn("{}='{}' is not an integer — defaulting to {}", envName, value, fallback);
            return fallback;
        }
    }

    private static long parseLong(String value, long fallback, String envName) {
        if (value == null || value.isBlank()) {
            return fallback;
        }
        try {
            return Long.parseLong(value.trim());
        } catch (NumberFormatException e) {
            log.warn("{}='{}' is not an integer — defaulting to {}", envName, value, fallback);
            return fallback;
        }
    }

    private static double parseDouble(String value, double fallback, String envName) {
        if (value == null || value.isBlank()) {
            return fallback;
        }
        try {
            return Double.parseDouble(value.trim());
        } catch (NumberFormatException e) {
            log.warn("{}='{}' is not a number — defaulting to {}", envName, value, fallback);
            return fallback;
        }
    }
}
