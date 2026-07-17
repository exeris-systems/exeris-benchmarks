package eu.exeris.benchmarks.targets.restateapp.saga;

import org.junit.jupiter.api.Test;

import java.util.Map;

import static org.junit.jupiter.api.Assertions.assertEquals;

/** EXERIS_SAGA_FAULT_MODE=terminal|off semantics (CONTRACT-v2 §4.1). */
final class SagaFaultModeTest {

    @Test
    void defaultsToTerminalWhenUnset() {
        assertEquals(SagaFaultMode.TERMINAL, SagaFaultMode.parse(null));
        assertEquals(SagaFaultMode.TERMINAL, SagaFaultMode.parse(""));
        assertEquals(SagaFaultMode.TERMINAL, SagaFaultMode.parse("   "));
        assertEquals(SagaFaultMode.TERMINAL, SagaFaultMode.fromEnv(Map.of()));
    }

    @Test
    void parsesBothModesCaseInsensitively() {
        assertEquals(SagaFaultMode.TERMINAL, SagaFaultMode.parse("terminal"));
        assertEquals(SagaFaultMode.TERMINAL, SagaFaultMode.parse("TERMINAL"));
        assertEquals(SagaFaultMode.OFF, SagaFaultMode.parse("off"));
        assertEquals(SagaFaultMode.OFF, SagaFaultMode.parse(" Off "));
        assertEquals(SagaFaultMode.OFF, SagaFaultMode.fromEnv(Map.of(SagaFaultMode.FAULT_MODE_ENV, "off")));
    }

    @Test
    void unrecognizedValueFallsBackToTerminal() {
        assertEquals(SagaFaultMode.TERMINAL, SagaFaultMode.parse("random"));
        assertEquals(SagaFaultMode.TERMINAL, SagaFaultMode.parse("0.03"));
    }

    @Test
    void legacyKnobsAreIgnoredNotHonored() {
        // v1 probabilistic knobs must not alter the mode (warn-and-ignore contract).
        assertEquals(SagaFaultMode.TERMINAL, SagaFaultMode.fromEnv(Map.of(
                SagaFaultMode.LEGACY_FAIL_RATE_ENV, "0.5",
                SagaFaultMode.LEGACY_FAILURE_MODE_ENV, "chaos")));
        assertEquals(SagaFaultMode.OFF, SagaFaultMode.fromEnv(Map.of(
                SagaFaultMode.FAULT_MODE_ENV, "off",
                SagaFaultMode.LEGACY_FAIL_RATE_ENV, "0.5")));
    }
}
