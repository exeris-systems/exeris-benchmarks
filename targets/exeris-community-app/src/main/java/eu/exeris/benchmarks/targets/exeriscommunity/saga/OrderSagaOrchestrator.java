package eu.exeris.benchmarks.targets.exeriscommunity.saga;

import eu.exeris.benchmarks.targets.exeriscommunity.infrastructure.events.DomainEventPublisher;
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
import eu.exeris.kernel.community.persistence.jdbc.CommunityJdbcEventStore;
import eu.exeris.kernel.spi.persistence.EventStore;
import java.nio.charset.StandardCharsets;
import java.util.Optional;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.ThreadLocalRandom;
import java.util.UUID;

/**
 * Wraps the Flow SPI to orchestrate the order-fulfillment saga.
 * The FlowEngine reference is captured at construction time (not via ScopedValue)
 * so it is safely accessible inside step action lambdas running on VTs.
 */
public final class OrderSagaOrchestrator {

    private enum FailureMode {
        RANDOM_SEEDED,
        ALWAYS_FAIL,
        NEVER_FAIL
    }

    private static final String PAYMENT_FAIL_RATE_ENV = "EXERIS_SAGA_PAYMENT_FAIL_RATE";
    private static final String FAILURE_MODE_ENV = "EXERIS_SAGA_FAILURE_MODE";

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
    private final double paymentFailureRate;
    private final FailureMode failureMode;

    private volatile FlowExecutionPlan plan;
    private record SagaKey(long most, long least) {}
    private final ConcurrentHashMap<SagaKey, Long> orderIdCache = new ConcurrentHashMap<>();

    public OrderSagaOrchestrator(FlowEngine flowEngine,
                                  OrderRepository orderRepository,
                                  DomainEventPublisher eventPublisher,
                                  TransactionalExecutor executor) {
        this.flowEngine = flowEngine;
        this.orderRepository = orderRepository;
        this.eventPublisher = eventPublisher;
        this.executor = executor;
        this.paymentFailureRate = parseDoubleOrDefault(System.getenv(PAYMENT_FAIL_RATE_ENV), 0.03d);
        this.failureMode = parseFailureMode(System.getenv(FAILURE_MODE_ENV));
    }

    public synchronized void initialize() {
        if (plan != null) {
            return;
        }

        FlowStepAction reserveAction = ctx -> {
            Long orderId = resolveOrderId(ctx);
            if (orderId == null) {
                return FlowOutcome.FAIL;
            }
            executor.executeManaged(conn -> {
                try (PersistenceStatement stmt = conn.prepare(RESERVE_INVENTORY_SQL)) {
                    stmt.bindLong(0, orderId).executeUpdate();
                }
                updateStatus(conn, orderId, "INVENTORY_RESERVED");
            });
            return FlowOutcome.CONTINUE;
        };

        FlowStepAction reserveCompensation = ctx -> {
            Long orderId = resolveOrderId(ctx);
            if (orderId == null) {
                return FlowOutcome.CONTINUE;
            }
            executor.executeManaged(conn -> {
                try (PersistenceStatement stmt = conn.prepare(RESTORE_INVENTORY_SQL)) {
                    stmt.bindLong(0, orderId).executeUpdate();
                }
                updateStatus(conn, orderId, "CANCELLED");
            });
            return FlowOutcome.CONTINUE;
        };

        FlowStepAction paymentAction = ctx -> {
            Long orderId = resolveOrderId(ctx);
            if (orderId == null) {
                return FlowOutcome.FAIL;
            }
            byte[] payloadBytes = paymentRequestedPayload(orderId).getBytes(StandardCharsets.UTF_8);
            executor.executeManaged(conn -> {
                new CommunityJdbcEventStore(conn).append(new EventStore.OutboxEvent(
                    UUID.randomUUID(),
                    String.valueOf(orderId),
                    "ORDER",
                    "PAYMENT_REQUESTED",
                    payloadBytes,
                    System.currentTimeMillis()
                ));
                updateStatus(conn, orderId, "PAYMENT_PROCESSING");
            });
            if (shouldFailPayment()) {
                return FlowOutcome.FAIL;
            }
            return FlowOutcome.CONTINUE;
        };

        FlowStepAction paymentCompensation = ctx -> {
            Long orderId = resolveOrderId(ctx);
            if (orderId == null) {
                return FlowOutcome.CONTINUE;
            }
            byte[] payloadBytes = orderCompensatedPayload(orderId).getBytes(StandardCharsets.UTF_8);
            executor.executeManaged(conn -> {
                updateStatus(conn, orderId, "PAYMENT_REFUNDED");
                new CommunityJdbcEventStore(conn).append(new EventStore.OutboxEvent(
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
            Long orderId = resolveOrderId(ctx);
            if (orderId == null) {
                return FlowOutcome.FAIL;
            }
            byte[] payloadBytes = orderConfirmedPayload(orderId).getBytes(StandardCharsets.UTF_8);
            executor.executeManaged(conn -> {
                updateStatus(conn, orderId, "CONFIRMED");
                new CommunityJdbcEventStore(conn).append(new EventStore.OutboxEvent(
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
            Long orderId = resolveOrderId(ctx);
            if (orderId != null) {
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
            .build();

        this.plan = flowEngine.plans().compile(def);
    }

    public String scheduleSaga(long orderId, long userId, String paymentMethod) {
        UUID uuid  = UUID.randomUUID();
        long most  = uuid.getMostSignificantBits();
        long least = uuid.getLeastSignificantBits();

        orderRepository.updateSagaId(orderId, uuid.toString());
        orderIdCache.put(new SagaKey(most, least), orderId);

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

    private Long resolveOrderId(FlowContext ctx) {
        Long cached = orderIdCache.get(new SagaKey(ctx.instanceIdMost(), ctx.instanceIdLeast()));
        if (cached != null) return cached;
        UUID sagaId = new UUID(ctx.instanceIdMost(), ctx.instanceIdLeast());
        return orderRepository.findOrderIdBySagaId(sagaId.toString());
    }

    private boolean shouldFailPayment() {
        return switch (failureMode) {
            case ALWAYS_FAIL -> true;
            case NEVER_FAIL -> false;
            case RANDOM_SEEDED -> ThreadLocalRandom.current().nextDouble() < paymentFailureRate;
        };
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

    private static double parseDoubleOrDefault(String value, double fallback) {
        if (value == null || value.isBlank()) {
            return fallback;
        }
        try {
            return Double.parseDouble(value.trim());
        } catch (NumberFormatException exception) {
            return fallback;
        }
    }

    private static FailureMode parseFailureMode(String value) {
        if (value == null || value.isBlank()) {
            return FailureMode.RANDOM_SEEDED;
        }
        try {
            return FailureMode.valueOf(value.trim().toUpperCase());
        } catch (IllegalArgumentException exception) {
            return FailureMode.RANDOM_SEEDED;
        }
    }

    private void updateStatus(eu.exeris.kernel.spi.persistence.PersistenceConnection conn,
                              long orderId, String status) {
        try (PersistenceStatement stmt = conn.prepare(UPDATE_ORDER_STATUS_SQL)) {
            stmt.bindString(0, status).bindLong(1, orderId).executeUpdate();
        }
    }
}
