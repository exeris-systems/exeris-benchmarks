package eu.exeris.benchmarks.targets.restateapp.saga;

import dev.restate.sdk.common.RetryPolicy;
import dev.restate.sdk.endpoint.definition.InvocationRetryPolicy;

import org.junit.jupiter.api.Test;

import java.time.Duration;
import java.util.Map;

import static org.junit.jupiter.api.Assertions.assertEquals;

/**
 * CONTRACT-v2 §5 pinned retry policy: 3 attempts total, 50 ms initial
 * backoff, factor 2, no jitter — configured explicitly, defaults not trusted.
 */
final class SagaRetryPolicyConfigTest {

    @Test
    void contractDefaultsMatchSection5() {
        SagaRetryPolicyConfig config = SagaRetryPolicyConfig.fromEnv(Map.of());
        assertEquals(3, config.maxAttempts());
        assertEquals(50L, config.initialBackoffMs());
        assertEquals(2.0d, config.backoffFactor());
    }

    @Test
    void honorsRunnerExportedKnobs() {
        SagaRetryPolicyConfig config = SagaRetryPolicyConfig.fromEnv(Map.of(
                SagaRetryPolicyConfig.MAX_ATTEMPTS_ENV, "5",
                SagaRetryPolicyConfig.INITIAL_BACKOFF_MS_ENV, "100",
                SagaRetryPolicyConfig.BACKOFF_FACTOR_ENV, "1.5"));
        assertEquals(5, config.maxAttempts());
        assertEquals(100L, config.initialBackoffMs());
        assertEquals(1.5d, config.backoffFactor());
    }

    @Test
    void malformedValuesFallBackToContractDefaults() {
        SagaRetryPolicyConfig config = SagaRetryPolicyConfig.fromEnv(Map.of(
                SagaRetryPolicyConfig.MAX_ATTEMPTS_ENV, "many",
                SagaRetryPolicyConfig.INITIAL_BACKOFF_MS_ENV, "fast",
                SagaRetryPolicyConfig.BACKOFF_FACTOR_ENV, "steep"));
        assertEquals(SagaRetryPolicyConfig.CONTRACT_DEFAULTS, config);
    }

    @Test
    void jitterKnobIsIgnoredDeterministicBackoffOnly() {
        // Restate exposes no jitter parameter (deterministic exponential backoff),
        // which is the §5 requirement; jitter=true must be warn-and-ignore.
        SagaRetryPolicyConfig config = SagaRetryPolicyConfig.fromEnv(Map.of(
                SagaRetryPolicyConfig.JITTER_ENV, "true"));
        assertEquals(SagaRetryPolicyConfig.CONTRACT_DEFAULTS, config);
    }

    @Test
    void runRetryPolicyCarriesPinnedValues() {
        RetryPolicy policy = SagaRetryPolicyConfig.CONTRACT_DEFAULTS.toRunRetryPolicy();
        assertEquals(Duration.ofMillis(50), policy.getInitialDelay());
        assertEquals(2.0f, policy.getExponentiationFactor());
        assertEquals(3, policy.getMaxAttempts());
    }

    @Test
    void invocationRetryPolicyCarriesPinnedValuesAndKillsOnExhaustion() {
        InvocationRetryPolicy policy = SagaRetryPolicyConfig.CONTRACT_DEFAULTS.toInvocationRetryPolicy();
        assertEquals(Duration.ofMillis(50), policy.initialInterval());
        assertEquals(2.0d, policy.exponentiationFactor());
        assertEquals(3, policy.maxAttempts());
        assertEquals(InvocationRetryPolicy.OnMaxAttempts.KILL, policy.onMaxAttempts());
    }
}
