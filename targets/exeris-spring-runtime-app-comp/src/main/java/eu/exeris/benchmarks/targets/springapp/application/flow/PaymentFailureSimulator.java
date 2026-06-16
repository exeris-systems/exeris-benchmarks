package eu.exeris.benchmarks.targets.springapp.application.flow;

import org.springframework.stereotype.Component;

import java.util.concurrent.ThreadLocalRandom;

/**
 * Probabilistic payment-failure simulator preserved verbatim from the Axon-era
 * {@code PaymentService}. Drives the saga's compensation path so the bench
 * scenario exercises both success and failure compensation chains.
 *
 * <p>Reads:
 * <ul>
 *   <li>{@code EXERIS_SAGA_FAILURE_MODE} — one of {@code RANDOM_SEEDED}, {@code ALWAYS_FAIL},
 *       {@code NEVER_FAIL}. Default {@code RANDOM_SEEDED}.</li>
 *   <li>{@code EXERIS_SAGA_PAYMENT_FAIL_RATE} — double in {@code [0, 1]}. Default {@code 0.03}.</li>
 * </ul>
 *
 * <p>Behaviour matches the pre-migration {@code PaymentService.shouldFailPayment()}
 * exactly; this keeps the saga benchmark workload comparable to the prior
 * Axon-on-Tomcat shape on the failure-mix axis (see README baseline-supersession
 * note for why the metrics still can't be regression-checked across the swap).
 */
@Component
public class PaymentFailureSimulator {

    private enum FailureMode { RANDOM_SEEDED, ALWAYS_FAIL, NEVER_FAIL }

    private static final String PAYMENT_FAIL_RATE_ENV = "EXERIS_SAGA_PAYMENT_FAIL_RATE";
    private static final String FAILURE_MODE_ENV = "EXERIS_SAGA_FAILURE_MODE";

    private final double paymentFailureRate;
    private final FailureMode failureMode;

    public PaymentFailureSimulator() {
        this.paymentFailureRate = parseDoubleOrDefault(System.getenv(PAYMENT_FAIL_RATE_ENV), 0.03d);
        this.failureMode = parseFailureMode(System.getenv(FAILURE_MODE_ENV));
    }

    /**
     * Returns {@code true} when the current invocation should simulate a payment failure.
     * Caller drives the saga's {@code charge-payment} step return: {@code true}
     * → {@code FlowOutcome.FAIL} (compensation chain); {@code false} → {@code FlowOutcome.CONTINUE}.
     */
    public boolean shouldFailOnce() {
        return switch (failureMode) {
            case ALWAYS_FAIL -> true;
            case NEVER_FAIL -> false;
            case RANDOM_SEEDED -> ThreadLocalRandom.current().nextDouble() < paymentFailureRate;
        };
    }

    private static double parseDoubleOrDefault(String value, double fallback) {
        if (value == null || value.isBlank()) return fallback;
        try {
            return Double.parseDouble(value.trim());
        } catch (NumberFormatException e) {
            return fallback;
        }
    }

    private static FailureMode parseFailureMode(String value) {
        if (value == null || value.isBlank()) return FailureMode.RANDOM_SEEDED;
        try {
            return FailureMode.valueOf(value.trim().toUpperCase());
        } catch (IllegalArgumentException e) {
            return FailureMode.RANDOM_SEEDED;
        }
    }
}
