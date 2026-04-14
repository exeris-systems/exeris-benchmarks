package eu.exeris.benchmarks.targets.springapp.application.axon;

import eu.exeris.benchmarks.targets.springapp.api.OrderStatusView;
import eu.exeris.benchmarks.targets.springapp.application.axon.event.InventoryReservedEvent;
import eu.exeris.benchmarks.targets.springapp.application.axon.event.OrderConfirmedEvent;
import eu.exeris.benchmarks.targets.springapp.application.axon.event.OrderSagaCompensatedEvent;
import eu.exeris.benchmarks.targets.springapp.application.axon.event.OrderSagaCompletedEvent;
import eu.exeris.benchmarks.targets.springapp.application.axon.event.OrderSagaInitiatedEvent;
import eu.exeris.benchmarks.targets.springapp.application.axon.event.PaymentCompensatedEvent;
import eu.exeris.benchmarks.targets.springapp.application.axon.event.PaymentFailedEvent;
import eu.exeris.benchmarks.targets.springapp.application.axon.event.PaymentProcessedEvent;
import eu.exeris.benchmarks.targets.springapp.application.axon.event.ReservationCompensatedEvent;

import org.axonframework.eventhandling.EventHandler;
import org.springframework.stereotype.Component;

import java.util.Optional;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.ConcurrentMap;

@Component
public class AxonOrderSagaProjection {

    private final ConcurrentMap<String, OrderStatusEntry> orderById = new ConcurrentHashMap<>();

    @EventHandler
    public void on(OrderSagaInitiatedEvent event) {
        orderById.put(event.orderId(), new OrderStatusEntry(event.userId(), "SAGA_INITIATED", event.sagaId()));
    }

    @EventHandler
    public void on(InventoryReservedEvent event) {
        orderById.put(event.orderId(), new OrderStatusEntry(event.userId(), "INVENTORY_RESERVED", event.sagaId()));
    }

    @EventHandler
    public void on(PaymentProcessedEvent event) {
        orderById.put(event.orderId(), new OrderStatusEntry(event.userId(), "PAYMENT_PROCESSING", event.sagaId()));
    }

    @EventHandler
    public void on(PaymentFailedEvent event) {
        orderById.put(event.orderId(), new OrderStatusEntry(event.userId(), "PAYMENT_PROCESSING", event.sagaId()));
    }

    @EventHandler
    public void on(PaymentCompensatedEvent event) {
        orderById.put(event.orderId(), new OrderStatusEntry(event.userId(), "PAYMENT_REFUNDED", event.sagaId()));
    }

    @EventHandler
    public void on(ReservationCompensatedEvent event) {
        orderById.put(event.orderId(), new OrderStatusEntry(event.userId(), "CANCELLED", event.sagaId()));
    }

    @EventHandler
    public void on(OrderConfirmedEvent event) {
        orderById.put(event.orderId(), new OrderStatusEntry(event.userId(), "CONFIRMED", event.sagaId()));
    }

    @EventHandler
    public void on(OrderSagaCompletedEvent event) {
        orderById.put(event.orderId(), new OrderStatusEntry(event.userId(), "COMPLETED", event.sagaId()));
    }

    @EventHandler
    public void on(OrderSagaCompensatedEvent event) {
        orderById.put(event.orderId(), new OrderStatusEntry(event.userId(), "CANCELLED", event.sagaId()));
    }

    public Optional<OrderStatusView> findForUser(String userId, String orderId) {
        OrderStatusEntry state = orderById.get(orderId);
        if (state == null || !state.userId().equals(userId)) {
            return Optional.empty();
        }
        return Optional.of(new OrderStatusView(orderId, state.status(), state.sagaId()));
    }

    private record OrderStatusEntry(String userId, String status, String sagaId) {}
}