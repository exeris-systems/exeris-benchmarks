package eu.exeris.benchmarks.targets.springapp.application.flow;

import eu.exeris.benchmarks.targets.springapp.api.OrderAcceptedView;
import eu.exeris.benchmarks.targets.springapp.api.OrderStatusView;
import eu.exeris.benchmarks.targets.springapp.application.ShopSagaStateService;
import eu.exeris.kernel.spi.flow.model.FlowContext;
import eu.exeris.spring.runtime.flow.ExerisFlowTemplate;

import org.springframework.stereotype.Service;

import java.util.Optional;
import java.util.UUID;

/**
 * Replacement for {@code AxonOrderSagaService} backed by
 * {@code exeris-spring-runtime-flow}. Drives the {@code shop-order-fulfillment}
 * flow and exposes the same API surface the controller expects.
 *
 * <h2>Synchronous-insert variant</h2>
 * <p>{@code orders}+{@code order_items} rows are inserted on the request thread,
 * <em>before</em> the flow is scheduled. The accepted view is then returned to
 * the client as 202 ACCEPTED, with the flow continuing asynchronously on
 * kernel-owned virtual threads. The API contract — "the orderId in the 202
 * response is durably persisted" — matches the pre-migration Axon shape, which
 * is required so the existing benchmark scenario (and the prior baseline
 * captured against it) remains structurally comparable. The methodology
 * caveats around comparing the numbers across the swap are documented in the
 * target's README.
 *
 * <h2>Status lookup</h2>
 * <p>{@link #orderStatus} reads from the
 * {@link ShopOrderFlowInputRegistry} projection (in-process
 * {@code ConcurrentMap} keyed by the API-level UUID {@code orderId}). The
 * pre-migration Axon target used the same single-JVM projection shape via
 * {@code AxonOrderSagaProjection}; cross-restart status recovery is out of
 * scope for this benchmark and was equally out of scope before the swap.
 */
@Service
public class ShopOrderFlowService {

    private final ExerisFlowTemplate flowTemplate;
    private final ShopOrderFlowInputRegistry inputRegistry;
    private final ShopOrderSqlSteps sqlSteps;

    public ShopOrderFlowService(
            ExerisFlowTemplate flowTemplate,
            ShopOrderFlowInputRegistry inputRegistry,
            ShopOrderSqlSteps sqlSteps
    ) {
        this.flowTemplate = flowTemplate;
        this.inputRegistry = inputRegistry;
        this.sqlSteps = sqlSteps;
    }

    /**
     * Creates a new order and schedules the saga. Idempotent under
     * {@code userId+":"+cartId}: a repeated POST after the first has returned
     * resolves to the prior view from
     * {@link ShopOrderFlowInputRegistry#lookupIdempotencyKey}.
     *
     * @return empty if the cart does not exist or is not owned by {@code userId};
     *         a {@link OrderAcceptedView} otherwise
     */
    public Optional<OrderAcceptedView> createOrder(
            String userId,
            String cartId,
            String paymentMethod,
            ShopSagaStateService cartState
    ) {
        if (!cartState.hasCartForUser(userId, cartId)) {
            return Optional.empty();
        }

        String idempotencyKey = userId + ":" + cartId;
        Optional<OrderAcceptedView> prior = inputRegistry.lookupIdempotencyKey(idempotencyKey);
        if (prior.isPresent()) {
            return prior;
        }

        String orderId = UUID.randomUUID().toString();
        String sagaId = "saga-" + UUID.randomUUID();

        // Synchronous insert: orders + order_items rows exist before the 202 returns.
        // Matches the pre-migration API shape exactly (see class javadoc + README).
        long dbOrderId = sqlSteps.insertOrder(userId, cartId, sagaId);

        // Seed the initial API-level status before scheduling — matches the
        // pre-migration projection which wrote SAGA_INITIATED on the same event.
        inputRegistry.recordStatus(orderId, userId, "SAGA_INITIATED", sagaId);

        FlowContext seed = flowTemplate.newContext(ShopOrderFlowDefinition.FLOW_NAME);
        inputRegistry.bind(
                seed,
                new ShopOrderFlowInputRegistry.Input(
                        orderId, sagaId, userId, cartId, paymentMethod, dbOrderId));
        flowTemplate.schedule(ShopOrderFlowDefinition.FLOW_NAME, seed);

        OrderAcceptedView candidate = new OrderAcceptedView(orderId, "ACCEPTED", sagaId);
        // bindIdempotencyKey returns the existing entry if a concurrent POST won the race.
        return Optional.of(inputRegistry.bindIdempotencyKey(idempotencyKey, candidate));
    }

    /**
     * Returns the current status of an order owned by {@code userId}, or empty
     * if no such order exists / is owned by another user.
     *
     * <p>Status vocabulary mirrors the pre-migration projection:
     * {@code SAGA_INITIATED}, {@code INVENTORY_RESERVED}, {@code PAYMENT_PROCESSING},
     * {@code CONFIRMED}, {@code COMPLETED}, {@code PAYMENT_REFUNDED},
     * {@code CANCELLED}. Each step lambda calls
     * {@link ShopOrderFlowInputRegistry#recordStatus} on transition, so reads
     * here observe the latest step-level state.
     */
    public Optional<OrderStatusView> orderStatus(String userId, String orderId) {
        Optional<ShopOrderFlowInputRegistry.StatusEntry> entry = inputRegistry.lookupStatus(orderId);
        if (entry.isEmpty() || !entry.get().userId().equals(userId)) {
            return Optional.empty();
        }
        return Optional.of(new OrderStatusView(orderId, toContractStatus(entry.get().status()), entry.get().sagaId()));
    }

    /**
     * Maps the internal step-lambda status vocabulary onto the API-level status the
     * e2e-shop-order-saga k6 contract polls for. The contract's terminal set is
     * {@code COMPLETED} / {@code COMPENSATED} / {@code FAILED} (see
     * {@code scenarios/e2e-shop-order-saga/k6.js} {@code TERMINAL_SAGA_STATUSES});
     * the saga's compensation chain records {@code PAYMENT_REFUNDED} then the
     * terminal {@code CANCELLED}, neither of which the poller recognizes as
     * terminal — so without this mapping a compensated saga is polled to
     * exhaustion and scored {@code saga_unresolved}. Mirrors
     * {@code exeris-community-app}'s {@code RepositoryBackedBenchmarkUseCaseService.mapFallbackSagaStatus}
     * so all targets expose an identical status surface. Non-terminal in-progress
     * statuses ({@code SAGA_INITIATED}, {@code INVENTORY_RESERVED},
     * {@code PAYMENT_PROCESSING}) pass through unchanged for the poller to keep polling.
     */
    private static String toContractStatus(String internalStatus) {
        return switch (internalStatus) {
            case "COMPLETED", "CONFIRMED" -> "COMPLETED";
            case "CANCELLED", "PAYMENT_REFUNDED" -> "COMPENSATED";
            case "FAILED" -> "FAILED";
            default -> internalStatus;
        };
    }
}
