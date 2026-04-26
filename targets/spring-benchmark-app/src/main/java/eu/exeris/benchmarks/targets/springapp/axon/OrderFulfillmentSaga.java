package eu.exeris.benchmarks.targets.springapp.application.axon;

import eu.exeris.benchmarks.targets.springapp.application.axon.command.CompleteOrderCommand;
import eu.exeris.benchmarks.targets.springapp.application.axon.command.CompensatePaymentCommand;
import eu.exeris.benchmarks.targets.springapp.application.axon.command.CompensateReservationCommand;
import eu.exeris.benchmarks.targets.springapp.application.axon.command.ConfirmOrderCommand;
import eu.exeris.benchmarks.targets.springapp.application.axon.command.ProcessPaymentCommand;
import eu.exeris.benchmarks.targets.springapp.application.axon.command.ReserveInventoryCommand;
import eu.exeris.benchmarks.targets.springapp.application.axon.event.InventoryReservedEvent;
import eu.exeris.benchmarks.targets.springapp.application.axon.event.OrderConfirmedEvent;
import eu.exeris.benchmarks.targets.springapp.application.axon.event.OrderSagaCompensatedEvent;
import eu.exeris.benchmarks.targets.springapp.application.axon.event.OrderSagaCompletedEvent;
import eu.exeris.benchmarks.targets.springapp.application.axon.event.OrderSagaInitiatedEvent;
import eu.exeris.benchmarks.targets.springapp.application.axon.event.PaymentCompensatedEvent;
import eu.exeris.benchmarks.targets.springapp.application.axon.event.PaymentFailedEvent;
import eu.exeris.benchmarks.targets.springapp.application.axon.event.PaymentProcessedEvent;
import eu.exeris.benchmarks.targets.springapp.application.axon.event.ReservationCompensatedEvent;

import org.axonframework.commandhandling.gateway.CommandGateway;
import org.axonframework.eventhandling.EventBus;
import org.axonframework.eventhandling.GenericEventMessage;
import org.axonframework.modelling.saga.EndSaga;
import org.axonframework.modelling.saga.SagaEventHandler;
import org.axonframework.modelling.saga.StartSaga;
import org.axonframework.spring.stereotype.Saga;
import org.springframework.beans.factory.annotation.Autowired;

@Saga
public class OrderFulfillmentSaga {

    @Autowired
    private transient CommandGateway commandGateway;

    @Autowired
    private transient OrderCreationService orderCreationService;

    @Autowired
    private transient EventBus eventBus;

    private String orderId;
    private String sagaId;
    private String userId;
    private String cartId;
    private String paymentMethod;
    private long dbOrderId;

    @StartSaga
    @SagaEventHandler(associationProperty = "sagaId")
    public void on(OrderSagaInitiatedEvent event) {
        this.orderId = event.orderId();
        this.sagaId = event.sagaId();
        this.userId = event.userId();
        this.cartId = event.cartId();
        this.paymentMethod = event.paymentMethod();
        this.dbOrderId = orderCreationService.insertOrder(userId, cartId, sagaId);
        commandGateway.sendAndWait(
                new ReserveInventoryCommand(sagaId, orderId, userId, dbOrderId));
    }

    @SagaEventHandler(associationProperty = "sagaId")
    public void on(InventoryReservedEvent event) {
        commandGateway.sendAndWait(
                new ProcessPaymentCommand(sagaId, orderId, userId, dbOrderId, paymentMethod));
    }

    @SagaEventHandler(associationProperty = "sagaId")
    public void on(PaymentProcessedEvent event) {
        commandGateway.sendAndWait(
                new ConfirmOrderCommand(sagaId, orderId, userId, dbOrderId));
    }

    @SagaEventHandler(associationProperty = "sagaId")
    public void on(PaymentFailedEvent event) {
        commandGateway.sendAndWait(
                new CompensatePaymentCommand(sagaId, orderId, userId, dbOrderId));
    }

    @SagaEventHandler(associationProperty = "sagaId")
    public void on(PaymentCompensatedEvent event) {
        commandGateway.sendAndWait(
                new CompensateReservationCommand(sagaId, orderId, userId, dbOrderId));
    }

    @SagaEventHandler(associationProperty = "sagaId")
    public void on(ReservationCompensatedEvent event) {
        eventBus.publish(GenericEventMessage.asEventMessage(
                new OrderSagaCompensatedEvent(orderId, userId, cartId, sagaId)));
    }

    @SagaEventHandler(associationProperty = "sagaId")
    public void on(OrderConfirmedEvent event) {
        commandGateway.sendAndWait(
                new CompleteOrderCommand(sagaId, orderId, userId, dbOrderId));
    }

    @EndSaga
    @SagaEventHandler(associationProperty = "sagaId")
    public void on(OrderSagaCompletedEvent event) {
        // saga lifecycle ends
    }

    @EndSaga
    @SagaEventHandler(associationProperty = "sagaId")
    public void on(OrderSagaCompensatedEvent event) {
        // saga lifecycle ends
    }
}
