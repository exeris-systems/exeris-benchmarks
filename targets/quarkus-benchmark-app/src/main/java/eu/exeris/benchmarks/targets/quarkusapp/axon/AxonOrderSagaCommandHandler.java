package eu.exeris.benchmarks.targets.quarkusapp.axon;

import eu.exeris.benchmarks.targets.quarkusapp.axon.command.CreateOrderCommand;
import eu.exeris.benchmarks.targets.quarkusapp.dto.OrderAcceptedView;

import jakarta.enterprise.context.ApplicationScoped;
import jakarta.inject.Inject;

/**
 * Order-fulfillment saga, split at the parking step (CONTRACT-v2 §4).
 *
 * <p>Until 2026-07-30 this ran the whole saga inline on one command round-trip: a
 * transaction script with compensation. That was possible only because no step
 * waited for anything outside the process. With {@code charge-payment} dispatching
 * to an external gateway, an inline saga would have to hold its caller across the
 * external wait, so the handler is split into two halves that share no in-process
 * state:
 *
 * <ol>
 *   <li>{@link #handle} — insert-order, reserve-inventory, payment-requested writes,
 *       dispatch to the gateway. Returns with the saga PARKED.</li>
 *   <li>{@link #settle} — driven by the gateway callback: forward to confirm/complete
 *       on authorisation, LIFO compensation on decline.</li>
 * </ol>
 *
 * <p>The halves are joined by the {@code orders} row alone — {@code settle} receives
 * the db order id from the callback's compare-and-set, so nothing about an in-flight
 * saga is held in this JVM's heap. That is a deliberate property, not an accident:
 * it is what makes this stack's parked-capacity behaviour worth measuring in shape C
 * rather than trivially bounded by a map.
 *
 * <p>What this stack still does NOT have is a saga engine: there is no persisted
 * saga instance, no scheduler, and no resumption after a restart. A park here is
 * "a row in PAYMENT_PROCESSING that some future callback may complete", and if the
 * callback never arrives, nothing ever reconsiders it. Registered under §9(a).
 */
@ApplicationScoped
public class AxonOrderSagaCommandHandler {

    /**
     * Status of the CONTRACT-v2 §3 response when the saga has parked on payment. Not a
     * terminal outcome: the caller awaits the settlement before answering the client.
     */
    static final String PARKED = "PARKED";

    @Inject
    OrderSagaStepService stepService;

    @Inject
    OrderSagaRetryPolicy retryPolicy;

    @Inject
    PaymentGatewayClient paymentGateway;

    /**
     * Forward half. Returns a {@link #PARKED} view once the payment request is in
     * flight; returns a terminal view only when the saga could not get as far as
     * parking (a forward step exhausting its §5 retry budget before the pivot).
     */
    public OrderAcceptedView handle(CreateOrderCommand command) {
        // insert-order precedes any compensatable state: retry-budget exhaustion here has
        // nothing to recover backward from, so it propagates as an infrastructure failure.
        long dbOrderId = retryPolicy.get("insert-order",
                () -> stepService.insertOrder(command.userId(), command.cartId(), command.sagaId()));

        try {
            retryPolicy.run("reserve-inventory", () -> stepService.reserveInventory(dbOrderId));
        } catch (OrderSagaRetryPolicy.RetryExhaustedException reserveExhausted) {
            // CONTRACT-v2 §5: forward-step retry-budget exhaustion routes to backward
            // recovery. Nothing was reserved and no payment was requested.
            return compensate(command.orderId(), command.sagaId(), dbOrderId, false, false);
        }

        try {
            retryPolicy.run("request-payment", () -> stepService.requestPayment(dbOrderId));
        } catch (OrderSagaRetryPolicy.RetryExhaustedException paymentWriteExhausted) {
            // The payment-requested writes never committed, so there is no authorisation
            // to refund — only the reservation to restore.
            return compensate(command.orderId(), command.sagaId(), dbOrderId, false, true);
        }

        // PARK. Dispatch is deliberately AFTER the writes above: settle() compare-and-sets
        // on the PAYMENT_PROCESSING status this step wrote, so a callback racing ahead of
        // it would find no parked row. At ~1 ms of gateway delay that race is real.
        paymentGateway.dispatch(command.orderId(), command.sagaId());
        return new OrderAcceptedView(command.orderId(), PARKED, command.sagaId());
    }

    /**
     * Continuation half, driven by the gateway callback. The saga resumes from the
     * {@code orders} row, not from memory.
     *
     * @param authorized the gateway's §4.1 verdict for this order
     * @return the terminal outcome (COMPLETED | COMPENSATED | FAILED_UNRECOVERED)
     */
    public String settle(String orderId, String sagaId, long dbOrderId, boolean authorized) {
        if (!authorized) {
            // CONTRACT-v2 §4.1: business-terminal decline — straight to backward recovery
            // with zero retries (§5). The payment-requested writes committed before the
            // park, so the refund compensation applies exactly as it did inline.
            return compensate(orderId, sagaId, dbOrderId, true, true).status();
        }
        try {
            retryPolicy.run("confirm-order", () -> stepService.confirmOrder(dbOrderId));
            retryPolicy.run("complete-order", () -> stepService.completeOrder(dbOrderId));
        } catch (OrderSagaRetryPolicy.RetryExhaustedException forwardExhausted) {
            return compensate(orderId, sagaId, dbOrderId, true, true).status();
        }
        return "COMPLETED";
    }

    /**
     * Backward recovery (CONTRACT-v2 §4.1/§5): compensations of the completed forward steps
     * run in LIFO order — payment before inventory. Every path settles the order row at a
     * terminal status so the polled projection converges with the synchronous outcome:
     * CANCELLED on successful compensation (written by compensate-reservation, or by
     * cancel-order when no reservation exists to restore), FAILED when a compensation step
     * exhausts its retry budget (FAILED_UNRECOVERED, counted separately by oracle O3).
     */
    private OrderAcceptedView compensate(String orderId, String sagaId, long dbOrderId,
                                         boolean refundPayment, boolean restoreInventory) {
        try {
            if (refundPayment) {
                retryPolicy.run("compensate-payment", () -> stepService.compensatePayment(dbOrderId));
            }
            if (restoreInventory) {
                retryPolicy.run("compensate-reservation", () -> stepService.compensateReservation(dbOrderId));
            } else {
                // Nothing to restore, but the order row must still reach the CANCELLED
                // terminal status — otherwise it rests at SAGA_INITIATED and the polled
                // projection never terminates (oracle G3 drain scan).
                retryPolicy.run("cancel-order", () -> stepService.cancelOrder(dbOrderId));
            }
        } catch (OrderSagaRetryPolicy.RetryExhaustedException compensationExhausted) {
            stepService.markOrderFailed(dbOrderId);
            return new OrderAcceptedView(orderId, "FAILED_UNRECOVERED", sagaId);
        }
        return new OrderAcceptedView(orderId, "COMPENSATED", sagaId);
    }
}
