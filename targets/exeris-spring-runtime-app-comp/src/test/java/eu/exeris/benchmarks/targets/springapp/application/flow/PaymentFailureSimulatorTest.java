package eu.exeris.benchmarks.targets.springapp.application.flow;

import org.junit.jupiter.api.Test;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;

/**
 * Locks the CONTRACT-v2 section 4.1 normative constants in place for the
 * spring-on-exeris compat target. The hash and the decline rule must be
 * bit-identical in every stack (see the identical test in
 * {@code exeris-community-app}'s {@code OrderSagaFaultModelTest} and the
 * harness oracle {@code tools/bench/lib/fnv1a64.py}); any deviation here is a
 * correctness bug, not a tuning choice.
 */
final class PaymentFailureSimulatorTest {

    private static PaymentFailureSimulator terminal() {
        return new PaymentFailureSimulator("terminal", null, null);
    }

    @Test
    void fnv1a64MatchesCanonicalTestVectors() {
        // Canonical FNV-1a 64-bit vectors (offset basis 0xcbf29ce484222325, prime 0x100000001b3).
        assertEquals(0xcbf29ce484222325L, PaymentFailureSimulator.fnv1a64(""));
        assertEquals(0xaf63dc4c8601ec8cL, PaymentFailureSimulator.fnv1a64("a"));
        assertEquals(0x85944171f73967e8L, PaymentFailureSimulator.fnv1a64("foobar"));
    }

    @Test
    void moduloIsTakenOnUnsignedInterpretation() {
        // fnv1a64("") = 0xcbf29ce484222325 is negative as a signed long; the contract
        // requires the unsigned remainder (37), not a signed % or floorMod result.
        assertEquals(37L, Long.remainderUnsigned(PaymentFailureSimulator.fnv1a64(""), 1000L));
    }

    @Test
    void declineRuleSelectsKnownOrderIds() {
        // Wire form is the decimal orderId string. First declined ids in [1..] under
        // decline(orderId) := Long.remainderUnsigned(fnv1a64(orderId), 1000) < 30.
        PaymentFailureSimulator simulator = terminal();
        assertTrue(simulator.shouldDecline("5"));
        assertTrue(simulator.shouldDecline("13"));
        assertTrue(simulator.shouldDecline("50"));
        assertTrue(simulator.shouldDecline("95"));
        assertTrue(simulator.shouldDecline("104"));

        assertFalse(simulator.shouldDecline("1"));
        assertFalse(simulator.shouldDecline("42"));
        assertFalse(simulator.shouldDecline("1001"));
        assertFalse(simulator.shouldDecline("123456789"));
    }

    @Test
    void declinedPopulationIsExactNotStatistical() {
        // CONTRACT-v2 section 4.1 exact-oracle property: the declined subset of a
        // deterministic orderId population is an exact integer, identical every run.
        PaymentFailureSimulator simulator = terminal();
        int declined = 0;
        for (long id = 1; id <= 100_000; id++) {
            if (simulator.shouldDecline(Long.toString(id))) {
                declined++;
            }
        }
        assertEquals(3079, declined,
            "declined subset of decimal ids [1..100000] must be exact and run-stable");
    }

    @Test
    void selectionIsPerOrderIdNotPerAttempt() {
        // Section 4.1: per-orderId, never per-attempt — repeated evaluation of the
        // same orderId must be stable across calls.
        PaymentFailureSimulator simulator = terminal();
        boolean first = simulator.shouldDecline("5");
        for (int attempt = 0; attempt < 100; attempt++) {
            assertEquals(first, simulator.shouldDecline("5"));
        }
    }

    @Test
    void faultModeDefaultsToTerminal() {
        assertTrue(new PaymentFailureSimulator(null, null, null).shouldDecline("5"));
        assertTrue(new PaymentFailureSimulator("  ", null, null).shouldDecline("5"));
        // Unrecognized values fall back to terminal (with a WARN), never to off:
        // silently disabling fault injection would fake a 100% success population.
        assertTrue(new PaymentFailureSimulator("bogus", null, null).shouldDecline("5"));
    }

    @Test
    void offModeDisablesFaultInjectionEntirely() {
        PaymentFailureSimulator simulator = new PaymentFailureSimulator("off", null, null);
        assertFalse(simulator.shouldDecline("5"));
        assertFalse(simulator.shouldDecline("13"));
    }

    @Test
    void faultModeParsingIsCaseInsensitive() {
        assertFalse(new PaymentFailureSimulator("OFF", null, null).shouldDecline("5"));
        assertTrue(new PaymentFailureSimulator("Terminal", null, null).shouldDecline("5"));
    }

    @Test
    void legacyKnobsDoNotAlterTheDeclineRule() {
        // CONTRACT-v1 knobs are ignored (WARN only): even ALWAYS_FAIL / rate 1.0
        // must not perturb the deterministic subset.
        PaymentFailureSimulator simulator = new PaymentFailureSimulator(null, "1.0", "ALWAYS_FAIL");
        assertTrue(simulator.shouldDecline("5"));
        assertFalse(simulator.shouldDecline("1"));
    }
}
