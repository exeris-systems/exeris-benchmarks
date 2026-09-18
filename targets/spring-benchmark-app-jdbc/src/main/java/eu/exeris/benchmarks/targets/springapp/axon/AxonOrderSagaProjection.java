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
import java.util.concurrent.CompletableFuture;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.ConcurrentMap;
import java.util.concurrent.ExecutionException;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.TimeoutException;

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
        OrderStatusEntry effective = orderById.merge(orderId, entry,
                (existing, incoming) -> TERMINAL_STATUSES.contains(existing.status()) ? existing : incoming);
        if (TERMINAL_STATUSES.contains(effective.status())) {
            signalTerminal(orderId, effective.status());
        }
    }

    // --- CONTRACT-v2 §3 request-response support -----------------------------
    //
    // Axon's saga is event-driven, so createOrder's sendAndWait() returns as soon as the
    // OrderAggregate has handled CreateOrderCommand — long before the saga settles. The
    // projection is the first component that observes a terminal status, so it is where
    // the waiting request thread is released.
    //
    // This is an idiom deviation, registered under CONTRACT-v2 §9(a): a production Axon
    // service would return 202 and let the client subscribe or poll. It is done here
    // because the alternative is worse for measurement — with polling, this stack's
    // measured saga duration was a flat ~1010 ms of client sleep quantization against
    // ~28 ms for the inline stacks, an artifact large enough to reverse the apparent
    // ordering between stacks.

    private final ConcurrentMap<String, CompletableFuture<String>> terminalOutcome =
            new ConcurrentHashMap<>();

    /**
     * Registers interest in {@code orderId}'s terminal outcome. MUST be called before the
     * command is dispatched, otherwise a saga that settles quickly completes before anyone
     * is waiting and the caller blocks until its timeout.
     */
    public void expectTerminalOutcome(String orderId) {
        terminalOutcome.putIfAbsent(orderId, new CompletableFuture<>());
    }

    /**
     * Blocks until the saga for {@code orderId} reaches a terminal status, or the timeout
     * elapses. Empty means "not settled in time" — the caller then falls back to the
     * pre-v2 async response and the client resolves by polling.
     */
    public Optional<String> awaitTerminalOutcome(String orderId, long timeoutMillis) {
        CompletableFuture<String> future = terminalOutcome.get(orderId);
        if (future == null) {
            return Optional.empty();
        }
        try {
            return Optional.ofNullable(future.get(timeoutMillis, TimeUnit.MILLISECONDS));
        } catch (TimeoutException timeout) {
            return Optional.empty();
        } catch (InterruptedException interrupted) {
            Thread.currentThread().interrupt();
            return Optional.empty();
        } catch (ExecutionException failure) {
            return Optional.empty();
        } finally {
            // Drop on timeout too, or an unsettled saga leaks its future for the
            // lifetime of the process.
            terminalOutcome.remove(orderId);
        }
    }

    private void signalTerminal(String orderId, String status) {
        CompletableFuture<String> future = terminalOutcome.get(orderId);
        if (future != null) {
            future.complete(status);
        }
    }

    private record OrderStatusEntry(String userId, String status, String sagaId) {}
}
