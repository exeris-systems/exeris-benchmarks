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
 * {@code ConcurrentMap} keyed by the API-level {@code orderId} string). The
 * pre-migration Axon target used the same single-JVM projection shape via
 * {@code AxonOrderSagaProjection}; cross-restart status recovery is out of
 * scope for this benchmark and was equally out of scope before the swap.
 */
@Service
public class ShopOrderFlowService {

    /**
     * Prefix of the API-level saga id. The remainder is the flow instance UUID, which
     * is what makes {@link #settlePayment} able to find a parked flow from a callback
     * that carries only the saga id.
     */
    private static final String SAGA_ID_PREFIX = "saga-";

    /**
     * CONTRACT-v2 section 3 request-response budget. Matched to the client's own
     * resolution budget (k6 polls 25 x 1 s) so this stack never gives up before the
     * client would.
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
     * <p>{@code clientOrderId} is the CONTRACT-v2 section 3 client-generated
     * deterministic orderId. When present it is adopted verbatim as the
     * API-level orderId — it is the input to the section 4.1 deterministic
     * payment-decline rule, so minting a server-side id here would break the
     * "identical declined subset in every stack and every run" invariant.
     * Blank/absent (pre-v2 clients) falls back to a server-generated UUID.
     *
     * @return empty if the cart does not exist or is not owned by {@code userId};
     *         a {@link OrderAcceptedView} otherwise
     */
    public Optional<OrderAcceptedView> createOrder(
            String userId,
            String clientOrderId,
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

        String orderId = (clientOrderId == null || clientOrderId.isBlank())
                ? UUID.randomUUID().toString()
                : clientOrderId.trim();

        // The context is minted FIRST so the sagaId can carry the flow instance id.
        // CONTRACT-v2 section 4 (parking workload): the gateway callback knows only the
        // sagaId, and it has to find the parked flow — deriving one from the other is
        // what lets it call lookupParked directly, with no sagaId -> instance index to
        // keep consistent. Same coupling exeris-community-app has, where the sagaId IS
        // the flow instance UUID.
        FlowContext seed = flowTemplate.newContext(ShopOrderFlowDefinition.FLOW_NAME);
        String sagaId = SAGA_ID_PREFIX
                + new UUID(seed.instanceIdMost(), seed.instanceIdLeast());

        // Synchronous insert: orders + order_items rows exist before the response returns.
        // Matches the pre-migration API shape exactly (see class javadoc + README).
        long dbOrderId = sqlSteps.insertOrder(userId, cartId, sagaId);

        // Seed the initial API-level status before scheduling — matches the
        // pre-migration projection which wrote SAGA_INITIATED on the same event.
        inputRegistry.recordStatus(orderId, userId, "SAGA_INITIATED", sagaId);

        inputRegistry.bind(
                seed,
                new ShopOrderFlowInputRegistry.Input(
                        orderId, sagaId, userId, cartId, paymentMethod, dbOrderId));
        // Registered BEFORE schedule: a saga that settles immediately must not signal
        // into a missing entry and strand the caller until its timeout.
        inputRegistry.expectTerminalOutcome(orderId);
        flowTemplate.schedule(ShopOrderFlowDefinition.FLOW_NAME, seed);

        // CONTRACT-v2 section 3: the response carries the FINAL outcome. Falls back to
        // the pre-v2 async ACCEPTED on timeout, so a slow saga degrades to client
        // polling rather than failing the request.
        String terminal = inputRegistry
                .awaitTerminalOutcome(orderId, SAGA_TERMINAL_AWAIT_TIMEOUT_MILLIS)
                .map(ShopOrderFlowService::toContractStatus)
                .orElse("ACCEPTED");

        OrderAcceptedView candidate = new OrderAcceptedView(orderId, terminal, sagaId);
        // bindIdempotencyKey returns the existing entry if a concurrent POST won the race.
        return Optional.of(inputRegistry.bindIdempotencyKey(idempotencyKey, candidate));
    }

    /**
     * Settles a flow parked on charge-payment, driven by the external gateway's
     * callback (CONTRACT-v2 section 4). Persists the outcome BEFORE waking: the
     * reverse order races, because a woken step could read the row before the
     * outcome landed and park again — this time with no callback left to arrive.
     *
     * @return false when no flow was parked on payment under {@code sagaId} — a
     *         duplicate callback, or one for a saga this process never had
     */
    public boolean settlePayment(String sagaId, boolean authorized) {
        if (sagaId == null || !sagaId.startsWith(SAGA_ID_PREFIX)) {
            return false;
        }
        UUID instance;
        try {
            instance = UUID.fromString(sagaId.substring(SAGA_ID_PREFIX.length()));
        } catch (IllegalArgumentException notAFlowInstance) {
            return false;
        }
        if (sqlSteps.settleParkedPayment(sagaId, authorized).isEmpty()) {
            return false;
        }
        // The callback can beat the park: at the shape-A gateway delay (~1 ms) the round
        // trip is comparable to the time the engine needs to reach await-payment and
        // register the instance. Giving up on the first miss strands the saga with its
        // outcome already persisted — a hang that reads as "slow stack", not as a race.
        Optional<FlowContext> parked = Optional.empty();
        for (int attempt = 0; attempt < 200; attempt++) {
            parked = flowTemplate.lookupParked(
                    instance.getMostSignificantBits(), instance.getLeastSignificantBits());
            if (parked.isPresent()) {
                break;
            }
            try {
                Thread.sleep(5L);
            } catch (InterruptedException interrupted) {
                Thread.currentThread().interrupt();
                return false;
            }
        }
        if (parked.isEmpty()) {
            return false;
        }
        flowTemplate.wake(parked.get());
        return true;
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
     * e2e-shop-order-saga contract polls for. The CONTRACT-v2 terminal set is
     * {@code COMPLETED} / {@code COMPENSATED} / {@code FAILED_UNRECOVERED} (section
     * 3; {@code scenarios/e2e-shop-order-saga/k6.js} {@code TERMINAL_SAGA_STATUSES});
     * the saga's compensation chain records {@code PAYMENT_REFUNDED} then the
     * terminal {@code CANCELLED}, neither of which the poller recognizes as
     * terminal — so without this mapping a compensated saga is polled to
     * exhaustion and scored {@code saga_unresolved}. Mirrors
     * {@code exeris-community-app}'s {@code RepositoryBackedBenchmarkUseCaseService.mapFallbackSagaStatus}
     * so all targets expose an identical status surface. {@code FAILED} (defensive:
     * no step lambda records it today) maps to the section 5 vocabulary
     * {@code FAILED_UNRECOVERED} — compensation retry-budget exhaustion.
     * Non-terminal in-progress statuses ({@code SAGA_INITIATED},
     * {@code INVENTORY_RESERVED}, {@code PAYMENT_PROCESSING}) pass through
     * unchanged for the poller to keep polling.
     */
    private static String toContractStatus(String internalStatus) {
        return switch (internalStatus) {
            case "COMPLETED" -> "COMPLETED";
            case "CANCELLED" -> "COMPENSATED";
            case "FAILED" -> "FAILED_UNRECOVERED";
            // CONFIRMED and PAYMENT_REFUNDED used to map to the terminal COMPLETED /
            // COMPENSATED. That was wrong and it was wrong in this stack only: both are
            // MID-path states (confirm-order done but complete-order pending; payment
            // refunded but restore-inventory pending), so a poller could observe a
            // terminal outcome that later regresses to the opposite one. quarkus-hibernate
            // maps them to the non-terminal COMPLETING / COMPENSATING for exactly this
            // reason; the four stacks now agree on the terminal surface, which they must,
            // because the §7 oracles count terminal observations.
            case "CONFIRMED" -> "COMPLETING";
            case "PAYMENT_REFUNDED" -> "COMPENSATING";
            default -> internalStatus;
        };
    }
}
