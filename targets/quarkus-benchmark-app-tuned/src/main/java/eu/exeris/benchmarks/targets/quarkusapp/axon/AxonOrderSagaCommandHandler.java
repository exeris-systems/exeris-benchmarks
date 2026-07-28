package eu.exeris.benchmarks.targets.quarkusapp.axon;

import eu.exeris.benchmarks.targets.quarkusapp.axon.command.CreateOrderCommand;
import eu.exeris.benchmarks.targets.quarkusapp.dto.OrderAcceptedView;

import jakarta.enterprise.context.ApplicationScoped;
import jakarta.inject.Inject;

/**
 * Imperative saga orchestration, command-dispatch only: the single CreateOrderCommand
 * round-trip through Axon Server carries the whole saga; forward steps and backward
 * recovery are invoked in-line. There is deliberately NO event-driven wiring here —
 * an earlier revision published lifecycle events to a subscriber-less SimpleEventBus,
 * which silently dropped them while looking load-bearing. Compensation correctness
 * rests on the direct calls below, and nothing else.
 */
@ApplicationScoped
public class AxonOrderSagaCommandHandler {

    @Inject
    OrderSagaStepService stepService;

    @Inject
    OrderSagaRetryPolicy retryPolicy;

    public OrderAcceptedView handle(CreateOrderCommand command) {
        // insert-order precedes any compensatable state: retry-budget exhaustion here has
        // nothing to recover backward from, so it propagates as an infrastructure failure.
        long dbOrderId = retryPolicy.get("insert-order",
                () -> stepService.insertOrder(command.userId(), command.cartId(), command.sagaId()));

        boolean inventoryReserved = false;
        boolean paymentRequested = false;
        try {
            retryPolicy.run("reserve-inventory", () -> stepService.reserveInventory(dbOrderId));
            inventoryReserved = true;

            boolean paymentAuthorized = retryPolicy.get("process-payment",
                    () -> stepService.processPayment(dbOrderId, command.orderId(), command.paymentMethod()));
            paymentRequested = true;

            if (!paymentAuthorized) {
                // CONTRACT-v2 §4.1: business-terminal decline — routed directly to backward
                // recovery with zero retries (§5); never re-attempted.
                return compensate(command, dbOrderId, true, true);
            }

            retryPolicy.run("confirm-order", () -> stepService.confirmOrder(dbOrderId));
            retryPolicy.run("complete-order", () -> stepService.completeOrder(dbOrderId));
        } catch (OrderSagaRetryPolicy.RetryExhaustedException forwardExhausted) {
            // CONTRACT-v2 §5: forward-step retry-budget exhaustion routes to backward recovery.
            return compensate(command, dbOrderId, paymentRequested, inventoryReserved);
        }

        return new OrderAcceptedView(command.orderId(), "COMPLETED", command.sagaId());
    }

    /**
     * Backward recovery (CONTRACT-v2 §4.1/§5): compensations of the completed forward steps
     * run in LIFO order — payment before inventory. Every path settles the order row at a
     * terminal status so the polled projection converges with the synchronous outcome:
     * CANCELLED on successful compensation (written by compensate-reservation, or by
     * cancel-order when no reservation exists to restore), FAILED when a compensation step
     * exhausts its retry budget (FAILED_UNRECOVERED, counted separately by oracle O3).
     */
    private OrderAcceptedView compensate(CreateOrderCommand command, long dbOrderId,
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
            return new OrderAcceptedView(command.orderId(), "FAILED_UNRECOVERED", command.sagaId());
        }
        return new OrderAcceptedView(command.orderId(), "COMPENSATED", command.sagaId());
    }
}
