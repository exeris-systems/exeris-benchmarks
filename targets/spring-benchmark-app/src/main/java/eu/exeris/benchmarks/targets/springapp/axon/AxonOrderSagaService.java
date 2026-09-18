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

    /**
     * CONTRACT-v2 §3 request-response budget. Matched to the client's own resolution
     * budget (k6 polls 25 × 1 s) so this stack never gives up before the client would.
     */
    private static final long SAGA_TERMINAL_AWAIT_TIMEOUT_MILLIS =
            Long.getLong("exeris.benchmark.saga.terminalAwaitTimeoutMillis",
                    parseEnvLong("EXERIS_SAGA_TERMINAL_AWAIT_TIMEOUT_MILLIS", 25_000L));

    private static long parseEnvLong(String name, long fallback) {
        String raw = System.getenv(name);
        if (raw == null || raw.isBlank()) {
            return fallback;
        }
        try {
            return Long.parseLong(raw.trim());
        } catch (NumberFormatException invalid) {
            return fallback;
        }
    }

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

        // CONTRACT-v2 §3: register BEFORE dispatch — the saga can settle while
        // sendAndWait is still returning, and a late registration would miss the signal.
        projection.expectTerminalOutcome(orderId);

        commandGateway.sendAndWait(
                new CreateOrderCommand(orderId, userId, cartId, paymentMethod, sagaId));

        // sendAndWait returns once the OrderAggregate has handled CreateOrderCommand; the
        // saga itself continues asynchronously. CONTRACT-v2 §3 requires the HTTP response
        // to carry the FINAL outcome, so wait for the projection to observe a terminal
        // status. Idiom deviation, registered under §9(a). Falls back to the pre-v2 async
        // "ACCEPTED" on timeout so a slow saga degrades to client polling rather than
        // failing the request.
        String status = projection
                .awaitTerminalOutcome(orderId, SAGA_TERMINAL_AWAIT_TIMEOUT_MILLIS)
                .orElse("ACCEPTED");

        return Optional.of(new OrderAcceptedView(orderId, status, sagaId));
    }

    public Optional<OrderStatusView> orderStatus(String userId, String orderId) {
        return projection.findForUser(userId, orderId);
    }
}