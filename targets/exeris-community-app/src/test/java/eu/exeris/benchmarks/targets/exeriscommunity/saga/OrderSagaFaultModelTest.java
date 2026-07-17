package eu.exeris.benchmarks.targets.exeriscommunity.saga;

import org.junit.jupiter.api.Test;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;

/**
 * Locks the CONTRACT-v2 section 4.1 normative constants in place. The hash and the
 * decline rule must be bit-identical in every stack; any deviation here is a
 * correctness bug, not a tuning choice.
 */
final class OrderSagaFaultModelTest {

    @Test
    void fnv1a64MatchesCanonicalTestVectors() {
        // Canonical FNV-1a 64-bit vectors (offset basis 0xcbf29ce484222325, prime 0x100000001b3).
        assertEquals(0xcbf29ce484222325L, OrderSagaOrchestrator.fnv1a64(""));
        assertEquals(0xaf63dc4c8601ec8cL, OrderSagaOrchestrator.fnv1a64("a"));
        assertEquals(0x85944171f73967e8L, OrderSagaOrchestrator.fnv1a64("foobar"));
    }

    @Test
    void moduloIsTakenOnUnsignedInterpretation() {
        // fnv1a64("") = 0xcbf29ce484222325 is negative as a signed long; the contract
        // requires the unsigned remainder (37), not a signed % or floorMod result.
        assertEquals(37L, Long.remainderUnsigned(OrderSagaOrchestrator.fnv1a64(""), 1000L));
    }

    @Test
    void declineRuleSelectsKnownOrderIds() {
        // Wire form is the decimal orderId string. First declined ids in [1..] under
        // decline(orderId) := Long.remainderUnsigned(fnv1a64(orderId), 1000) < 30.
        assertTrue(OrderSagaOrchestrator.isDeclined("5"));
        assertTrue(OrderSagaOrchestrator.isDeclined("13"));
        assertTrue(OrderSagaOrchestrator.isDeclined("50"));
        assertTrue(OrderSagaOrchestrator.isDeclined("95"));
        assertTrue(OrderSagaOrchestrator.isDeclined("104"));

        assertFalse(OrderSagaOrchestrator.isDeclined("1"));
        assertFalse(OrderSagaOrchestrator.isDeclined("42"));
        assertFalse(OrderSagaOrchestrator.isDeclined("1001"));
        assertFalse(OrderSagaOrchestrator.isDeclined("123456789"));
    }

    @Test
    void declinedPopulationIsExactNotStatistical() {
        // CONTRACT-v2 section 4.1 exact-oracle property: the declined subset of a
        // deterministic orderId population is an exact integer, identical every run.
        int declined = 0;
        for (long id = 1; id <= 100_000; id++) {
            if (OrderSagaOrchestrator.isDeclined(Long.toString(id))) {
                declined++;
            }
        }
        assertEquals(3079, declined,
            "declined subset of decimal ids [1..100000] must be exact and run-stable");
    }
}
