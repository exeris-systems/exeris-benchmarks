package eu.exeris.benchmarks.targets.springapp.application.flow;

import eu.exeris.kernel.spi.flow.FlowDefinitionBuilder;
import eu.exeris.kernel.spi.flow.model.FlowDefinition;
import eu.exeris.kernel.spi.flow.model.FlowOutcome;
import eu.exeris.spring.runtime.flow.ExerisFlowDefinition;

import org.springframework.stereotype.Component;

/**
 * Saga definition for {@code POST /api/v1/orders} on the e2e-shop-order-saga
 * benchmark target.
 *
 * <h2>Topology — synchronous-insert variant</h2>
 * <pre>
 *   step 0: reserve-inventory  (compensation: restore-inventory)
 *   step 1: request-payment    (compensation: refund-payment) — writes + dispatch, CONTINUE
 *   step 2: await-payment      (no compensation) — PARK
 *   step 3: settle-payment     (no compensation) — reads the persisted outcome
 *   step 4: confirm-order      (no compensation — pre-confirmation only)
 *   step 5: complete-order     (no compensation — terminal)
 * </pre>
 *
 * <p>{@code orders} + {@code order_items} rows are inserted <em>before</em> the
 * flow is scheduled (see {@link ShopOrderFlowService#createOrder}). That keeps
 * the API contract identical to the pre-migration Axon shape — the 202
 * ACCEPTED response carries an {@code orderId} that already exists in the DB —
 * which is required to preserve fairness on the saga benchmark axis.
 *
 * <h2>Outcome semantics</h2>
 * <ul>
 *   <li>Success path: each step returns {@link FlowOutcome#CONTINUE} except the
 *       terminal {@code complete-order}, which returns {@link FlowOutcome#COMPLETE}
 *       to short-circuit the engine to {@code FlowState.COMPLETED}.</li>
 *   <li>Parking path: {@code request-payment} dispatches to the external payment
 *       gateway, {@code await-payment} returns {@link FlowOutcome#PARK}
 *       (CONTRACT-v2 section 4), and the gateway's asynchronous callback wakes the
 *       flow. The wake lands on {@code settle-payment} — the step AFTER the parked
 *       one, because {@code beginScheduleAfterWake()} returns {@code currentStep + 1}
 *       — which is where the persisted outcome is read.</li>
 *   <li>Failure path: on wake, {@code settle-payment} returns {@link FlowOutcome#FAIL}
 *       when the gateway declined — the CONTRACT-v2 section 4.1 deterministic
 *       declined subset, evaluated in the gateway rather than here so a single
 *       implementation of the rule serves every stack. A decline is
 *       business-terminal — never retried (section 5) — and the kernel transitions
 *       to {@code COMPENSATING} and executes the compensations in reverse (LIFO)
 *       order — {@code refund-payment} for step 1, then {@code restore-inventory}
 *       for step 0. This is why step 1 returns CONTINUE rather than PARK:
 *       {@code applyParkOutcome} pushes no compensation, so parking there would drop
 *       {@code refund-payment} from the unwind.</li>
 * </ul>
 *
 * <h2>Lambda discipline</h2>
 * <p>Step lambdas capture {@code sqlSteps} and {@code inputRegistry} by
 * reference at definition time; both are Spring singletons and outlive any
 * in-flight flow instance. Per the {@code ExerisFlowDefinition} contract,
 * lambdas run on kernel-owned virtual threads under a {@code ScopedValue}
 * scope that is independent of the Spring request/application thread — no
 * thread-local context (security, transaction synchronization) is available
 * inside step bodies. The lifted SQL bodies are self-contained and do not need
 * any.
 */
@Component
public class ShopOrderFlowDefinition implements ExerisFlowDefinition {

    /** Stable identifier used to schedule the flow via {@code ExerisFlowTemplate.schedule}. */
    public static final String FLOW_NAME = "shop-order-fulfillment";

    private final ShopOrderSqlSteps sqlSteps;
    private final ShopOrderFlowInputRegistry inputRegistry;
    private final PaymentGatewayClient paymentGateway;

    public ShopOrderFlowDefinition(ShopOrderSqlSteps sqlSteps,
                                   ShopOrderFlowInputRegistry inputRegistry,
                                   PaymentGatewayClient paymentGateway) {
        this.sqlSteps = sqlSteps;
        this.inputRegistry = inputRegistry;
        this.paymentGateway = paymentGateway;
    }

    @Override
    public String name() {
        return FLOW_NAME;
    }

    @Override
    public FlowDefinition define(FlowDefinitionBuilder builder) {
        return builder
                .step(
                        "reserve-inventory",
                        ctx -> {
                            ShopOrderFlowInputRegistry.Input in = inputRegistry.require(ctx);
                            sqlSteps.reserveInventory(in.dbOrderId(), in.sagaId());
                            inputRegistry.recordStatus(in.orderId(), in.userId(), "INVENTORY_RESERVED", in.sagaId());
                            return FlowOutcome.CONTINUE;
                        },
                        ctx -> {
                            ShopOrderFlowInputRegistry.Input in = inputRegistry.require(ctx);
                            sqlSteps.restoreInventory(in.dbOrderId(), in.sagaId());
                            inputRegistry.recordStatus(in.orderId(), in.userId(), "CANCELLED", in.sagaId());
                            // Terminal compensation (runs last, in reverse order): the
                            // per-instance input binding is no longer needed once the saga
                            // has rolled all the way back. Drop it here to bound byInstance.
                            inputRegistry.drop(ShopOrderFlowInputRegistry.InstanceKey.of(ctx));
                            return FlowOutcome.CONTINUE;
                        })
                // CONTRACT-v2 section 4 (parking workload), three steps rather than one.
                //
                // WHY, established on the perf box 2026-08-18 and NOT by reading the SPI:
                // RuntimeFlowInstance.beginScheduleAfterWake() returns currentStep + 1, so a
                // woken flow resumes at the step AFTER the one that parked — it does NOT
                // re-enter it. A single step that parked and expected to re-read its own
                // persisted outcome had that read skipped entirely on wake, and a DECLINED
                // payment continued to confirm-order and completed successfully.
                //
                // request-payment must return CONTINUE, not PARK: applyParkOutcome does not
                // push a compensation, so parking here would silently drop refund-payment
                // from the LIFO unwind on a decline.
                .step(
                        "request-payment",
                        ctx -> {
                            ShopOrderFlowInputRegistry.Input in = inputRegistry.require(ctx);
                            sqlSteps.requestPayment(in.dbOrderId(), in.sagaId());
                            // Pre-migration projection wrote PAYMENT_PROCESSING for both
                            // PaymentProcessedEvent and PaymentFailedEvent. We preserve that
                            // surface; the compensation step transitions to PAYMENT_REFUNDED.
                            inputRegistry.recordStatus(in.orderId(), in.userId(), "PAYMENT_PROCESSING", in.sagaId());
                            paymentGateway.dispatch(in.orderId(), in.sagaId());
                            return FlowOutcome.CONTINUE;
                        },
                        ctx -> {
                            ShopOrderFlowInputRegistry.Input in = inputRegistry.require(ctx);
                            sqlSteps.refundPayment(in.dbOrderId(), in.sagaId());
                            inputRegistry.recordStatus(in.orderId(), in.userId(), "PAYMENT_REFUNDED", in.sagaId());
                            return FlowOutcome.CONTINUE;
                        })
                // await-payment: parks and does nothing else. The wake lands on the NEXT
                // step, which is why the decision cannot live here.
                .step("await-payment", ctx -> FlowOutcome.PARK, null)
                // settle-payment: the step the wake actually lands on, so the only place the
                // persisted outcome can be read.
                .step(
                        "settle-payment",
                        ctx -> {
                            ShopOrderFlowInputRegistry.Input in = inputRegistry.require(ctx);
                            String settled = sqlSteps.readPaymentOutcome(in.dbOrderId());
                            if (ShopOrderSqlSteps.PAYMENT_DECLINED.equals(settled)) {
                                // CONTRACT-v2 section 4.1 business-terminal decline: FAIL routes
                                // to kernel-driven LIFO compensation (refund-payment, then
                                // restore-inventory) and is never retried (section 5).
                                return FlowOutcome.FAIL;
                            }
                            if (ShopOrderSqlSteps.PAYMENT_AUTHORIZED.equals(settled)) {
                                return FlowOutcome.CONTINUE;
                            }
                            // Woken with no settled outcome: fail closed. Treating an unknown
                            // payment as authorised is the one failure mode this scenario must
                            // never have.
                            return FlowOutcome.FAIL;
                        },
                        null)
                .step(
                        "confirm-order",
                        ctx -> {
                            ShopOrderFlowInputRegistry.Input in = inputRegistry.require(ctx);
                            sqlSteps.confirmOrder(in.dbOrderId(), in.sagaId());
                            inputRegistry.recordStatus(in.orderId(), in.userId(), "CONFIRMED", in.sagaId());
                            return FlowOutcome.CONTINUE;
                        },
                        null)
                .step(
                        "complete-order",
                        ctx -> {
                            ShopOrderFlowInputRegistry.Input in = inputRegistry.require(ctx);
                            sqlSteps.completeOrder(in.dbOrderId(), in.sagaId());
                            inputRegistry.recordStatus(in.orderId(), in.userId(), "COMPLETED", in.sagaId());
                            // Terminal success step: the per-instance input binding has served
                            // its last require() and is no longer needed. Drop it here to bound
                            // byInstance (the status/idempotency projections intentionally
                            // outlive the flow — see ShopOrderFlowInputRegistry).
                            inputRegistry.drop(ShopOrderFlowInputRegistry.InstanceKey.of(ctx));
                            return FlowOutcome.COMPLETE;
                        },
                        null)
                .transition(0, 1)
                .transition(1, 2)
                .transition(2, 3)
                .transition(3, 4)
                .transition(4, 5)
                // CONTRACT-v2 section 5 transient-fault retry budget, configured explicitly
                // (defaults are not trusted): max 3 attempts total (1 initial + 2 retries)
                // -> maxRetries(2), which per the FlowDefinitionBuilder contract counts
                // step-level retries before backward compensation is triggered. Terminal
                // declines (section 4.1) return FlowOutcome.FAIL, which the kernel routes
                // straight to compensation — exempt from any retry budget (zero retries).
                .maxRetries(2)
                // TODO(CONTRACT-v2 section 5): the pinned backoff shape — exponential,
                // initial 50 ms, factor 2, NO jitter — is not expressible in
                // exeris-kernel-spi 0.5.0-SNAPSHOT: FlowDefinitionBuilder exposes only
                // maxRetries(int) and timeoutDuration(long), no backoff hook. Also note:
                // FlowDefinition.maxRetries is recorded in the definition, but the kernel
                // core flow runtime routes both FAIL and thrown step exceptions straight to
                // compensation without consulting it, so enforcement must be re-verified
                // when transient injection (section 4.2) lands. Configure the explicit
                // backoff here as soon as the SPI grows the API. Timeout stays at the
                // kernel default — section 5 pins retry policy only.
                .build();
    }
}
