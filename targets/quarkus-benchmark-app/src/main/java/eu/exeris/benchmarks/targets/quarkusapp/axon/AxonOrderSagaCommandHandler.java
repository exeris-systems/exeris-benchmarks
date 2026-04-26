package eu.exeris.benchmarks.targets.quarkusapp.axon;

import eu.exeris.benchmarks.targets.quarkusapp.axon.command.CreateOrderCommand;
import eu.exeris.benchmarks.targets.quarkusapp.axon.event.OrderSagaCompensatedEvent;
import eu.exeris.benchmarks.targets.quarkusapp.axon.event.OrderSagaCompletedEvent;
import eu.exeris.benchmarks.targets.quarkusapp.axon.event.OrderSagaInitiatedEvent;
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

    public OrderAcceptedView handle(CreateOrderCommand command) {
        long dbOrderId = stepService.insertOrder(command.userId(), command.cartId(), command.sagaId());
        eventBus.publish(GenericEventMessage.asEventMessage(
                new OrderSagaInitiatedEvent(command.orderId(), command.sagaId(), command.userId())));

        stepService.reserveInventory(dbOrderId);
        boolean paymentOk = stepService.processPayment(dbOrderId, command.paymentMethod());

        if (!paymentOk) {
            stepService.compensatePayment(dbOrderId);
            stepService.compensateReservation(dbOrderId);
            eventBus.publish(GenericEventMessage.asEventMessage(
                    new OrderSagaCompensatedEvent(command.orderId(), command.sagaId(), command.userId())));
            return new OrderAcceptedView(command.orderId(), "COMPENSATING", command.sagaId());
        }

        stepService.confirmOrder(dbOrderId);
        stepService.completeOrder(dbOrderId);
        eventBus.publish(GenericEventMessage.asEventMessage(
                new OrderSagaCompletedEvent(command.orderId(), command.sagaId(), command.userId())));
        return new OrderAcceptedView(command.orderId(), "SAGA_INITIATED", command.sagaId());
    }
}
