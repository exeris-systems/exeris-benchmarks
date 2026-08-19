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
import java.util.concurrent.CompletableFuture;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.ExecutionException;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.TimeoutException;
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

    /**
     * Claims a parked payment. The {@code status} predicate is the compare-and-set:
     * only a row still sitting in PAYMENT_PROCESSING can be settled, so a duplicate
     * gateway callback updates nothing and is dropped before it can wake the flow.
     */
    private static final String SETTLE_PARKED_PAYMENT_SQL =
        "UPDATE orders SET status = ?, updated_at = CURRENT_TIMESTAMP "
        + "WHERE id = ? AND status = 'PAYMENT_PROCESSING'";

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

    /**
     * CONTRACT-v2 section 3 request-response support: one future per in-flight saga,
     * completed by the flow's terminal step with the terminal outcome.
     *
     * <p>Why a future and not a poll: {@code FlowScheduler} (exeris-kernel-spi, identical
     * in 0.8.1 and 0.10.2) exposes only {@code schedule/park/wake/lookupParked} — there is
     * no synchronous execute and no completion handle, so the terminal outcome cannot be
     * awaited through the SPI. The alternative, polling {@link #getSagaStatus}, would issue
     * a FlowSnapshotStore load per iteration; this target persists flow state to the v5
     * tables, so a tight poll is a DB SELECT per iteration — measurable extra load applied
     * to THIS stack only, which would bias exactly the comparison the scenario exists to
     * make. Signalling in-process from the terminal step costs nothing and biases nothing.
     */
    private final ConcurrentHashMap<SagaKey, CompletableFuture<String>> terminalOutcome =
        new ConcurrentHashMap<>();

    // --- Parking payment step (CONTRACT-v2 section 4, parking workload) --------

    static final String PAYMENT_AUTHORIZED = "PAYMENT_AUTHORIZED";
    static final String PAYMENT_DECLINED   = "PAYMENT_DECLINED";

    private static final String PAYMENT_GATEWAY_URL =
        System.getenv().getOrDefault("EXERIS_PAYMENT_GATEWAY_URL", "http://localhost:9300/payments");
    // The gateway runs in a container and calls BACK to this JVM on the host, so
    // the advertised callback host is 127.0.0.1 — the container shares the host's
    // network namespace, so this JVM IS its localhost (it was host.docker.internal
    // while the stack ran on the bridge) —
    // same wiring reason as restate-server's RESTATE_SDK_ADVERTISED_URL. Override
    // with EXERIS_PAYMENT_CALLBACK_URL when the gateway runs on the host.
    private static final String PAYMENT_CALLBACK_URL =
        System.getenv().getOrDefault("EXERIS_PAYMENT_CALLBACK_URL",
            "http://127.0.0.1:" + System.getenv().getOrDefault("EXERIS_PORT", "9000")
                + "/api/v1/payments/callback");

    private static final java.net.http.HttpClient PAYMENT_HTTP =
        java.net.http.HttpClient.newBuilder()
            .connectTimeout(java.time.Duration.ofSeconds(5))
            .build();

    /**
     * Reads the settled payment outcome for an order, or null when it has not
     * settled yet. Deliberately a DB read: the flow step re-enters on resume and
     * must see an outcome that survived the crash.
     */
    private String readPaymentOutcome(long orderId) {
        String status = orderRepository.getOrderStatus(orderId);
        if (PAYMENT_AUTHORIZED.equals(status) || PAYMENT_DECLINED.equals(status)) {
            return status;
        }
        return null;
    }

    /**
     * Fire-and-forget dispatch to the external gateway. The gateway answers 202
     * and calls back later; the saga parks in the meantime.
     *
     * <p>A dispatch failure is NOT swallowed into a decline — that would corrupt
     * the section 4.1 population, whose expected compensation count is an exact
     * integer derived from the orderId alone. The flow parks regardless and the
     * order simply never settles, which is visible as a stranded saga rather than
     * as a fake decline.
     */
    private void dispatchPaymentRequest(SagaOrder order) {
        String body = "{\"order_id\":\"" + order.apiOrderId()
            + "\",\"saga_id\":\"" + orderRepository.getSagaId(order.orderId())
            + "\",\"callback_url\":\"" + PAYMENT_CALLBACK_URL + "\"}";
        java.net.http.HttpRequest request = java.net.http.HttpRequest.newBuilder()
            .uri(java.net.URI.create(PAYMENT_GATEWAY_URL))
            .header("Content-Type", "application/json")
            .timeout(java.time.Duration.ofSeconds(10))
            .POST(java.net.http.HttpRequest.BodyPublishers.ofString(body))
            .build();
        PAYMENT_HTTP.sendAsync(request, java.net.http.HttpResponse.BodyHandlers.discarding());
    }

    /**
     * Settles a parked payment: persists the outcome, then wakes the flow so the
     * engine re-enters the payment step and reads it.
     *
     * <p>Persist BEFORE waking. The reverse order races: a woken step could read
     * the row before the outcome landed and park again, this time with no
     * callback left to arrive.
     *
     * @return true when a parked flow was found and woken
     */
    public boolean settlePayment(String apiOrderId, boolean authorized) {
        Long dbOrderId = dbOrderIdByApiOrderId.get(apiOrderId);
        if (dbOrderId == null) {
            return false;
        }
        String outcome = authorized ? PAYMENT_AUTHORIZED : PAYMENT_DECLINED;
        // Compare-and-set on the parked state rather than a blind write: a duplicate
        // callback then updates no row, so it can never wake the flow a second time.
        java.util.concurrent.atomic.AtomicLong claimed = new java.util.concurrent.atomic.AtomicLong();
        executor.executeManaged(conn -> {
            try (PersistenceStatement stmt = conn.prepare(SETTLE_PARKED_PAYMENT_SQL)) {
                claimed.set(stmt.bindString(0, outcome).bindLong(1, dbOrderId).executeUpdate());
            }
        });
        if (claimed.get() == 0L) {
            return false;
        }

        String sagaId = orderRepository.getSagaId(dbOrderId);
        if (sagaId == null || sagaId.isBlank()) {
            return false;
        }
        UUID uuid = UUID.fromString(sagaId);
        // The callback can beat the park. At the shape-A gateway delay (~1 ms) the
        // round trip is comparable to the time the engine needs to reach await-payment
        // and register the instance as parked, so lookupParked legitimately misses.
        // Giving up on the first miss would strand the saga with its outcome already
        // persisted — a hang that reads as "slow stack", not as a race. Bounded wait,
        // then fail loudly rather than silently.
        Optional<FlowContext> parked = Optional.empty();
        for (int attempt = 0; attempt < 200; attempt++) {
            parked = flowEngine.scheduler()
                .lookupParked(uuid.getMostSignificantBits(), uuid.getLeastSignificantBits());
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
            System.err.println("[saga] payment settled for order " + dbOrderId
                + " but no parked flow appeared within 1s; the saga is stranded with"
                + " outcome=" + outcome + " persisted. This is a wake race, not a decline.");
            return false;
        }
        flowEngine.scheduler().wake(parked.get());
        return true;
    }

    /**
     * api orderId -> DB order id, so a gateway callback can find the row. Populated
     * in {@link #scheduleSaga}, which already receives both.
     */
    private final ConcurrentHashMap<String, Long> dbOrderIdByApiOrderId = new ConcurrentHashMap<>();

    /** Completes the waiting {@link #placeOrderAwaitTerminal} caller, if any. */
    private void signalTerminal(FlowContext ctx, String outcome) {
        CompletableFuture<String> future =
            terminalOutcome.get(new SagaKey(ctx.instanceIdMost(), ctx.instanceIdLeast()));
        if (future != null) {
            future.complete(outcome);
        }
    }

    public OrderSagaOrchestrator(FlowEngine flowEngine,
                                  OrderRepository orderRepository,
                                  DomainEventPublisher eventPublisher,
                                  TransactionalExecutor executor) {
        this.flowEngine = flowEngine;
        this.orderRepository = orderRepository;
        this.eventPublisher = eventPublisher;
        this.executor = executor;
        this.faultMode = parseFaultMode(System.getenv(FAULT_MODE_ENV));
        if (faultMode == FaultMode.OFF) {
            // Parsed only so a stale setting is not read as authoritative: under the
            // section 4 parking workload the effective switch is the gateway's
            // PAYMENT_STUB_FAULT_MODE. A knob that silently no-ops is worse than none.
            System.err.println("[saga-fault] WARN: " + FAULT_MODE_ENV + "=off has no effect in the"
                + " parking workload: the CONTRACT-v2 section 4.1 decline is decided by the"
                + " external payment gateway. Set PAYMENT_STUB_FAULT_MODE=off instead.");
        }
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
            // Terminal point of the backward path: compensations unwind LIFO
            // (refund-payment -> restore-inventory), so reserve-inventory's compensation
            // is always the last to run and the saga is COMPENSATED once it returns.
            signalTerminal(ctx, "COMPENSATED");
            return FlowOutcome.CONTINUE;
        };

        // CONTRACT-v2 section 4 (parking workload): S_pay does not answer inline.
        // It dispatches to the external payment gateway and PARKS; the gateway's
        // asynchronous callback wakes it. This is what makes the workload a saga
        // rather than a transaction script, and it is the only shape that
        // exercises the kernel's actual recovery guarantee — AbstractSagaRecoveryTck
        // scopes resumption to PARKED flows, and FlowSnapshotStore.save() fires on
        // the PARK transition.
        //
        // The step is IDEMPOTENT and outcome-driven, because the engine re-enters it
        // on resume: it reads the persisted outcome first and only dispatches when
        // there is none. That is also why the outcome is written to the orders row
        // rather than held in a map — an in-memory outcome would be lost on crash,
        // and the resumed step would re-dispatch to a gateway that has already
        // answered, parking forever.
        // request-payment: commit the payment-requested writes and dispatch, then
        // CONTINUE — deliberately NOT PARK. Returning CONTINUE is what pushes this
        // step's compensation (refund-payment) onto the unwind stack; the kernel's
        // applyParkOutcome does not push one, so parking here would silently drop
        // refund-payment from the LIFO chain on a decline.
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
            dispatchPaymentRequest(order);
            return FlowOutcome.CONTINUE;
        };

        // await-payment: parks and does nothing else.
        //
        // WHY A SEPARATE STEP, established the hard way on 2026-08-18: this kernel's
        // RuntimeFlowInstance.beginScheduleAfterWake() returns currentStep + 1, so a
        // woken flow resumes at the step AFTER the one that parked — it does NOT
        // re-enter it. The previous single-step design read the settled outcome at the
        // top of the parking step and assumed re-entry; on wake that read was simply
        // skipped, so a DECLINED payment continued to confirm-order and the saga
        // completed successfully. Caught by the §3.1 vocabulary preflight on its first
        // execution: forced-decline order returned COMPLETED.
        FlowStepAction awaitPaymentAction = ctx -> FlowOutcome.PARK;

        // settle-payment: the step the wake actually lands on, and therefore the only
        // place the persisted outcome can be read.
        FlowStepAction settlePaymentAction = ctx -> {
            SagaOrder order = resolveOrder(ctx);
            if (order == null) {
                return FlowOutcome.FAIL;
            }
            String settled = readPaymentOutcome(order.orderId());
            if (PAYMENT_DECLINED.equals(settled)) {
                // CONTRACT-v2 section 4.1: business-terminal decline. FAIL routes to
                // kernel-driven LIFO compensation (refund-payment, then
                // restore-inventory) and is never retried (section 5).
                return FlowOutcome.FAIL;
            }
            if (PAYMENT_AUTHORIZED.equals(settled)) {
                return FlowOutcome.CONTINUE;
            }
            // Woken with no settled outcome: the callback did not land, or landed for a
            // different order. FAIL rather than CONTINUE — treating an unknown payment
            // as authorised is the one failure mode this scenario must never have.
            System.err.println("[saga] settle-payment woken with no persisted outcome for order "
                + order.orderId() + "; failing closed to compensation.");
            return FlowOutcome.FAIL;
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
            // Terminal point of the forward path (last step, FlowOutcome.COMPLETE).
            signalTerminal(ctx, "COMPLETED");
            return FlowOutcome.COMPLETE;
        };

        FlowDefinition def = flowEngine.plans()
            .newDefinition("order-fulfillment")
            .step("reserve-inventory", reserveAction,       reserveCompensation)
            .step("request-payment",   paymentAction,       paymentCompensation)
            .step("await-payment",     awaitPaymentAction,  null)
            .step("settle-payment",    settlePaymentAction, null)
            .step("confirm-order",     confirmAction,       null)
            .step("send-email",        emailAction,         null)
            .transition(0, 1)
            .transition(1, 2)
            .transition(2, 3)
            .transition(3, 4)
            .transition(4, 5)
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
        SagaKey sagaKey = new SagaKey(most, least);
        orderIdCache.put(sagaKey, new SagaOrder(orderId, apiOrderId));
        // Reverse mapping for the payment gateway callback, which knows only the
        // api orderId. Registered BEFORE schedule(): the gateway can call back
        // before schedule() returns when the configured delay is small.
        dbOrderIdByApiOrderId.putIfAbsent(apiOrderId, orderId);
        // Registered BEFORE schedule() so a saga that completes immediately cannot
        // signal into a missing entry and strand the caller until its timeout.
        terminalOutcome.put(sagaKey, new CompletableFuture<>());

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

    /**
     * CONTRACT-v2 section 3: block until the saga reaches a terminal outcome and return it
     * ({@code COMPLETED} | {@code COMPENSATED}), so the HTTP response can carry the final
     * outcome instead of the client discovering it by polling.
     *
     * <p>Returns {@link Optional#empty()} if the saga has not settled within
     * {@code timeoutMillis}; the caller then falls back to the pre-v2 async response and the
     * client resolves by polling, so a slow saga degrades rather than fails.
     *
     * <p>Measurement note: this deliberately holds the request thread for the saga's
     * duration. That matches what quarkus-hibernate already does (its command handler runs
     * the whole saga on the request thread) and is what makes order-create latency mean the
     * same thing on both stacks — the prerequisite for comparing them at all.
     */
    public Optional<String> awaitTerminalOutcome(String sagaId, long timeoutMillis) {
        if (sagaId == null || sagaId.isBlank()) {
            return Optional.empty();
        }
        UUID uuid = UUID.fromString(sagaId);
        SagaKey key = new SagaKey(uuid.getMostSignificantBits(), uuid.getLeastSignificantBits());
        CompletableFuture<String> future = terminalOutcome.get(key);
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
            // Always drop the entry: on timeout too, otherwise a saga that never settles
            // leaks its future for the lifetime of the process.
            terminalOutcome.remove(key);
        }
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

    /**
     * <strong>Reference implementation, no longer on the saga path.</strong> Under the
     * CONTRACT-v2 section 4 parking workload the decline is decided by the external
     * payment gateway ({@code targets/payment-gateway-stub/payment_stub.py}), so no
     * target evaluates the rule in-process any more. This method and {@link #fnv1a64}
     * are retained solely because {@code OrderSagaFaultModelTest} pins the normative
     * constants and known-answer vectors the gateway must agree with. Do not re-wire
     * either into a step without removing the gateway's copy first: two implementations
     * of a rule that must be identical everywhere is a drift waiting to happen.
     *
     * <p>CONTRACT-v2 section 4.1 normative decline rule:
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
