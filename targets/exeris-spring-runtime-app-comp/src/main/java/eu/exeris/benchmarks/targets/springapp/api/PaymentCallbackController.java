package eu.exeris.benchmarks.targets.springapp.api;

import eu.exeris.benchmarks.targets.springapp.application.flow.ShopOrderFlowService;

import org.springframework.context.annotation.Lazy;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RestController;

import java.util.Map;

/**
 * CONTRACT-v2 §4 (parking workload): the external payment gateway settles a PARKED
 * flow here. Unauthenticated by design — a machine-to-machine callback from a
 * component of the §1 deployment unit, not a user-facing route. Every target treats
 * it the same way; putting this stack's auth filter on it would make it pay a
 * per-callback cost no other stack pays.
 */
/*
 * @Lazy on the flow dependency, added 2026-08-21 for exeris-spring-runtime 0.7.0.
 *
 * WHY: 0.7.0 introduces a bean cycle that 0.5.0-SNAPSHOT did not have, and the app sits in the
 * middle of it without doing anything unusual:
 *
 *   paymentCallbackController -> shopOrderFlowService -> exerisFlowTemplate
 *     -> exerisFlowEngineSupplier -> exerisRuntimeLifecycle -> exerisCompatDispatcher
 *     -> exerisSpringMvcBridge -> exerisHandlerMethodRegistry -> paymentCallbackController
 *
 * In compatibility mode the handler-method registry has to scan every @RestController to build
 * its dispatch table, and building that registry is a transitive dependency of the flow engine.
 * So ANY controller that also needs the flow engine closes the loop — which a payment-callback
 * controller inherently does, because settling a parked saga is its entire job. The application
 * fails to start: "Relying upon circular references is discouraged and they are prohibited by
 * default."
 *
 * WHY @Lazy RATHER THAN spring.main.allow-circular-references=true: the property is Spring's own
 * last resort and relaxes a global safety setting for the whole context, which would also hide
 * any future cycle this benchmark introduces itself. @Lazy is local, idiomatic, and breaks the
 * loop at exactly one edge — the controller is constructed without materialising the flow chain,
 * the registry gets its bean, and the flow service resolves on first call. It costs one proxy
 * hop on a path that is not on the measured request path.
 *
 * TO DECLARE under CONTRACT-v2 §9(a): this is a deviation from the stack's native idiom forced
 * by the host runtime's wiring, not a tuning choice, and it applies to spring-on-exeris only.
 */
@RestController
public class PaymentCallbackController {

    private final ShopOrderFlowService flowService;

    public PaymentCallbackController(@Lazy ShopOrderFlowService flowService) {
        this.flowService = flowService;
    }

    @PostMapping("/api/v1/payments/callback")
    public ResponseEntity<Map<String, Object>> settle(@RequestBody Map<String, Object> body) {
        String orderId = asString(body.get("order_id"));
        String sagaId = asString(body.get("saga_id"));
        String outcome = asString(body.get("outcome"));
        if (orderId == null || sagaId == null || outcome == null) {
            return ResponseEntity.badRequest()
                    .body(Map.of("error", "order_id, saga_id and outcome are required"));
        }
        boolean settled = flowService.settlePayment(sagaId, "AUTHORIZED".equalsIgnoreCase(outcome));
        // 200 either way: an unmatched callback is a duplicate, not a delivery failure,
        // and the gateway counts non-2xx as callbacks_failed. IGNORED keeps it visible
        // without inflating that counter.
        return ResponseEntity.ok(Map.of("order_id", orderId,
                "status", settled ? "SETTLED" : "IGNORED"));
    }

    private static String asString(Object value) {
        if (value == null) {
            return null;
        }
        String text = String.valueOf(value).trim();
        return text.isEmpty() ? null : text;
    }
}
