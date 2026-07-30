package eu.exeris.benchmarks.targets.springapp.api;

import eu.exeris.benchmarks.targets.springapp.application.flow.ShopOrderFlowService;

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
@RestController
public class PaymentCallbackController {

    private final ShopOrderFlowService flowService;

    public PaymentCallbackController(ShopOrderFlowService flowService) {
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
