package eu.exeris.benchmarks.targets.springapp.application.axon;

import eu.exeris.benchmarks.targets.springapp.api.OrderAcceptedView;
import eu.exeris.benchmarks.targets.springapp.api.OrderStatusView;
import eu.exeris.benchmarks.targets.springapp.application.ShopSagaStateService;
import eu.exeris.benchmarks.targets.springapp.application.axon.command.CreateOrderCommand;

import org.axonframework.commandhandling.gateway.CommandGateway;
import org.springframework.stereotype.Service;

import java.util.Optional;
import java.util.UUID;

/**
 * Dispatches CreateOrderCommand via CommandGateway → Axon Server → OrderAggregate.
 *
 * Production simulation mode: axon.axonserver.enabled=true.
 * sendAndWait() blocks until OrderAggregate @CommandHandler completes and Axon Server
 * has persisted the events. SubscribingEventProcessor delivers events to
 * AxonOrderSagaProjection @EventHandlers synchronously in the same thread.
 */
@Service
public class AxonOrderSagaService {

    private final CommandGateway commandGateway;
    private final AxonOrderSagaProjection projection;

    public AxonOrderSagaService(CommandGateway commandGateway, AxonOrderSagaProjection projection) {
        this.commandGateway = commandGateway;
        this.projection = projection;
    }

    public Optional<OrderAcceptedView> createOrder(
            String userId,
            String cartId,
            String paymentMethod,
            String requestedOrderId,
            ShopSagaStateService cartState
    ) {
        if (!cartState.hasCartForUser(userId, cartId)) {
            return Optional.empty();
        }

        // CONTRACT-v2 §3: prefer the client-generated orderId (deterministic seeded
        // population, prerequisite for the §4.1 exact decline oracle); fall back to a
        // server-generated UUID when the harness does not supply one.
        String orderId = (requestedOrderId == null || requestedOrderId.isBlank())
                ? UUID.randomUUID().toString()
                : requestedOrderId.trim();
        String sagaId = "saga-" + UUID.randomUUID();

        commandGateway.sendAndWait(
                new CreateOrderCommand(orderId, userId, cartId, paymentMethod, sagaId));

        return Optional.of(new OrderAcceptedView(orderId, "ACCEPTED", sagaId));
    }

    public Optional<OrderStatusView> orderStatus(String userId, String orderId) {
        return projection.findForUser(userId, orderId);
    }
}