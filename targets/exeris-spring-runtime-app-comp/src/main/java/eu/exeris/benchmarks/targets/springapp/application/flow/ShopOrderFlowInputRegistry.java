package eu.exeris.benchmarks.targets.springapp.application.flow;

import eu.exeris.benchmarks.targets.springapp.api.OrderAcceptedView;
import eu.exeris.kernel.spi.flow.model.FlowContext;

import org.springframework.stereotype.Component;

import java.util.Objects;
import java.util.Optional;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.ConcurrentMap;

/**
 * Process-local side channel that carries per-flow-instance input data and a
 * stable idempotency binding for {@code POST /api/v1/orders}.
 *
 * <h2>Why a side channel</h2>
 * <p>The kernel {@link FlowContext} SPI exposes only the instance UUID
 * (most/least 64-bit halves), the definition name, the current step index, the
 * lifecycle state, and the absolute deadline — see
 * {@code eu.exeris.kernel.spi.flow.model.FlowContext}. Step lambdas have no way
 * to read a heap-allocated payload from the context itself. The bench target's
 * saga needs {@code dbOrderId}, {@code orderId}, {@code userId}, {@code cartId},
 * {@code sagaId}, and {@code paymentMethod} on every step; a process-local
 * {@code ConcurrentMap} keyed by the instance id is the documented bridge.
 *
 * <h2>Idempotency map</h2>
 * <p>Maps an idempotency key ({@code userId + ':' + cartId}) to the
 * {@link OrderAcceptedView} originally returned. Retried POSTs after a flow has
 * already completed must still return the same accepted view; the per-instance
 * entry is dropped on terminal outcome by the flow's terminal step, so the
 * idempotency map is the only durable surface within a single JVM. This
 * survives only as long as the process; cross-restart idempotency relies on the
 * {@code orders.saga_id} column and {@code carts.status} (a completed cart
 * cannot re-enter the flow).
 *
 * <h2>Not persistent</h2>
 * <p>The kernel's snapshot store handles flow-state durability; this side
 * channel does <em>not</em>. After a JVM restart, in-flight flow instances that
 * resume from disk will fail to look up their input — by design, since the
 * benchmark scenario does not exercise cross-restart resumption. The
 * pre-migration Axon shape had the same single-JVM constraint via the
 * {@code AxonOrderSagaProjection} {@code ConcurrentMap}.
 */
@Component
public class ShopOrderFlowInputRegistry {

    /**
     * Per-flow-instance input payload. One entry is added in
     * {@link ShopOrderFlowService#createOrder} immediately before
     * {@code flowTemplate.schedule(...)} and removed by the flow's terminal step
     * (the {@code complete-order} success step or the {@code restore-inventory}
     * terminal compensation) via {@link #drop(InstanceKey)} once the flow reaches
     * {@code COMPLETED} or {@code CANCELLED}. This bounds {@link #byInstance} to
     * the set of in-flight instances. Note that {@link #idempotencyMap} and
     * {@link #statusByOrderId} are deliberately <em>not</em> dropped on terminal
     * outcome — post-completion idempotent retries and status reads must still
     * resolve, so they persist for the JVM lifetime (bounded by the distinct
     * orders in a run).
     */
    public record Input(
            String orderId,
            String sagaId,
            String userId,
            String cartId,
            String paymentMethod,
            long dbOrderId
    ) {
        public Input {
            Objects.requireNonNull(orderId, "orderId");
            Objects.requireNonNull(sagaId, "sagaId");
            Objects.requireNonNull(userId, "userId");
            Objects.requireNonNull(cartId, "cartId");
            Objects.requireNonNull(paymentMethod, "paymentMethod");
        }
    }

    /** Flyweight instance-id key — pair of {@code long}s matching the kernel context UUID halves. */
    public record InstanceKey(long instanceIdMost, long instanceIdLeast) {

        public static InstanceKey of(FlowContext ctx) {
            return new InstanceKey(ctx.instanceIdMost(), ctx.instanceIdLeast());
        }
    }

    /**
     * Per-API-order projection entry. The API exposes a UUID-string {@code orderId}
     * but the DB row uses a {@code bigint} id; the pre-migration Axon projection
     * kept the API-level status indexed by the UUID. We replicate the same
     * surface here, driven by step-lambda updates rather than EventBus handlers,
     * so {@code GET /api/v1/orders/{orderId}/status} can resolve the API-level
     * status without an extra DB round-trip per status read.
     */
    public record StatusEntry(String userId, String status, String sagaId) {
        public StatusEntry {
            Objects.requireNonNull(userId, "userId");
            Objects.requireNonNull(status, "status");
            Objects.requireNonNull(sagaId, "sagaId");
        }
    }

    private final ConcurrentMap<InstanceKey, Input> byInstance = new ConcurrentHashMap<>();
    private final ConcurrentMap<String, OrderAcceptedView> idempotencyMap = new ConcurrentHashMap<>();
    private final ConcurrentMap<String, StatusEntry> statusByOrderId = new ConcurrentHashMap<>();

    /**
     * Binds {@code input} to the supplied seed {@link FlowContext}. Throws if a
     * binding already exists for that instance — duplicate scheduling under the
     * same instance id is an application bug (matches the kernel's own
     * fail-loud posture for duplicates).
     */
    public void bind(FlowContext seedContext, Input input) {
        Objects.requireNonNull(seedContext, "seedContext");
        Objects.requireNonNull(input, "input");
        Input prev = byInstance.putIfAbsent(InstanceKey.of(seedContext), input);
        if (prev != null) {
            throw new IllegalStateException(
                    "ShopOrderFlowInputRegistry already has a binding for instance "
                            + Long.toHexString(seedContext.instanceIdMost())
                            + Long.toHexString(seedContext.instanceIdLeast())
                            + " — duplicate flow scheduling is a bug.");
        }
    }

    /**
     * Fetches the bound input for the given flow context. Used by step lambdas
     * on the kernel-owned virtual thread.
     *
     * @throws IllegalStateException if no binding exists (should never happen in
     *         the normal flow lifecycle)
     */
    public Input require(FlowContext ctx) {
        return require(InstanceKey.of(ctx));
    }

    /**
     * Overload by {@link InstanceKey}. Useful when the caller wants to keep the
     * key around for {@link #drop(InstanceKey)} without re-deriving it from the
     * context.
     */
    public Input require(InstanceKey key) {
        Input input = byInstance.get(key);
        if (input == null) {
            throw new IllegalStateException(
                    "No ShopOrderFlowInputRegistry binding for instance "
                            + Long.toHexString(key.instanceIdMost())
                            + Long.toHexString(key.instanceIdLeast()));
        }
        return input;
    }

    /**
     * Removes the per-instance binding once the flow has reached a terminal
     * state. Called from the flow's terminal step lambdas — the
     * {@code complete-order} success step and the {@code restore-inventory}
     * terminal compensation in {@code ShopOrderFlowDefinition} — after the last
     * {@link #require(FlowContext)} for that instance. Dropping here (rather than
     * on the controller status read, which only has the API-level {@code orderId}
     * and not the {@link InstanceKey}) keeps {@link #byInstance} bounded to
     * in-flight instances without an extra {@code orderId -> InstanceKey} index.
     */
    public void drop(InstanceKey key) {
        byInstance.remove(key);
    }

    /**
     * Binds an idempotency key to the {@link OrderAcceptedView} that was returned
     * to the client. If the key is already bound, returns the prior view (the
     * existing binding wins — same-key retries are idempotent). If the key is
     * fresh, stores {@code candidate} and returns it.
     */
    public OrderAcceptedView bindIdempotencyKey(String key, OrderAcceptedView candidate) {
        Objects.requireNonNull(key, "key");
        Objects.requireNonNull(candidate, "candidate");
        OrderAcceptedView existing = idempotencyMap.putIfAbsent(key, candidate);
        return existing != null ? existing : candidate;
    }

    /**
     * @return the {@link OrderAcceptedView} previously bound under {@code key},
     *         or empty if no prior POST for this {@code userId+cartId} pair has
     *         been seen in this JVM
     */
    public Optional<OrderAcceptedView> lookupIdempotencyKey(String key) {
        if (key == null) return Optional.empty();
        return Optional.ofNullable(idempotencyMap.get(key));
    }

    /**
     * Updates the API-level status projection for the supplied order. Step
     * lambdas call this on every state transition (e.g. {@code SAGA_INITIATED}
     * after schedule, {@code INVENTORY_RESERVED} after step 0, etc.).
     */
    public void recordStatus(String orderId, String userId, String status, String sagaId) {
        Objects.requireNonNull(orderId, "orderId");
        statusByOrderId.put(orderId, new StatusEntry(userId, status, sagaId));
    }

    /**
     * @return the most recent {@link StatusEntry} for the supplied {@code orderId},
     *         or empty if no entry has been recorded
     */
    public Optional<StatusEntry> lookupStatus(String orderId) {
        if (orderId == null) return Optional.empty();
        return Optional.ofNullable(statusByOrderId.get(orderId));
    }
}
