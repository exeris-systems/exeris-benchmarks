package eu.exeris.benchmarks.targets.restateapp.saga;

import java.util.Optional;
import java.util.Set;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.ConcurrentMap;

/**
 * In-memory status projection backing GET /api/v1/orders/{orderId}/status,
 * keyed by the client orderId. Mirrors the Axon stacks'
 * AxonOrderSagaProjection: sticky terminal states — once a saga reaches a
 * terminal status (CONTRACT-v2 §3 vocabulary: COMPLETED | COMPENSATED |
 * FAILED_UNRECOVERED), later (replayed or out-of-order) intermediate updates
 * cannot overwrite it. Replays of the Restate handler re-execute the
 * non-journaled projection puts, which this stickiness makes harmless.
 *
 * Fairness note (documented in the scenario contract): like the Axon stacks
 * this is an in-memory read path, not a DB read — status_poll_comparison_excluded.
 */
public final class OrderStatusProjection {

    private static final Set<String> TERMINAL_STATUSES =
            Set.of("COMPLETED", "COMPENSATED", "FAILED_UNRECOVERED");

    private final ConcurrentMap<String, OrderStatusEntry> orderById = new ConcurrentHashMap<>();

    public void put(String orderId, String userId, String status, String sagaId) {
        orderById.merge(orderId, new OrderStatusEntry(userId, status, sagaId),
                (existing, incoming) -> TERMINAL_STATUSES.contains(existing.status()) ? existing : incoming);
    }

    public Optional<OrderStatusEntry> findForUser(String userId, String orderId) {
        OrderStatusEntry state = orderById.get(orderId);
        if (state == null || !state.userId().equals(userId)) {
            return Optional.empty();
        }
        return Optional.of(state);
    }

    public record OrderStatusEntry(String userId, String status, String sagaId) {}
}
