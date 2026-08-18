package eu.exeris.benchmarks.targets.springapp.application.axon;

import eu.exeris.benchmarks.targets.springapp.api.OrderStatusView;
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

import org.axonframework.eventhandling.EventHandler;
import org.springframework.stereotype.Component;

import java.util.Optional;
import java.util.Set;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.ConcurrentMap;

/**
 * In-memory status projection backing GET /api/v1/orders/{orderId}/status.
 *
 * Terminal statuses follow the CONTRACT-v2 §3 final-outcome vocabulary:
 * COMPLETED | COMPENSATED | FAILED_UNRECOVERED. v1 surfaced CANCELLED for
 * compensated sagas, which the k6 poller does not recognize as terminal —
 * compensations fired but were scored unresolved (the v1 "zero compensations"
 * asymmetry). Terminal states are sticky: once a saga reaches a terminal
 * status, later (out-of-order) intermediate events cannot overwrite it.
 */
@Component
public class AxonOrderSagaProjection {

    private static final Set<String> TERMINAL_STATUSES =
            Set.of("COMPLETED", "COMPENSATED", "FAILED_UNRECOVERED");

    private final ConcurrentMap<String, OrderStatusEntry> orderById = new ConcurrentHashMap<>();

    @EventHandler
    public void on(OrderSagaInitiatedEvent event) {
        put(event.orderId(), new OrderStatusEntry(event.userId(), "SAGA_INITIATED", event.sagaId()));
    }

    @EventHandler
    public void on(InventoryReservedEvent event) {
        put(event.orderId(), new OrderStatusEntry(event.userId(), "INVENTORY_RESERVED", event.sagaId()));
    }

    @EventHandler
    public void on(PaymentProcessedEvent event) {
        put(event.orderId(), new OrderStatusEntry(event.userId(), "PAYMENT_PROCESSING", event.sagaId()));
    }

    @EventHandler
    public void on(PaymentDeclinedEvent event) {
        // Business-terminal decline (CONTRACT-v2 §4.1): backward recovery starts.
        put(event.orderId(), new OrderStatusEntry(event.userId(), "COMPENSATING", event.sagaId()));
    }

    @EventHandler
    public void on(PaymentCompensatedEvent event) {
        put(event.orderId(), new OrderStatusEntry(event.userId(), "PAYMENT_REFUNDED", event.sagaId()));
    }

    @EventHandler
    public void on(ReservationCompensatedEvent event) {
        put(event.orderId(), new OrderStatusEntry(event.userId(), "CANCELLED", event.sagaId()));
    }

    @EventHandler
    public void on(OrderConfirmedEvent event) {
        put(event.orderId(), new OrderStatusEntry(event.userId(), "CONFIRMED", event.sagaId()));
    }

    @EventHandler
    public void on(OrderSagaCompletedEvent event) {
        put(event.orderId(), new OrderStatusEntry(event.userId(), "COMPLETED", event.sagaId()));
    }

    @EventHandler
    public void on(OrderSagaCompensatedEvent event) {
        put(event.orderId(), new OrderStatusEntry(event.userId(), "COMPENSATED", event.sagaId()));
    }

    @EventHandler
    public void on(OrderSagaFailedUnrecoveredEvent event) {
        put(event.orderId(), new OrderStatusEntry(event.userId(), "FAILED_UNRECOVERED", event.sagaId()));
    }

    public Optional<OrderStatusView> findForUser(String userId, String orderId) {
        OrderStatusEntry state = orderById.get(orderId);
        if (state == null || !state.userId().equals(userId)) {
            return Optional.empty();
        }
        return Optional.of(new OrderStatusView(orderId, state.status(), state.sagaId()));
    }

    private void put(String orderId, OrderStatusEntry entry) {
        orderById.merge(orderId, entry,
                (existing, incoming) -> TERMINAL_STATUSES.contains(existing.status()) ? existing : incoming);
    }

    private record OrderStatusEntry(String userId, String status, String sagaId) {}
}
