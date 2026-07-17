package eu.exeris.benchmarks.targets.quarkusapp.axon;

import eu.exeris.benchmarks.targets.quarkusapp.axon.command.CreateOrderCommand;
import eu.exeris.benchmarks.targets.quarkusapp.axon.event.OrderSagaCompensatedEvent;
import eu.exeris.benchmarks.targets.quarkusapp.axon.event.OrderSagaCompletedEvent;
import eu.exeris.benchmarks.targets.quarkusapp.axon.event.OrderSagaInitiatedEvent;
import eu.exeris.benchmarks.targets.quarkusapp.axon.event.PaymentDeclinedEvent;
import eu.exeris.benchmarks.targets.quarkusapp.dto.OrderAcceptedView;

import jakarta.enterprise.context.ApplicationScoped;
import jakarta.inject.Inject;

import org.axonframework.eventhandling.EventBus;
import org.axonframework.eventhandling.GenericEventMessage;

@ApplicationScoped
public class AxonOrderSagaCommandHandler {

    @Inject
    EventBus eventBus;

    @Inject
    OrderSagaStepService stepService;

    @Inject
    OrderSagaRetryPolicy retryPolicy;

    public OrderAcceptedView handle(CreateOrderCommand command) {
        // insert-order precedes any compensatable state: retry-budget exhaustion here has
        // nothing to recover backward from, so it propagates as an infrastructure failure.
        long dbOrderId = retryPolicy.get("insert-order",
                () -> stepService.insertOrder(command.userId(), command.cartId(), command.sagaId()));
        eventBus.publish(GenericEventMessage.asEventMessage(
                new OrderSagaInitiatedEvent(command.orderId(), command.sagaId(), command.userId())));

        boolean inventoryReserved = false;
        boolean paymentRequested = false;
        try {
            retryPolicy.run("reserve-inventory", () -> stepService.reserveInventory(dbOrderId));
            inventoryReserved = true;

            boolean paymentAuthorized = retryPolicy.get("process-payment",
                    () -> stepService.processPayment(dbOrderId, command.orderId(), command.paymentMethod()));
            paymentRequested = true;

            if (!paymentAuthorized) {
                // CONTRACT-v2 §4.1: business-terminal decline — explicitly modeled as an event
                // and routed to saga compensation with zero retries (§5); never re-attempted.
                eventBus.publish(GenericEventMessage.asEventMessage(
                        new PaymentDeclinedEvent(command.orderId(), command.sagaId(), command.userId())));
                return compensate(command, dbOrderId, true, true);
            }

            retryPolicy.run("confirm-order", () -> stepService.confirmOrder(dbOrderId));
            retryPolicy.run("complete-order", () -> stepService.completeOrder(dbOrderId));
        } catch (OrderSagaRetryPolicy.RetryExhaustedException forwardExhausted) {
            // CONTRACT-v2 §5: forward-step retry-budget exhaustion routes to backward recovery.
            return compensate(command, dbOrderId, paymentRequested, inventoryReserved);
        }

        eventBus.publish(GenericEventMessage.asEventMessage(
                new OrderSagaCompletedEvent(command.orderId(), command.sagaId(), command.userId())));
        return new OrderAcceptedView(command.orderId(), "COMPLETED", command.sagaId());
    }

    /**
     * Backward recovery (CONTRACT-v2 §4.1/§5): compensations of the completed forward steps
     * run in LIFO order — payment before inventory. Compensation-step retry-budget exhaustion
     * routes to FAILED_UNRECOVERED (§5), counted separately by oracle O3.
     */
    private OrderAcceptedView compensate(CreateOrderCommand command, long dbOrderId,
                                         boolean refundPayment, boolean restoreInventory) {
        try {
            if (refundPayment) {
                retryPolicy.run("compensate-payment", () -> stepService.compensatePayment(dbOrderId));
            }
            if (restoreInventory) {
                retryPolicy.run("compensate-reservation", () -> stepService.compensateReservation(dbOrderId));
            }
        } catch (OrderSagaRetryPolicy.RetryExhaustedException compensationExhausted) {
            return new OrderAcceptedView(command.orderId(), "FAILED_UNRECOVERED", command.sagaId());
        }
        eventBus.publish(GenericEventMessage.asEventMessage(
                new OrderSagaCompensatedEvent(command.orderId(), command.sagaId(), command.userId())));
        return new OrderAcceptedView(command.orderId(), "COMPENSATED", command.sagaId());
    }
}
