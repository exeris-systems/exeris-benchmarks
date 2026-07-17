package eu.exeris.benchmarks.targets.exeriscommunity.saga;

import eu.exeris.benchmarks.targets.exeriscommunity.infrastructure.events.DomainEventPublisher;
import eu.exeris.benchmarks.targets.exeriscommunity.infrastructure.persistence.JdbcOutboxEventStore;
import eu.exeris.benchmarks.targets.exeriscommunity.infrastructure.persistence.OrderRepository;
import eu.exeris.kernel.spi.context.KernelProviders;
import eu.exeris.kernel.spi.flow.FlowEngine;
import eu.exeris.kernel.spi.flow.model.FlowContext;
import eu.exeris.kernel.spi.flow.model.FlowDefinition;
import eu.exeris.kernel.spi.flow.model.FlowExecutionPlan;
import eu.exeris.kernel.spi.flow.model.FlowOutcome;
import eu.exeris.kernel.spi.flow.model.FlowSnapshot;
import eu.exeris.kernel.spi.flow.model.FlowSnapshotStore;
import eu.exeris.kernel.spi.flow.model.FlowState;
import eu.exeris.kernel.spi.flow.model.FlowStepAction;
import eu.exeris.kernel.spi.persistence.PersistenceStatement;
import eu.exeris.kernel.spi.persistence.TransactionalExecutor;
import eu.exeris.kernel.spi.persistence.EventStore;
import java.nio.charset.StandardCharsets;
import java.util.Locale;
import java.util.Optional;
import java.util.concurrent.ConcurrentHashMap;
import java.util.UUID;

/**
 * Wraps the Flow SPI to orchestrate the order-fulfillment saga.
 * The FlowEngine reference is captured at construction time (not via ScopedValue)
 * so it is safely accessible inside step action lambdas running on VTs.
 *
 * <p>Payment fault model (CONTRACT-v2 section 4.1): a payment is <em>declined</em>
 * deterministically per orderId — {@code fnv1a64(orderId) mod 1000 < 30}, exactly
 * 3.0% of the deterministic orderId population, identical in every stack and every
 * run. A decline is a business-terminal outcome: it returns {@link FlowOutcome#FAIL},
 * which routes straight to backward recovery (LIFO compensation) and is never
 * retried (CONTRACT-v2 section 5).
 */
public final class OrderSagaOrchestrator {

    /**
     * CONTRACT-v2 fault-injection switch: {@code terminal} (default) applies the
     * section 4.1 deterministic decline rule; {@code off} disables fault injection
     * entirely (every payment succeeds).
     */
    private enum FaultMode {
        TERMINAL,
        OFF
    }

    private static final String FAULT_MODE_ENV = "EXERIS_SAGA_FAULT_MODE";

    /** Legacy CONTRACT-v1 knobs — read only to WARN; their rate semantics are ignored. */
    private static final String LEGACY_PAYMENT_FAIL_RATE_ENV = "EXERIS_SAGA_PAYMENT_FAIL_RATE";
    private static final String LEGACY_FAILURE_MODE_ENV = "EXERIS_SAGA_FAILURE_MODE";

    /** FNV-1a 64-bit offset basis (CONTRACT-v2 section 4.1 normative constant). */
    private static final long FNV1A64_OFFSET_BASIS = 0xcbf29ce484222325L;
    /** FNV-1a 64-bit prime (CONTRACT-v2 section 4.1 normative constant). */
    private static final long FNV1A64_PRIME = 0x100000001b3L;

    private static final String RESERVE_INVENTORY_SQL =
        "UPDATE inventory " +
        "SET reserved = reserved + 1, quantity_available = quantity_available - 1 " +
        "WHERE product_id IN (SELECT product_id FROM order_items WHERE order_id = ?) " +
        "  AND quantity_available > 0";

    private static final String RESTORE_INVENTORY_SQL =
        "UPDATE inventory " +
        "SET reserved = GREATEST(reserved - 1, 0), " +
        "    quantity_available = quantity_available + 1 " +
        "WHERE product_id IN (SELECT product_id FROM order_items WHERE order_id = ?)";

    private static final String UPDATE_ORDER_STATUS_SQL =
        "UPDATE orders SET status = ?, updated_at = CURRENT_TIMESTAMP WHERE id = ?";

    private final FlowEngine flowEngine;
    private final OrderRepository orderRepository;
    private final DomainEventPublisher eventPublisher;
    private final TransactionalExecutor executor;
    private final FaultMode faultMode;

    private volatile FlowExecutionPlan plan;
    private record SagaKey(long most, long least) {}
    /**
     * DB (BIGSERIAL) order id plus the API-level orderId. {@code apiOrderId} is the
     * CONTRACT-v2 section 3 client-generated seeded orderId adopted verbatim at order
     * creation (decimal DB id only for pre-v2 clients that supply none) — it is the
     * section 4.1 decline key; domain writes stay keyed on the DB id.
     */
    private record SagaOrder(long orderId, String apiOrderId) {}
    private final ConcurrentHashMap<SagaKey, SagaOrder> orderIdCache = new ConcurrentHashMap<>();

    public OrderSagaOrchestrator(FlowEngine flowEngine,
                                  OrderRepository orderRepository,
                                  DomainEventPublisher eventPublisher,
                                  TransactionalExecutor executor) {
        this.flowEngine = flowEngine;
        this.orderRepository = orderRepository;
        this.eventPublisher = eventPublisher;
        this.executor = executor;
        this.faultMode = parseFaultMode(System.getenv(FAULT_MODE_ENV));
        warnIfLegacyFaultEnvSet();
    }

    public synchronized void initialize() {
        if (plan != null) {
            return;
        }

        FlowStepAction reserveAction = ctx -> {
            SagaOrder order = resolveOrder(ctx);
            if (order == null) {
                return FlowOutcome.FAIL;
            }
            long orderId = order.orderId();
            executor.executeManaged(conn -> {
                try (PersistenceStatement stmt = conn.prepare(RESERVE_INVENTORY_SQL)) {
                    stmt.bindLong(0, orderId).executeUpdate();
                }
                updateStatus(conn, orderId, "INVENTORY_RESERVED");
            });
            return FlowOutcome.CONTINUE;
        };

        FlowStepAction reserveCompensation = ctx -> {
            SagaOrder order = resolveOrder(ctx);
            if (order == null) {
                return FlowOutcome.CONTINUE;
            }
            long orderId = order.orderId();
            executor.executeManaged(conn -> {
                try (PersistenceStatement stmt = conn.prepare(RESTORE_INVENTORY_SQL)) {
                    stmt.bindLong(0, orderId).executeUpdate();
                }
                updateStatus(conn, orderId, "CANCELLED");
            });
            return FlowOutcome.CONTINUE;
        };

        FlowStepAction paymentAction = ctx -> {
            SagaOrder order = resolveOrder(ctx);
            if (order == null) {
                return FlowOutcome.FAIL;
            }
            long orderId = order.orderId();
            byte[] payloadBytes = paymentRequestedPayload(orderId).getBytes(StandardCharsets.UTF_8);
            executor.executeManaged(conn -> {
                new JdbcOutboxEventStore(conn).append(new EventStore.OutboxEvent(
                    UUID.randomUUID(),
                    String.valueOf(orderId),
                    "ORDER",
                    "PAYMENT_REQUESTED",
                    payloadBytes,
                    System.currentTimeMillis()
                ));
                updateStatus(conn, orderId, "PAYMENT_PROCESSING");
            });
            // CONTRACT-v2 section 4.1: deterministic business-terminal decline, selected
            // per-orderId (never per-attempt). FlowOutcome.FAIL routes to kernel-driven
            // LIFO compensation; a decline is never retried (section 5: zero retries).
            if (shouldDeclinePayment(order.apiOrderId())) {
                return FlowOutcome.FAIL;
            }
            return FlowOutcome.CONTINUE;
        };

        FlowStepAction paymentCompensation = ctx -> {
            SagaOrder order = resolveOrder(ctx);
            if (order == null) {
                return FlowOutcome.CONTINUE;
            }
            long orderId = order.orderId();
            byte[] payloadBytes = orderCompensatedPayload(orderId).getBytes(StandardCharsets.UTF_8);
            executor.executeManaged(conn -> {
                updateStatus(conn, orderId, "PAYMENT_REFUNDED");
                new JdbcOutboxEventStore(conn).append(new EventStore.OutboxEvent(
                    UUID.randomUUID(),
                    String.valueOf(orderId),
                    "ORDER",
                    "ORDER_COMPENSATED",
                    payloadBytes,
                    System.currentTimeMillis()
                ));
            });
            return FlowOutcome.CONTINUE;
        };

        FlowStepAction confirmAction = ctx -> {
            SagaOrder order = resolveOrder(ctx);
            if (order == null) {
                return FlowOutcome.FAIL;
            }
            long orderId = order.orderId();
            byte[] payloadBytes = orderConfirmedPayload(orderId).getBytes(StandardCharsets.UTF_8);
            executor.executeManaged(conn -> {
                updateStatus(conn, orderId, "CONFIRMED");
                new JdbcOutboxEventStore(conn).append(new EventStore.OutboxEvent(
                    UUID.randomUUID(),
                    String.valueOf(orderId),
                    "ORDER",
                    "ORDER_CONFIRMED",
                    payloadBytes,
                    System.currentTimeMillis()
                ));
            });
            return FlowOutcome.CONTINUE;
        };

        FlowStepAction emailAction = ctx -> {
            SagaOrder order = resolveOrder(ctx);
            if (order != null) {
                long orderId = order.orderId();
                executor.executeManaged(conn -> updateStatus(conn, orderId, "COMPLETED"));
            }
            return FlowOutcome.COMPLETE;
        };

        FlowDefinition def = flowEngine.plans()
            .newDefinition("order-fulfillment")
            .step("reserve-inventory", reserveAction, reserveCompensation)
            .step("charge-payment",    paymentAction,  paymentCompensation)
            .step("confirm-order",     confirmAction,  null)
            .step("send-email",        emailAction,    null)
            .transition(0, 1)
            .transition(1, 2)
            .transition(2, 3)
            // CONTRACT-v2 section 5 transient-fault retry budget: max 3 attempts total
            // (1 initial + 2 retries) -> maxRetries(2) counts retries after the initial
            // attempt. Terminal declines (section 4.1) return FlowOutcome.FAIL, which
            // routes straight to compensation and is exempt from any retry budget.
            .maxRetries(2)
            // TODO(CONTRACT-v2 section 5): the pinned backoff shape -- exponential, initial
            // 50 ms, factor 2, NO jitter -- is not expressible in exeris-kernel-spi 0.10.0.
            // FlowDefinitionBuilder exposes only maxRetries(int) and timeoutDuration(long);
            // there is no backoff hook (e.g. retryBackoff(initialNanos, factor, jitterEnabled),
            // per-definition or per-step). Also note: FlowDefinition.maxRetries is recorded in
            // the definition, but no consumer was found in the kernel 0.10.0 core flow runtime,
            // so enforcement must be re-verified when transient injection (section 4.2) lands.
            // Configure the explicit backoff here as soon as the SPI grows the API.
            .build();

        this.plan = flowEngine.plans().compile(def);
    }

    /**
     * @param orderId    DB (BIGSERIAL) order id keying the domain writes
     * @param apiOrderId API-level orderId — the CONTRACT-v2 section 3 client-generated
     *                   seeded orderId adopted verbatim at order creation; the section
     *                   4.1 payment-decline key
     */
    public String scheduleSaga(long orderId, String apiOrderId, long userId, String paymentMethod) {
        UUID uuid  = UUID.randomUUID();
        long most  = uuid.getMostSignificantBits();
        long least = uuid.getLeastSignificantBits();

        orderRepository.updateSagaId(orderId, uuid.toString());
        orderIdCache.put(new SagaKey(most, least), new SagaOrder(orderId, apiOrderId));

        FlowContext ctx = new FlowContext() {
            @Override public long instanceIdMost()   { return most; }
            @Override public long instanceIdLeast()  { return least; }
            @Override public String definitionName() { return "order-fulfillment"; }
            @Override public int currentStep()       { return 0; }
            @Override public FlowState state()       { return FlowState.RUNNING; }
            @Override public long timeoutNanos()     { return System.nanoTime() + 60_000_000_000L; }
        };

        flowEngine.scheduler().schedule(plan, ctx);
        return uuid.toString();
    }

    public String getSagaStatus(long orderId) {
        String sagaId = orderRepository.getSagaId(orderId);
        if (sagaId != null && !sagaId.isBlank()) {
            UUID sagaUuid = UUID.fromString(sagaId);
            long most = sagaUuid.getMostSignificantBits();
            long least = sagaUuid.getLeastSignificantBits();
            Optional<FlowSnapshotStore> store = KernelProviders.flowSnapshotStore();
            if (store.isPresent()) {
                Optional<FlowSnapshot> snapshot = store.get().load(most, least);
                if (snapshot.isPresent()) {
                    FlowState state = snapshot.get().state();
                    if (state.isTerminal()) {
                        orderIdCache.remove(new SagaKey(most, least));
                    }
                    return mapFlowState(state);
                }
            }
        }
        String dbStatus = orderRepository.getOrderStatus(orderId);
        return dbStatus != null ? dbStatus : "UNKNOWN";
    }

    private static String mapFlowState(FlowState state) {
        return switch (state) {
            case CREATED, RUNNING, PARKED -> "SAGA_INITIATED";
            case COMPLETED                -> "COMPLETED";
            case COMPENSATING             -> "COMPENSATING";
            case FAILED_ROLLEDBACK        -> "COMPENSATED";
        };
    }

    private SagaOrder resolveOrder(FlowContext ctx) {
        SagaOrder cached = orderIdCache.get(new SagaKey(ctx.instanceIdMost(), ctx.instanceIdLeast()));
        if (cached != null) return cached;
        UUID sagaId = new UUID(ctx.instanceIdMost(), ctx.instanceIdLeast());
        Long orderId = orderRepository.findOrderIdBySagaId(sagaId.toString());
        if (orderId == null) return null;
        // Cache miss (cross-restart resumption): the client-generated API orderId lives
        // only in the in-process cache — parity with the sibling stacks' in-memory
        // projections, where cross-restart recovery is equally out of scope — so fall
        // back to the decimal DB id as the decline key.
        return new SagaOrder(orderId, Long.toString(orderId));
    }

    private boolean shouldDeclinePayment(String apiOrderId) {
        // The decline key is the API-level orderId: the CONTRACT-v2 section 3
        // client-generated seeded orderId adopted verbatim at order creation — the same
        // string the client receives in the order_id response field and polls status
        // with (decimal DB id only for pre-v2 clients that supply none).
        return faultMode == FaultMode.TERMINAL && isDeclined(apiOrderId);
    }

    /**
     * CONTRACT-v2 section 4.1 normative decline rule:
     * {@code decline(orderId) := Long.remainderUnsigned(fnv1a64(orderId), 1000) < 30}
     * — exactly 3.0% of the deterministic orderId population, identical in every stack.
     * The modulo is taken on the UNSIGNED interpretation of the 64-bit hash.
     */
    static boolean isDeclined(String orderId) {
        return Long.remainderUnsigned(fnv1a64(orderId), 1000L) < 30L;
    }

    /**
     * FNV-1a 64-bit over the UTF-8 bytes of {@code value} (CONTRACT-v2 section 4.1
     * normative constants: offset basis 0xcbf29ce484222325, prime 0x100000001b3,
     * unsigned arithmetic — Java long wraparound matches mod-2^64 exactly).
     */
    static long fnv1a64(String value) {
        long hash = FNV1A64_OFFSET_BASIS;
        for (byte b : value.getBytes(StandardCharsets.UTF_8)) {
            hash ^= (b & 0xFFL);
            hash *= FNV1A64_PRIME;
        }
        return hash;
    }

    private static String paymentRequestedPayload(long orderId) {
        return "{\"order_id\":" + orderId + ",\"event\":\"PAYMENT_REQUESTED\"}";
    }

    private static String orderConfirmedPayload(long orderId) {
        return "{\"order_id\":" + orderId + ",\"event\":\"ORDER_CONFIRMED\"}";
    }

    private static String orderCompensatedPayload(long orderId) {
        return "{\"order_id\":" + orderId + ",\"event\":\"ORDER_COMPENSATED\"}";
    }

    private static FaultMode parseFaultMode(String value) {
        if (value == null || value.isBlank()) {
            return FaultMode.TERMINAL;
        }
        return switch (value.trim().toLowerCase(Locale.ROOT)) {
            case "terminal" -> FaultMode.TERMINAL;
            case "off" -> FaultMode.OFF;
            default -> {
                System.err.println("[saga-fault] WARN: unknown " + FAULT_MODE_ENV + "='" + value
                    + "' (expected terminal|off); defaulting to terminal");
                yield FaultMode.TERMINAL;
            }
        };
    }

    /**
     * CONTRACT-v1 knobs are still parsed for backward compatibility but their rate
     * semantics are ignored: v2 section 4.1 replaced per-attempt probabilistic
     * injection with the deterministic per-orderId decline rule.
     */
    private static void warnIfLegacyFaultEnvSet() {
        String legacyRate = System.getenv(LEGACY_PAYMENT_FAIL_RATE_ENV);
        if (legacyRate != null && !legacyRate.isBlank()) {
            System.err.println("[saga-fault] WARN: " + LEGACY_PAYMENT_FAIL_RATE_ENV + "='" + legacyRate
                + "' is ignored under CONTRACT-v2 section 4.1: the payment decline is deterministic"
                + " per orderId (fnv1a64(orderId) mod 1000 < 30, exactly 3.0%), not rate-sampled."
                + " Use " + FAULT_MODE_ENV + "=terminal|off instead.");
        }
        String legacyMode = System.getenv(LEGACY_FAILURE_MODE_ENV);
        if (legacyMode != null && !legacyMode.isBlank()) {
            System.err.println("[saga-fault] WARN: " + LEGACY_FAILURE_MODE_ENV + "='" + legacyMode
                + "' is ignored under CONTRACT-v2 section 4.1."
                + " Use " + FAULT_MODE_ENV + "=terminal|off instead.");
        }
    }

    private void updateStatus(eu.exeris.kernel.spi.persistence.PersistenceConnection conn,
                              long orderId, String status) {
        try (PersistenceStatement stmt = conn.prepare(UPDATE_ORDER_STATUS_SQL)) {
            stmt.bindString(0, status).bindLong(1, orderId).executeUpdate();
        }
    }
}
