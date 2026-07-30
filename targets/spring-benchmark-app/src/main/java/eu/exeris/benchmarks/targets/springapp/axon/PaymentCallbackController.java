package eu.exeris.benchmarks.targets.springapp.application.axon;

import eu.exeris.benchmarks.targets.springapp.application.axon.event.PaymentDeclinedEvent;
import eu.exeris.benchmarks.targets.springapp.application.axon.event.PaymentProcessedEvent;

import org.axonframework.eventhandling.EventBus;
import org.axonframework.eventhandling.GenericEventMessage;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RestController;

import javax.sql.DataSource;
import java.sql.Connection;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.util.Map;

/**
 * CONTRACT-v2 §4 (parking workload): the external payment gateway settles a PARKED
 * saga here. Unauthenticated by design — a machine-to-machine callback from a
 * component of the §1 deployment unit, not a user-facing route (permitted in
 * SecurityConfig alongside /health).
 *
 * <p>Lives in the {@code ...application.axon} package so it is component-scanned
 * only when {@code exeris.axon.enabled=true}: pure-read scenarios must not grow an
 * extra route.
 */
@RestController
public class PaymentCallbackController {

    private static final Logger log = LoggerFactory.getLogger(PaymentCallbackController.class);

    static final String PAYMENT_AUTHORIZED = "PAYMENT_AUTHORIZED";
    static final String PAYMENT_DECLINED = "PAYMENT_DECLINED";

    /**
     * Compare-and-set on the parked state: resolves the saga's order row AND claims
     * the settlement in one statement. A second callback for the same saga matches no
     * row and is ignored, so a duplicate can never drive the saga twice — which a
     * plain SELECT-then-publish would allow. The returned columns are what the saga
     * events need and the callback body does not carry.
     */
    private static final String SETTLE_PARKED_PAYMENT_SQL =
            "UPDATE orders SET status = ?, updated_at = CURRENT_TIMESTAMP "
            + "WHERE saga_id = ? AND status = 'PAYMENT_PROCESSING' "
            + "RETURNING id, user_id";

    private final DataSource dataSource;
    private final EventBus eventBus;

    public PaymentCallbackController(DataSource dataSource, EventBus eventBus) {
        this.dataSource = dataSource;
        this.eventBus = eventBus;
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
        boolean authorized = "AUTHORIZED".equalsIgnoreCase(outcome);

        long dbOrderId;
        long userId;
        try (Connection conn = dataSource.getConnection();
             PreparedStatement ps = conn.prepareStatement(SETTLE_PARKED_PAYMENT_SQL)) {
            ps.setString(1, authorized ? PAYMENT_AUTHORIZED : PAYMENT_DECLINED);
            ps.setString(2, sagaId);
            try (ResultSet rs = ps.executeQuery()) {
                if (!rs.next()) {
                    // No parked saga in this state: a duplicate callback, or one for a
                    // saga this process never had. Answered 200 so the gateway does not
                    // score it as a delivery failure — it is not one.
                    return ResponseEntity.ok(Map.of("order_id", orderId, "status", "IGNORED"));
                }
                dbOrderId = rs.getLong(1);
                userId = rs.getLong(2);
            }
        } catch (Exception e) {
            log.error("payment callback failed to settle saga {}", sagaId, e);
            return ResponseEntity.internalServerError()
                    .body(Map.of("order_id", orderId, "status", "ERROR"));
        }

        // Waking the park = publishing the event the saga has been waiting for.
        // CONTRACT-v2 §4.1: a decline is business-terminal, modeled as its own event and
        // never thrown, so it can never reach the §5 transient-retry path.
        if (authorized) {
            eventBus.publish(GenericEventMessage.asEventMessage(
                    new PaymentProcessedEvent(sagaId, orderId, String.valueOf(userId), dbOrderId)));
        } else {
            eventBus.publish(GenericEventMessage.asEventMessage(
                    new PaymentDeclinedEvent(sagaId, orderId, String.valueOf(userId), dbOrderId)));
        }
        return ResponseEntity.ok(Map.of("order_id", orderId, "status", "SETTLED"));
    }

    private static String asString(Object value) {
        if (value == null) {
            return null;
        }
        String text = String.valueOf(value).trim();
        return text.isEmpty() ? null : text;
    }
}
