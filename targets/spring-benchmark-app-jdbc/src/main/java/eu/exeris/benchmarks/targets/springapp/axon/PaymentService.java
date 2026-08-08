package eu.exeris.benchmarks.targets.springapp.application.axon;

import eu.exeris.benchmarks.targets.springapp.application.axon.command.CompensatePaymentCommand;
import eu.exeris.benchmarks.targets.springapp.application.axon.command.ProcessPaymentCommand;
import eu.exeris.benchmarks.targets.springapp.application.axon.event.PaymentCompensatedEvent;
import eu.exeris.benchmarks.targets.springapp.application.axon.event.PaymentDeclinedEvent;
import eu.exeris.benchmarks.targets.springapp.application.axon.event.PaymentProcessedEvent;

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

    public PaymentService(DataSource dataSource, EventBus eventBus) {
        this.dataSource = dataSource;
        this.eventBus = eventBus;
        this.faultMode = parseFaultMode(System.getenv(FAULT_MODE_ENV));
        warnIfLegacyKnobSet(LEGACY_FAIL_RATE_ENV);
        warnIfLegacyKnobSet(LEGACY_FAILURE_MODE_ENV);
    }

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
        // CONTRACT-v2 §4.1: deterministic per-orderId business decline. A decline is
        // BUSINESS-TERMINAL — published as an explicitly modeled event (never thrown),
        // so the command gateway's transient-fault retry scheduler (§5) can never see
        // it: zero retries on decline, routed straight to saga compensation.
        if (faultMode == FaultMode.TERMINAL && PaymentDeclineRule.isDeclined(cmd.orderId())) {
            eventBus.publish(GenericEventMessage.asEventMessage(
                    new PaymentDeclinedEvent(cmd.sagaId(), cmd.orderId(), cmd.userId(), cmd.dbOrderId())));
        } else {
            eventBus.publish(GenericEventMessage.asEventMessage(
                    new PaymentProcessedEvent(cmd.sagaId(), cmd.orderId(), cmd.userId(), cmd.dbOrderId())));
        }
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
