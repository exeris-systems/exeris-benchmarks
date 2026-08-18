package eu.exeris.benchmarks.targets.quarkusapp.axon;

import jakarta.enterprise.context.ApplicationScoped;
import jakarta.inject.Inject;
import jakarta.ws.rs.HeaderParam;
import jakarta.ws.rs.PUT;
import jakarta.ws.rs.Path;
import jakarta.ws.rs.core.Response;

import org.eclipse.microprofile.lra.annotation.Compensate;
import org.eclipse.microprofile.lra.annotation.Complete;
import org.eclipse.microprofile.lra.annotation.ParticipantStatus;
import org.eclipse.microprofile.lra.annotation.Status;
import org.eclipse.microprofile.lra.annotation.ws.rs.LRA;
import org.jboss.logging.Logger;

import java.net.URI;

/**
 * CONTRACT-v2 §9(a): this arm's saga engine is MicroProfile LRA, and the saga is
 * enrolled as a <strong>single participant</strong>.
 *
 * <h2>Why one participant and not one per step</h2>
 *
 * The MicroProfile LRA specification guarantees no ordering across participants — from
 * its own {@code @Compensate} javadoc: <em>"The LRA specification makes no guarantees
 * about when Compensate method will be invoked, just that it will eventually be
 * called."</em> CONTRACT-v2 §2 requires LIFO unwinding. Enrolling one participant per
 * step would therefore leave the ordering to the coordinator, which the spec does not
 * promise and which we did not measure; enrolling ONE participant and unwinding inside
 * it puts LIFO back under our control, satisfied by construction.
 *
 * <p><strong>This must never be described as "full LRA".</strong> It uses LRA as a
 * durable saga <em>envelope</em>: the coordinator persists which LRAs are open and who
 * is enrolled, and drives {@link #compensate}/{@link #complete} afterwards — including
 * after this JVM restarts, which is the whole reason the arm has an engine at all. It
 * does not use LRA's multi-participant choreography. Registered in §9(a); the
 * extension's support level (<em>preview</em>) goes into the reproducibility metadata.
 *
 * <h2>Why the LRA id lives on the orders row</h2>
 *
 * The coordinator hands back only the LRA id when it calls compensate/complete, and it
 * may do so after a restart. A heap map would work right up to the crash it exists to
 * survive.
 */
@ApplicationScoped
@Path("/api/v1/lra/order-saga")
public class OrderSagaLraParticipant {

    private static final Logger LOG = Logger.getLogger(OrderSagaLraParticipant.class);

    @Inject
    OrderSagaStepService stepService;

    @Inject
    OrderSagaRetryPolicy retryPolicy;

    /**
     * Backward recovery. Invoked by the coordinator when the LRA is cancelled — which
     * this arm does on a §4.1 decline, and which the coordinator also does on its own
     * after a restart for LRAs left open.
     *
     * <p>The unwind order is LIFO and is decided HERE, in application code:
     * refund-payment, then restore-inventory. That is the same order the Axon and
     * Restate arms produce, and it is not delegated to the coordinator for the reason
     * in the class javadoc.
     */
    @PUT
    @Path("/compensate")
    @Compensate
    public Response compensate(@HeaderParam(LRA.LRA_HTTP_CONTEXT_HEADER) URI lraId) {
        Long dbOrderId = stepService.findOrderIdByLraId(lraId.toString());
        if (dbOrderId == null) {
            // Nothing to unwind that we can identify. Reporting Compensated rather than
            // FailedToCompensate on purpose: the coordinator would otherwise retry
            // forever against an order this process cannot resolve, and a stuck
            // coordinator is harder to notice than a logged orphan.
            LOG.warnf("LRA %s cancelled but no order row carries it; nothing to compensate.", lraId);
            return Response.ok(ParticipantStatus.Compensated.name()).build();
        }
        try {
            retryPolicy.run("compensate-payment", () -> stepService.compensatePayment(dbOrderId));
            retryPolicy.run("compensate-reservation", () -> stepService.compensateReservation(dbOrderId));
        } catch (OrderSagaRetryPolicy.RetryExhaustedException exhausted) {
            // CONTRACT-v2 §5: compensation retry-budget exhaustion is FAILED_UNRECOVERED
            // and is counted separately (§7 O3), never silently swallowed.
            stepService.markOrderFailed(dbOrderId);
            LOG.errorf(exhausted, "LRA %s compensation exhausted its retry budget for order %d", lraId, dbOrderId);
            return Response.ok(ParticipantStatus.FailedToCompensate.name()).build();
        }
        return Response.ok(ParticipantStatus.Compensated.name()).build();
    }

    /**
     * Forward completion. The forward steps already ran on the callback path, so this
     * is the coordinator's acknowledgement rather than more work — kept explicit
     * because a participant without {@code @Complete} cannot report its state, and a
     * saga whose completion is unobservable is not one this contract can gate.
     */
    @PUT
    @Path("/complete")
    @Complete
    public Response complete(@HeaderParam(LRA.LRA_HTTP_CONTEXT_HEADER) URI lraId) {
        return Response.ok(ParticipantStatus.Completed.name()).build();
    }

    @PUT
    @Path("/status")
    @Status
    public Response status(@HeaderParam(LRA.LRA_HTTP_CONTEXT_HEADER) URI lraId) {
        Long dbOrderId = stepService.findOrderIdByLraId(lraId.toString());
        if (dbOrderId == null) {
            return Response.ok(ParticipantStatus.Active.name()).build();
        }
        String orderStatus = stepService.readOrderStatus(dbOrderId);
        if ("CANCELLED".equals(orderStatus) || "PAYMENT_REFUNDED".equals(orderStatus)) {
            return Response.ok(ParticipantStatus.Compensated.name()).build();
        }
        if ("FAILED".equals(orderStatus)) {
            return Response.ok(ParticipantStatus.FailedToCompensate.name()).build();
        }
        if ("COMPLETED".equals(orderStatus)) {
            return Response.ok(ParticipantStatus.Completed.name()).build();
        }
        return Response.ok(ParticipantStatus.Active.name()).build();
    }
}
