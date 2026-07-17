package eu.exeris.benchmarks.targets.springapp.application.flow;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.stereotype.Component;

import java.nio.charset.StandardCharsets;
import java.util.Locale;

/**
 * Deterministic payment-decline rule for the e2e-shop-order-saga benchmark
 * (CONTRACT-v2 section 4.1). Replaces the Axon-era probabilistic simulator:
 * a payment is <em>declined</em> per-{@code orderId}, never per-attempt —
 * {@code decline(orderId) := Long.remainderUnsigned(fnv1a64(orderId), 1000) < 30},
 * exactly 3.0% of the deterministic orderId population, identical in every
 * stack and every run. A decline is a business-terminal outcome: the caller
 * routes it to backward recovery (LIFO compensation) with zero retries
 * (CONTRACT-v2 section 5).
 *
 * <p>Reads:
 * <ul>
 *   <li>{@code EXERIS_SAGA_FAULT_MODE} — {@code terminal} (default) applies the
 *       section 4.1 decline rule; {@code off} disables fault injection entirely
 *       (every payment succeeds).</li>
 * </ul>
 *
 * <p>The CONTRACT-v1 knobs {@code EXERIS_SAGA_PAYMENT_FAIL_RATE} and
 * {@code EXERIS_SAGA_FAILURE_MODE} are ignored — v2 pins where the randomness
 * lives (nowhere: the decline subset is a pure function of the orderId). Setting
 * either logs a WARN so stale runner configs are caught, not silently misread.
 *
 * <p>Because the declined subset is deterministic and known a priori, the
 * expected compensation count per run is an exact integer
 * ({@code observed_compensations == |declined ∩ issued|}, CONTRACT-v2 section
 * 4.1 exact oracle), not a statistical estimate.
 */
@Component
public class PaymentFailureSimulator {

    /**
     * CONTRACT-v2 fault-injection switch: {@code TERMINAL} (default) applies the
     * section 4.1 deterministic decline rule; {@code OFF} disables fault
     * injection entirely.
     */
    private enum FaultMode { TERMINAL, OFF }

    private static final Logger LOG = LoggerFactory.getLogger(PaymentFailureSimulator.class);

    private static final String FAULT_MODE_ENV = "EXERIS_SAGA_FAULT_MODE";

    /** Legacy CONTRACT-v1 knobs — read only to WARN; their rate semantics are ignored. */
    private static final String LEGACY_PAYMENT_FAIL_RATE_ENV = "EXERIS_SAGA_PAYMENT_FAIL_RATE";
    private static final String LEGACY_FAILURE_MODE_ENV = "EXERIS_SAGA_FAILURE_MODE";

    /** FNV-1a 64-bit offset basis (CONTRACT-v2 section 4.1 normative constant). */
    private static final long FNV1A64_OFFSET_BASIS = 0xcbf29ce484222325L;
    /** FNV-1a 64-bit prime (CONTRACT-v2 section 4.1 normative constant). */
    private static final long FNV1A64_PRIME = 0x100000001b3L;
    /** Decline-rule modulus (CONTRACT-v2 section 4.1 normative constant). */
    private static final long DECLINE_MODULUS = 1000L;
    /** Decline-rule threshold: {@code < 30} of 1000 → exactly 3.0% (section 4.1). */
    private static final long DECLINE_THRESHOLD = 30L;

    private final FaultMode faultMode;

    public PaymentFailureSimulator() {
        this(System.getenv(FAULT_MODE_ENV),
             System.getenv(LEGACY_PAYMENT_FAIL_RATE_ENV),
             System.getenv(LEGACY_FAILURE_MODE_ENV));
    }

    PaymentFailureSimulator(String faultModeValue, String legacyFailRateValue, String legacyFailureModeValue) {
        this.faultMode = parseFaultMode(faultModeValue);
        warnIfLegacyKnobSet(LEGACY_PAYMENT_FAIL_RATE_ENV, legacyFailRateValue);
        warnIfLegacyKnobSet(LEGACY_FAILURE_MODE_ENV, legacyFailureModeValue);
    }

    /**
     * Returns {@code true} when the supplied orderId is in the deterministic
     * declined subset (CONTRACT-v2 section 4.1). Selection is per-orderId, not
     * per-attempt: the same orderId yields the same answer on every call, in
     * every stack, in every run. The caller drives the saga's
     * {@code charge-payment} step return: {@code true} → {@code FlowOutcome.FAIL}
     * (business-terminal, LIFO compensation, zero retries per section 5);
     * {@code false} → {@code FlowOutcome.CONTINUE}.
     *
     * @param orderId the client-visible orderId string; hashed over its UTF-8 bytes
     */
    public boolean shouldDecline(String orderId) {
        return switch (faultMode) {
            case OFF -> false;
            case TERMINAL -> Long.remainderUnsigned(fnv1a64(orderId), DECLINE_MODULUS) < DECLINE_THRESHOLD;
        };
    }

    /**
     * FNV-1a 64-bit over the UTF-8 bytes of {@code value} (CONTRACT-v2 section
     * 4.1 normative hash). Plain {@code long} arithmetic is bit-identical to the
     * unsigned definition; only the final reduction needs
     * {@link Long#remainderUnsigned(long, long)}.
     */
    static long fnv1a64(String value) {
        long hash = FNV1A64_OFFSET_BASIS;
        for (byte b : value.getBytes(StandardCharsets.UTF_8)) {
            hash ^= (b & 0xffL);
            hash *= FNV1A64_PRIME;
        }
        return hash;
    }

    private static FaultMode parseFaultMode(String value) {
        if (value == null || value.isBlank()) {
            return FaultMode.TERMINAL;
        }
        try {
            return FaultMode.valueOf(value.trim().toUpperCase(Locale.ROOT));
        } catch (IllegalArgumentException e) {
            LOG.warn("{}='{}' is not a recognized fault mode (terminal|off) — defaulting to terminal.",
                    FAULT_MODE_ENV, value);
            return FaultMode.TERMINAL;
        }
    }

    private static void warnIfLegacyKnobSet(String envName, String value) {
        if (value != null && !value.isBlank()) {
            LOG.warn("{}='{}' is set but IGNORED under CONTRACT-v2: payment decline is deterministic "
                            + "per-orderId (fnv1a64(orderId) mod 1000 < 30 = 3.0%), not rate-configured. "
                            + "Use {}=terminal|off instead.",
                    envName, value, FAULT_MODE_ENV);
        }
    }
}
