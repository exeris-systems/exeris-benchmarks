package eu.exeris.benchmarks.targets.quarkusapp.controller;

import eu.exeris.benchmarks.targets.quarkusapp.axon.AxonOrderSagaService;

import io.smallrye.common.annotation.RunOnVirtualThread;
import jakarta.inject.Inject;
import jakarta.ws.rs.Consumes;
import jakarta.ws.rs.POST;
import jakarta.ws.rs.Path;
import jakarta.ws.rs.Produces;
import jakarta.ws.rs.core.MediaType;
import jakarta.ws.rs.core.Response;

import java.util.Map;

/**
 * CONTRACT-v2 §4 (parking workload): the external payment gateway settles a PARKED
 * saga here. Unauthenticated by design — a machine-to-machine callback from a
 * component of the §1 deployment unit, not a user-facing route. Every target treats
 * it the same way; putting this stack's auth path on it would make it pay a
 * per-callback cost no other stack pays.
 */
@Path("/api/v1/payments")
@Produces(MediaType.APPLICATION_JSON)
@Consumes(MediaType.APPLICATION_JSON)
@RunOnVirtualThread
public class PaymentCallbackResource {

    @Inject
    AxonOrderSagaService axonOrderSagaService;

    @POST
    @Path("/callback")
    public Response settle(Map<String, Object> body) {
        String orderId = asString(body == null ? null : body.get("order_id"));
        String sagaId = asString(body == null ? null : body.get("saga_id"));
        String outcome = asString(body == null ? null : body.get("outcome"));
        if (orderId == null || sagaId == null || outcome == null) {
            return Response.status(Response.Status.BAD_REQUEST)
                    .entity(Map.of("error", "order_id, saga_id and outcome are required"))
                    .build();
        }
        boolean authorized = "AUTHORIZED".equalsIgnoreCase(outcome);
        boolean settled = axonOrderSagaService.settlePayment(orderId, sagaId, authorized);
        // 200 either way: an unmatched callback is a duplicate, not a delivery failure,
        // and the gateway counts non-2xx as callbacks_failed. IGNORED keeps it visible
        // without inflating that counter.
        return Response.ok(Map.of("order_id", orderId,
                        "status", settled ? "SETTLED" : "IGNORED"))
                .build();
    }

    private static String asString(Object value) {
        if (value == null) {
            return null;
        }
        String text = String.valueOf(value).trim();
        return text.isEmpty() ? null : text;
    }
}
