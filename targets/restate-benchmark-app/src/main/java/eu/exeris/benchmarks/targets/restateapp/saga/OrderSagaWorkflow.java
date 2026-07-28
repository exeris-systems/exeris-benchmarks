package eu.exeris.benchmarks.targets.restateapp.saga;

import dev.restate.common.function.ThrowingRunnable;
import dev.restate.sdk.Restate;
import dev.restate.sdk.annotation.Handler;
import dev.restate.sdk.annotation.Name;
import dev.restate.sdk.annotation.Service;
import dev.restate.sdk.common.RetryPolicy;
import dev.restate.sdk.common.TerminalException;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

import java.util.ArrayDeque;
import java.util.Deque;

/**
 * Shop-order fulfillment saga on Restate (official sagas-guide pattern:
 * compensation list + TerminalException + LIFO unwind in the catch block).
 *
 * Step sequence and domain writes mirror the reference Axon stacks
 * (spring-benchmark-app OrderFulfillmentSaga):
 *
 *   create-order (saga start, orders + order_items)
 *   RESERVE_INVENTORY   → compensation restore-inventory
 *   CHARGE_PAYMENT (pivot, §4.1 FNV decline after forward writes)
 *                       → compensation refund-payment
 *   CONFIRM_ORDER       (no compensation)
 *   COMPLETE_ORDER      (no compensation)
 *
 * Every forward step and every compensation executes inside a journaled run
 * block ({@code Restate.run} — the SDK 2.9 reflection-API spelling of
 * {@code ctx.run}, identical semantics: journaled once, replayed on retry,
 * never re-executed after success)
 * with the CONTRACT-v2 §5 pinned retry policy (3 attempts / 50 ms / x2 /
 * no jitter). A §4.1 decline throws {@link TerminalException} — Restate never
 * retries terminal exceptions, so the decline reaches the catch block with
 * zero retries and triggers the LIFO compensation unwind
 * (refund-payment, then restore-inventory — same order as the Axon saga).
 * Retry exhaustion inside a compensation {@code ctx.run} surfaces as a
 * TerminalException from that run block and terminates the saga
 * FAILED_UNRECOVERED (§5 / §7 O3).
 */
@Service
@Name("OrderSaga")
public class OrderSagaWorkflow {

    private static final Logger log = LoggerFactory.getLogger(OrderSagaWorkflow.class);

    private final OrderSagaSqlSteps steps;
    private final OrderStatusProjection projection;
    private final SagaFaultMode faultMode;
    private final SagaRetryPolicyConfig retryConfig;

    public OrderSagaWorkflow(
            OrderSagaSqlSteps steps,
            OrderStatusProjection projection,
            SagaFaultMode faultMode,
            SagaRetryPolicyConfig retryConfig
    ) {
        this.steps = steps;
        this.projection = projection;
        this.faultMode = faultMode;
        this.retryConfig = retryConfig;
    }

    @Handler
    public OrderSagaResult run(OrderSagaRequest request) {
        String orderId = request.orderId();
        String userId = request.userId();
        String sagaId = request.sagaId();
        RetryPolicy retry = retryConfig.toRunRetryPolicy();

        projection.put(orderId, userId, "SAGA_INITIATED", sagaId);
        long dbOrderId = Restate.run("create-order", Long.class, retry,
                () -> steps.insertOrder(userId, request.cartId(), sagaId));

        Deque<NamedCompensation> compensations = new ArrayDeque<>();
        try {
            Restate.run("reserve-inventory", retry, () -> steps.reserveInventory(dbOrderId, sagaId));
            compensations.push(new NamedCompensation("restore-inventory",
                    () -> steps.restoreInventory(dbOrderId, sagaId)));
            projection.put(orderId, userId, "INVENTORY_RESERVED", sagaId);

            // Pivot step. Compensation is registered BEFORE the charge because the
            // §4.1 decline fires after the step's forward writes are committed —
            // exactly like the reference stacks, a declined payment still refunds.
            compensations.push(new NamedCompensation("refund-payment",
                    () -> steps.refundPayment(dbOrderId, sagaId)));
            Restate.run("charge-payment", retry, () -> {
                steps.requestPayment(dbOrderId, sagaId);
                // CONTRACT-v2 §4.1: deterministic per-orderId business decline —
                // BUSINESS-TERMINAL. TerminalException is never retried by Restate
                // (zero retries on decline), routed straight to compensation.
                if (faultMode == SagaFaultMode.TERMINAL && PaymentDeclineRule.isDeclined(orderId)) {
                    throw new TerminalException(TerminalException.INTERNAL_SERVER_ERROR_CODE,
                            "payment_declined:" + orderId);
                }
            });
            projection.put(orderId, userId, "PAYMENT_PROCESSING", sagaId);

            Restate.run("confirm-order", retry, () -> steps.confirmOrder(dbOrderId, sagaId));
            projection.put(orderId, userId, "CONFIRMED", sagaId);

            Restate.run("complete-order", retry, () -> steps.completeOrder(dbOrderId, sagaId));
            projection.put(orderId, userId, "COMPLETED", sagaId);
            return new OrderSagaResult(orderId, OrderSagaResult.COMPLETED, sagaId);
        } catch (TerminalException e) {
            // Backward recovery: LIFO over the registered compensations
            // (refund-payment, then restore-inventory), each in a journaled run block.
            projection.put(orderId, userId, "COMPENSATING", sagaId);
            try {
                for (NamedCompensation compensation : compensations) {
                    Restate.run(compensation.name(), retry, compensation.action());
                }
            } catch (TerminalException compensationFailure) {
                // §5: compensation retry-budget exhaustion → FAILED_UNRECOVERED,
                // counted separately (§7 O3), never silently swallowed.
                log.error("saga {} compensation failed unrecovered: {}", sagaId, compensationFailure.getMessage());
                projection.put(orderId, userId, "FAILED_UNRECOVERED", sagaId);
                return new OrderSagaResult(orderId, OrderSagaResult.FAILED_UNRECOVERED, sagaId);
            }
            projection.put(orderId, userId, "COMPENSATED", sagaId);
            return new OrderSagaResult(orderId, OrderSagaResult.COMPENSATED, sagaId);
        }
    }

    /**
     * Compensation registered for a completed (or, for the pivot,
     * write-committed) forward step. Deque iteration order is LIFO because
     * registrations use {@code push} — matches the CONTRACT-v2 §2 unwind order.
     */
    record NamedCompensation(String name, ThrowingRunnable action) {}
}
