package eu.exeris.benchmarks.targets.springapp.application.axon;

import eu.exeris.benchmarks.targets.springapp.application.axon.command.CompensatePaymentCommand;
import eu.exeris.benchmarks.targets.springapp.application.axon.command.ProcessPaymentCommand;
import eu.exeris.benchmarks.targets.springapp.application.axon.event.PaymentCompensatedEvent;

import org.axonframework.commandhandling.CommandHandler;
import org.axonframework.eventhandling.EventBus;
import org.axonframework.eventhandling.GenericEventMessage;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.stereotype.Component;

import javax.sql.DataSource;
import java.nio.charset.StandardCharsets;
import java.sql.Connection;
import java.sql.PreparedStatement;
import java.util.Locale;
import java.util.UUID;

@Component
public class PaymentService {

    /**
     * CONTRACT-v2 §4.1 fault mode: TERMINAL (default) applies the deterministic
     * FNV-1a decline rule; OFF disables business-fault injection entirely.
     */
    private enum FaultMode { TERMINAL, OFF }

    private static final Logger log = LoggerFactory.getLogger(PaymentService.class);

    private static final String FAULT_MODE_ENV = "EXERIS_SAGA_FAULT_MODE";
    // v1 probabilistic knobs — superseded by the CONTRACT-v2 §4.1 deterministic
    // per-orderId decline rule. Ignored; a WARN is logged when either is set.
    private static final String LEGACY_FAIL_RATE_ENV = "EXERIS_SAGA_PAYMENT_FAIL_RATE";
    private static final String LEGACY_FAILURE_MODE_ENV = "EXERIS_SAGA_FAILURE_MODE";

    private static final String INSERT_OUTBOX_SQL =
            "INSERT INTO exeris_outbox (id, aggregate_id, aggregate_type, event_type, payload, occurred_at) " +
            "VALUES (?, ?, 'ORDER', ?, ?, ?)";

    private static final String UPDATE_ORDER_SQL =
            "UPDATE orders SET status = ?, updated_at = CURRENT_TIMESTAMP WHERE id = ?";

    private final DataSource dataSource;
    private final EventBus eventBus;
    private final FaultMode faultMode;
    private final PaymentGatewayClient gateway;

    public PaymentService(DataSource dataSource, EventBus eventBus, PaymentGatewayClient gateway) {
        this.dataSource = dataSource;
        this.eventBus = eventBus;
        this.gateway = gateway;
        this.faultMode = parseFaultMode(System.getenv(FAULT_MODE_ENV));
        warnIfLegacyKnobSet(LEGACY_FAIL_RATE_ENV);
        warnIfLegacyKnobSet(LEGACY_FAILURE_MODE_ENV);
    }

    /**
     * CONTRACT-v2 §4 (parking workload): S_pay does not answer inline. It commits its
     * forward writes, dispatches to the external gateway, and publishes NOTHING — so
     * the Axon saga simply has no next event and sits in the saga store until the
     * gateway's callback publishes {@code PaymentProcessedEvent} or
     * {@code PaymentDeclinedEvent} (see {@code PaymentCallbackController}).
     *
     * <p>This is Axon's park: no thread, no connection and no request is held across
     * the wait — the saga instance is persisted state, and the tracking processor is
     * free to advance other sagas. It is also the idiomatic shape; the previous
     * inline decision was only possible because the workload had no external system
     * in it.
     */
    @CommandHandler
    public void handle(ProcessPaymentCommand cmd) {
        try (Connection conn = dataSource.getConnection()) {
            String payload = "{\"order_id\":" + cmd.dbOrderId() + ",\"event\":\"PAYMENT_REQUESTED\"}";
            try (PreparedStatement ps = conn.prepareStatement(INSERT_OUTBOX_SQL)) {
                ps.setString(1, UUID.randomUUID().toString());
                ps.setString(2, String.valueOf(cmd.dbOrderId()));
                ps.setString(3, "PAYMENT_REQUESTED");
                ps.setBytes(4, payload.getBytes(StandardCharsets.UTF_8));
                ps.setLong(5, System.currentTimeMillis());
                ps.executeUpdate();
            }
            try (PreparedStatement ps = conn.prepareStatement(UPDATE_ORDER_SQL)) {
                ps.setString(1, "PAYMENT_PROCESSING");
                ps.setLong(2, cmd.dbOrderId());
                ps.executeUpdate();
            }
        } catch (Exception e) {
            throw new RuntimeException("processPayment failed for saga " + cmd.sagaId(), e);
        }
        // The §4.1 decline decision now lives in the external gateway, bit-identical
        // (same FNV-1a constants, same modulus and threshold, same orderId key), so the
        // deterministic declined subset and the exact-compensation oracle are unchanged.
        // Deciding it here as well would be a second implementation of a rule that must
        // be identical everywhere — and the two could drift silently.
        //
        // faultMode is still parsed so a stale EXERIS_SAGA_FAULT_MODE is not read as
        // authoritative: for parking shapes the effective switch is the gateway's
        // PAYMENT_STUB_FAULT_MODE, and disagreement is worth a warning rather than a
        // silent divergence between what the operator set and what was injected.
        if (faultMode == FaultMode.OFF) {
            log.warn("{}=off has no effect in the parking workload: the CONTRACT-v2 §4.1 decline is "
                    + "decided by the external gateway. Set PAYMENT_STUB_FAULT_MODE=off instead.",
                    FAULT_MODE_ENV);
        }
        gateway.dispatch(cmd.orderId(), cmd.sagaId());
        // No event published: the saga parks here until the gateway calls back.
    }

    @CommandHandler
    public void handle(CompensatePaymentCommand cmd) {
        try (Connection conn = dataSource.getConnection()) {
            try (PreparedStatement ps = conn.prepareStatement(UPDATE_ORDER_SQL)) {
                ps.setString(1, "PAYMENT_REFUNDED");
                ps.setLong(2, cmd.dbOrderId());
                ps.executeUpdate();
            }
            String payload = "{\"order_id\":" + cmd.dbOrderId() + ",\"event\":\"ORDER_COMPENSATED\"}";
            try (PreparedStatement ps = conn.prepareStatement(INSERT_OUTBOX_SQL)) {
                ps.setString(1, UUID.randomUUID().toString());
                ps.setString(2, String.valueOf(cmd.dbOrderId()));
                ps.setString(3, "ORDER_COMPENSATED");
                ps.setBytes(4, payload.getBytes(StandardCharsets.UTF_8));
                ps.setLong(5, System.currentTimeMillis());
                ps.executeUpdate();
            }
        } catch (Exception e) {
            throw new RuntimeException("compensatePayment failed for saga " + cmd.sagaId(), e);
        }
        eventBus.publish(GenericEventMessage.asEventMessage(
                new PaymentCompensatedEvent(cmd.sagaId(), cmd.orderId(), cmd.userId(), cmd.dbOrderId())));
    }

    private static FaultMode parseFaultMode(String value) {
        if (value == null || value.isBlank()) return FaultMode.TERMINAL;
        try {
            return FaultMode.valueOf(value.trim().toUpperCase(Locale.ROOT));
        } catch (IllegalArgumentException e) {
            log.warn("{}='{}' not recognized (expected terminal|off) — defaulting to terminal", FAULT_MODE_ENV, value);
            return FaultMode.TERMINAL;
        }
    }

    private static void warnIfLegacyKnobSet(String envName) {
        if (System.getenv(envName) != null) {
            log.warn("{} is set but IGNORED: CONTRACT-v2 §4.1 replaced probabilistic payment failure with the "
                    + "deterministic FNV-1a per-orderId decline rule (control via {}=terminal|off)",
                    envName, FAULT_MODE_ENV);
        }
    }
}
