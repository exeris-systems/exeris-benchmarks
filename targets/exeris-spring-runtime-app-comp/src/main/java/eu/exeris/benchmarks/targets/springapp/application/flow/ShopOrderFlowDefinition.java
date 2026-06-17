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
 *   step 1: charge-payment     (compensation: refund-payment)
 *   step 2: confirm-order      (no compensation — pre-confirmation only)
 *   step 3: complete-order     (no compensation — terminal)
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
 *   <li>Failure path: {@code charge-payment} returns {@link FlowOutcome#FAIL}
 *       when {@link PaymentFailureSimulator#shouldFailOnce()} fires. The kernel
 *       transitions to {@code COMPENSATING} and executes the compensations in
 *       reverse order — {@code refund-payment} for step 1, then
 *       {@code restore-inventory} for step 0.</li>
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

    public ShopOrderFlowDefinition(ShopOrderSqlSteps sqlSteps, ShopOrderFlowInputRegistry inputRegistry) {
        this.sqlSteps = sqlSteps;
        this.inputRegistry = inputRegistry;
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
                .step(
                        "charge-payment",
                        ctx -> {
                            ShopOrderFlowInputRegistry.Input in = inputRegistry.require(ctx);
                            boolean ok = sqlSteps.chargePayment(in.dbOrderId(), in.sagaId());
                            // Pre-migration projection wrote PAYMENT_PROCESSING for both
                            // PaymentProcessedEvent and PaymentFailedEvent. We preserve that
                            // surface; the compensation step transitions to PAYMENT_REFUNDED.
                            inputRegistry.recordStatus(in.orderId(), in.userId(), "PAYMENT_PROCESSING", in.sagaId());
                            return ok ? FlowOutcome.CONTINUE : FlowOutcome.FAIL;
                        },
                        ctx -> {
                            ShopOrderFlowInputRegistry.Input in = inputRegistry.require(ctx);
                            sqlSteps.refundPayment(in.dbOrderId(), in.sagaId());
                            inputRegistry.recordStatus(in.orderId(), in.userId(), "PAYMENT_REFUNDED", in.sagaId());
                            return FlowOutcome.CONTINUE;
                        })
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
                // Bench scenario uses the kernel-default timeout/retry — the explicit
                // setters are intentionally omitted so observed numbers reflect the
                // out-of-the-box Community FlowEngine defaults rather than a tuned variant.
                .build();
    }
}
