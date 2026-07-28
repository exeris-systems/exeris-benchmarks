package eu.exeris.benchmarks.targets.restateapp.saga;

import org.junit.jupiter.api.Test;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;

/**
 * Sticky-terminal projection semantics (mirrors the Axon stacks'
 * AxonOrderSagaProjection): once terminal, replayed or out-of-order
 * intermediate updates must not overwrite the outcome.
 */
final class OrderStatusProjectionTest {

    @Test
    void intermediateStatusesProgress() {
        OrderStatusProjection projection = new OrderStatusProjection();
        projection.put("o-1", "7", "SAGA_INITIATED", "saga-a");
        projection.put("o-1", "7", "INVENTORY_RESERVED", "saga-a");
        assertEquals("INVENTORY_RESERVED", projection.findForUser("7", "o-1").orElseThrow().status());
    }

    @Test
    void terminalStatusIsSticky() {
        OrderStatusProjection projection = new OrderStatusProjection();
        projection.put("o-1", "7", "COMPENSATED", "saga-a");
        // Handler replay re-executes non-journaled puts — they must be harmless.
        projection.put("o-1", "7", "SAGA_INITIATED", "saga-a");
        projection.put("o-1", "7", "COMPENSATING", "saga-a");
        assertEquals("COMPENSATED", projection.findForUser("7", "o-1").orElseThrow().status());
    }

    @Test
    void allThreeContractTerminalStatusesAreSticky() {
        for (String terminal : new String[]{"COMPLETED", "COMPENSATED", "FAILED_UNRECOVERED"}) {
            OrderStatusProjection projection = new OrderStatusProjection();
            projection.put("o-1", "7", terminal, "saga-a");
            projection.put("o-1", "7", "PAYMENT_PROCESSING", "saga-a");
            assertEquals(terminal, projection.findForUser("7", "o-1").orElseThrow().status());
        }
    }

    @Test
    void lookupIsScopedToTheOwningUser() {
        OrderStatusProjection projection = new OrderStatusProjection();
        projection.put("o-1", "7", "COMPLETED", "saga-a");
        assertTrue(projection.findForUser("8", "o-1").isEmpty());
        assertTrue(projection.findForUser("7", "o-2").isEmpty());
    }
}
