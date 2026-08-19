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
import eu.exeris.benchmarks.targets.springapp.application.axon.event.OrderSagaFailedUnrecoveredEvent;
import eu.exeris.benchmarks.targets.springapp.application.axon.event.OrderSagaInitiatedEvent;
import eu.exeris.benchmarks.targets.springapp.application.axon.event.PaymentCompensatedEvent;
import eu.exeris.benchmarks.targets.springapp.application.axon.event.PaymentDeclinedEvent;
import eu.exeris.benchmarks.targets.springapp.application.axon.event.PaymentProcessedEvent;
import eu.exeris.benchmarks.targets.springapp.application.axon.event.ReservationCompensatedEvent;

import com.fasterxml.jackson.annotation.JsonAutoDetect;
import com.fasterxml.jackson.annotation.JsonIgnore;
import com.fasterxml.jackson.annotation.JsonIgnoreProperties;

import org.axonframework.commandhandling.gateway.CommandGateway;
import org.axonframework.eventhandling.EventBus;
import org.axonframework.eventhandling.GenericEventMessage;
import org.axonframework.modelling.saga.EndSaga;
import org.axonframework.modelling.saga.SagaEventHandler;
import org.axonframework.modelling.saga.StartSaga;
import org.axonframework.spring.stereotype.Saga;
import org.springframework.beans.factory.annotation.Autowired;

/**
 * <h2>Why this saga carries Jackson annotations</h2>
 *
 * A durable saga store round-trips this object through the configured serializer, and
 * {@code axon.serializer.general=jackson} makes that Jackson. Jackson auto-detects PUBLIC
 * accessors, and a saga has none - so without the annotations below every field is dropped
 * and the store writes the empty document. Measured directly on the embedded arm:
 *
 * <pre>
 *   JdbcSagaStore : Storing saga id 9094f2f2-... as {}
 *   JdbcSagaStore : Loaded  saga id [9094f2f2-...] of type [OrderFulfillmentSaga]
 *   JdbcSagaStore : Updating saga id 9094f2f2-... as {}
 * </pre>
 *
 * The saga was found and its handler DID run - on an instance whose {@code sagaId} was null
 * and whose {@code dbOrderId} was 0. The payment it dispatched was therefore unroutable, the
 * gateway callback matched no parked order row, and every session stranded at
 * {@code INVENTORY_RESERVED} with no exception and no WARN anywhere in the log.
 *
 * <p>The Axon Server arm never showed this because it runs on an IN-MEMORY saga store
 * (its log carries {@code WARN InMemoryTokenStore: An in memory token store is being
 * created}), where the saga is a live Java object that is never serialized. The defect was
 * invisible until a store that actually persists saga state was introduced.
 *
 * <p>Field visibility rather than a different serializer: Axon's own advice is to serialize
 * sagas with XStream, but that would put the two Axon arms on different serializers and add
 * a second variable to a comparison whose point is where the saga state lives. The injected
 * collaborators are {@code transient} AND {@code @JsonIgnore} because Jackson does not honour
 * the transient marker unless {@code MapperFeature.PROPAGATE_TRANSIENT_MARKER} is enabled,
 * which it is not by default - the marker alone would have Jackson try to serialize a
 * {@code CommandGateway}.
 */
@Saga
@JsonAutoDetect(
        fieldVisibility = JsonAutoDetect.Visibility.ANY,
        getterVisibility = JsonAutoDetect.Visibility.NONE,
        isGetterVisibility = JsonAutoDetect.Visibility.NONE,
        setterVisibility = JsonAutoDetect.Visibility.NONE,
        creatorVisibility = JsonAutoDetect.Visibility.NONE)
@JsonIgnoreProperties(ignoreUnknown = true)
public class OrderFulfillmentSaga {

    @Autowired
    @JsonIgnore
    private transient CommandGateway commandGateway;

    @Autowired
    @JsonIgnore
    private transient OrderCreationService orderCreationService;

    @Autowired
    @JsonIgnore
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

    /**
     * CONTRACT-v2 §4.1: payment declined — a BUSINESS-TERMINAL outcome. Routed to
     * backward recovery (LIFO compensation: payment refund, then reservation
     * restore), never retried. §5: if a compensation step exhausts the command
     * gateway's transient retry budget, the saga terminates FAILED_UNRECOVERED
     * instead of being silently swallowed by the saga error handler.
     */
    @SagaEventHandler(associationProperty = "sagaId")
    public void on(PaymentDeclinedEvent event) {
        try {
            commandGateway.sendAndWait(
                    new CompensatePaymentCommand(sagaId, orderId, userId, dbOrderId));
        } catch (Exception e) {
            failUnrecovered();
        }
    }

    @SagaEventHandler(associationProperty = "sagaId")
    public void on(PaymentCompensatedEvent event) {
        try {
            commandGateway.sendAndWait(
                    new CompensateReservationCommand(sagaId, orderId, userId, dbOrderId));
        } catch (Exception e) {
            failUnrecovered();
        }
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

    @EndSaga
    @SagaEventHandler(associationProperty = "sagaId")
    public void on(OrderSagaFailedUnrecoveredEvent event) {
        // saga lifecycle ends — compensation retry budget exhausted (CONTRACT-v2 §5)
    }

    private void failUnrecovered() {
        eventBus.publish(GenericEventMessage.asEventMessage(
                new OrderSagaFailedUnrecoveredEvent(orderId, userId, cartId, sagaId)));
    }
}
