package eu.exeris.benchmarks.targets.restateapp.saga;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

import java.util.Locale;
import java.util.Map;

/**
 * CONTRACT-v2 §4.1 fault mode: TERMINAL (default) applies the deterministic
 * FNV-1a decline rule; OFF disables business-fault injection entirely.
 * Live knob: EXERIS_SAGA_FAULT_MODE=terminal|off.
 */
public enum SagaFaultMode {
    TERMINAL,
    OFF;

    public static final String FAULT_MODE_ENV = "EXERIS_SAGA_FAULT_MODE";
    // v1 probabilistic knobs — superseded by the CONTRACT-v2 §4.1 deterministic
    // per-orderId decline rule. Ignored; a WARN is logged when either is set.
    static final String LEGACY_FAIL_RATE_ENV = "EXERIS_SAGA_PAYMENT_FAIL_RATE";
    static final String LEGACY_FAILURE_MODE_ENV = "EXERIS_SAGA_FAILURE_MODE";

    private static final Logger log = LoggerFactory.getLogger(SagaFaultMode.class);

    public static SagaFaultMode fromEnv(Map<String, String> env) {
        warnIfLegacyKnobSet(env, LEGACY_FAIL_RATE_ENV);
        warnIfLegacyKnobSet(env, LEGACY_FAILURE_MODE_ENV);
        return parse(env.get(FAULT_MODE_ENV));
    }

    static SagaFaultMode parse(String value) {
        if (value == null || value.isBlank()) {
            return TERMINAL;
        }
        try {
            return SagaFaultMode.valueOf(value.trim().toUpperCase(Locale.ROOT));
        } catch (IllegalArgumentException e) {
            log.warn("{}='{}' not recognized (expected terminal|off) — defaulting to terminal", FAULT_MODE_ENV, value);
            return TERMINAL;
        }
    }

    private static void warnIfLegacyKnobSet(Map<String, String> env, String envName) {
        if (env.get(envName) != null) {
            log.warn("{} is set but IGNORED: CONTRACT-v2 §4.1 replaced probabilistic payment failure with the "
                    + "deterministic FNV-1a per-orderId decline rule (control via {}=terminal|off)",
                    envName, FAULT_MODE_ENV);
        }
    }
}
