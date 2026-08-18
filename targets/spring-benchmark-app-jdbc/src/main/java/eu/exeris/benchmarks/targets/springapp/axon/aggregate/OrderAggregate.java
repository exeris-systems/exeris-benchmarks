package eu.exeris.benchmarks.targets.springapp.application.axon.aggregate;

import eu.exeris.benchmarks.targets.springapp.application.axon.command.CreateOrderCommand;
import eu.exeris.benchmarks.targets.springapp.application.axon.event.OrderSagaInitiatedEvent;

import org.axonframework.commandhandling.CommandHandler;
import org.axonframework.eventsourcing.EventSourcingHandler;
import org.axonframework.modelling.command.AggregateIdentifier;
import org.axonframework.modelling.command.AggregateLifecycle;
import org.axonframework.spring.stereotype.Aggregate;

/**
 * Order aggregate — the command model for the order saga.
 *
 * Synchronous saga: both events (initiated + completed) are applied in a single
 * command handler because there are no external systems or async steps. This
 * mirrors the Exeris Community FlowEngine which executes all saga steps inline.
 *
 * AggregateLifecycle.apply() publishes each event to the EventBus (EmbeddedEventStore
 * backed by JdbcEventStorageEngine), which stores it in domain_event_entry AND dispatches
 * it to subscribing @EventHandler methods in AxonOrderSagaProjection in the same thread.
 */
@Aggregate
public class OrderAggregate {

    @AggregateIdentifier
    private String orderId;
    private String status;

    /**
     * Required by Axon for event-sourcing reconstruction from the event store.
     * Axon uses reflection to call this before replaying EventSourcingHandler methods.
     */
    protected OrderAggregate() {
    }

    @CommandHandler
    public OrderAggregate(CreateOrderCommand command) {
        AggregateLifecycle.apply(new OrderSagaInitiatedEvent(
                command.orderId(),
                command.userId(),
                command.cartId(),
                command.sagaId(),
                command.paymentMethod()
        ));
    }

    @EventSourcingHandler
    public void on(OrderSagaInitiatedEvent event) {
        this.orderId = event.orderId();
        this.status = "SAGA_INITIATED";
    }
}
