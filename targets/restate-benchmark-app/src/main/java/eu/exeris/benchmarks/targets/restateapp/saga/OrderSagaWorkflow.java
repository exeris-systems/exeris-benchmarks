package eu.exeris.benchmarks.targets.restateapp.saga;

import dev.restate.common.function.ThrowingRunnable;
import dev.restate.sdk.Awakeable;
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
    private final PaymentGatewayClient paymentGateway = new PaymentGatewayClient();

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
        if (faultMode == SagaFaultMode.OFF) {
            // Parsed only so a stale setting is not read as authoritative: under the §4
            // parking workload the effective switch is the gateway's
            // PAYMENT_STUB_FAULT_MODE. A knob that silently no-ops is worse than none.
            log.warn("EXERIS_SAGA_FAULT_MODE=off has no effect in the parking workload: the "
                    + "CONTRACT-v2 §4.1 decline is decided by the external gateway. "
                    + "Set PAYMENT_STUB_FAULT_MODE=off instead.");
        }
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
            // §4.1 decline arrives after the step's forward writes are committed —
            // exactly like the reference stacks, a declined payment still refunds.
            compensations.push(new NamedCompensation("refund-payment",
                    () -> steps.refundPayment(dbOrderId, sagaId)));

            // CONTRACT-v2 §4 (parking workload): charge-payment does not answer inline.
            //
            // The awakeable is created OUTSIDE the run block on purpose: creating it is
            // itself a journaled action, so on replay it yields the same id, whereas an
            // id minted inside a run block would be captured in that block's result and
            // the surrounding code could not see it. The dispatch goes INSIDE a run
            // block so it happens exactly once across replays — a second dispatch would
            // produce a second callback for an already-resolved awakeable.
            Awakeable<PaymentGatewayOutcome> payment = Restate.awakeable(PaymentGatewayOutcome.class);
            Restate.run("charge-payment", retry, () -> {
                steps.requestPayment(dbOrderId, sagaId);
                paymentGateway.dispatch(orderId, sagaId, payment.id());
            });
            projection.put(orderId, userId, "PAYMENT_PROCESSING", sagaId);

            // PARK. Restate suspends the invocation here — no thread, no connection and
            // no request is held while the gateway takes its time; the journal is the
            // only thing that persists. This is the shape the whole workload exists to
            // compare, and it is the one Restate is built around.
            PaymentGatewayOutcome outcome = payment.await();
            if (!outcome.authorized()) {
                // CONTRACT-v2 §4.1: business-terminal decline, decided by the gateway.
                // TerminalException is never retried by Restate (zero retries on
                // decline), routed straight to compensation.
                throw new TerminalException(TerminalException.INTERNAL_SERVER_ERROR_CODE,
                        "payment_declined:" + orderId);
            }

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
