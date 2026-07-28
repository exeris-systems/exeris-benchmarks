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
        // Decimal-string vectors (the pre-v2 fallback key when no client orderId is
        // supplied). First declined ids in [1..] under
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

    @Test
    void k6OrderIdPopulationMatchesHarnessOracle() {
        // Same population the k6 harness issues (K6_ORDER_SEED default 'exeris-saga-v2',
        // measurement scenario, dense index): tools/bench/lib/fnv1a64.py computes 312
        // declines for indices 0..9999. The gate compares this exact integer against the
        // observed compensation count — both sides must agree on the function, and the
        // decline key must be the client-generated orderId adopted verbatim by the API.
        int declined = 0;
        for (int i = 0; i < 10_000; i++) {
            if (OrderSagaOrchestrator.isDeclined("exeris-saga-v2-measurement-i" + i)) {
                declined++;
            }
        }
        assertEquals(312, declined,
            "declined subset must match the fnv1a64.py oracle for the k6 orderId population");
    }
}
