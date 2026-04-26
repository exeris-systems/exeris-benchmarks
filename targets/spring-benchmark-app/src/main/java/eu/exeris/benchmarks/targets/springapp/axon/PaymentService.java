package eu.exeris.benchmarks.targets.springapp.application.axon;

import eu.exeris.benchmarks.targets.springapp.application.axon.command.CompensatePaymentCommand;
import eu.exeris.benchmarks.targets.springapp.application.axon.command.ProcessPaymentCommand;
import eu.exeris.benchmarks.targets.springapp.application.axon.event.PaymentCompensatedEvent;
import eu.exeris.benchmarks.targets.springapp.application.axon.event.PaymentFailedEvent;
import eu.exeris.benchmarks.targets.springapp.application.axon.event.PaymentProcessedEvent;

import org.axonframework.commandhandling.CommandHandler;
import org.axonframework.eventhandling.EventBus;
import org.axonframework.eventhandling.GenericEventMessage;
import org.springframework.stereotype.Component;

import javax.sql.DataSource;
import java.nio.charset.StandardCharsets;
import java.sql.Connection;
import java.sql.PreparedStatement;
import java.util.UUID;
import java.util.concurrent.ThreadLocalRandom;

@Component
public class PaymentService {

    private enum FailureMode { RANDOM_SEEDED, ALWAYS_FAIL, NEVER_FAIL }

    private static final String PAYMENT_FAIL_RATE_ENV = "EXERIS_SAGA_PAYMENT_FAIL_RATE";
    private static final String FAILURE_MODE_ENV = "EXERIS_SAGA_FAILURE_MODE";

    private static final String INSERT_OUTBOX_SQL =
            "INSERT INTO exeris_outbox (id, aggregate_id, aggregate_type, event_type, payload, occurred_at) " +
            "VALUES (?, ?, 'ORDER', ?, ?, ?)";

    private static final String UPDATE_ORDER_SQL =
            "UPDATE orders SET status = ?, updated_at = CURRENT_TIMESTAMP WHERE id = ?";

    private final DataSource dataSource;
    private final EventBus eventBus;
    private final double paymentFailureRate;
    private final FailureMode failureMode;

    public PaymentService(DataSource dataSource, EventBus eventBus) {
        this.dataSource = dataSource;
        this.eventBus = eventBus;
        this.paymentFailureRate = parseDoubleOrDefault(System.getenv(PAYMENT_FAIL_RATE_ENV), 0.03d);
        this.failureMode = parseFailureMode(System.getenv(FAILURE_MODE_ENV));
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
        if (shouldFailPayment()) {
            eventBus.publish(GenericEventMessage.asEventMessage(
                    new PaymentFailedEvent(cmd.sagaId(), cmd.orderId(), cmd.userId(), cmd.dbOrderId())));
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

    private boolean shouldFailPayment() {
        return switch (failureMode) {
            case ALWAYS_FAIL -> true;
            case NEVER_FAIL -> false;
            case RANDOM_SEEDED -> ThreadLocalRandom.current().nextDouble() < paymentFailureRate;
        };
    }

    private static double parseDoubleOrDefault(String value, double fallback) {
        if (value == null || value.isBlank()) return fallback;
        try { return Double.parseDouble(value.trim()); } catch (NumberFormatException e) { return fallback; }
    }

    private static FailureMode parseFailureMode(String value) {
        if (value == null || value.isBlank()) return FailureMode.RANDOM_SEEDED;
        try { return FailureMode.valueOf(value.trim().toUpperCase()); } catch (IllegalArgumentException e) { return FailureMode.RANDOM_SEEDED; }
    }
}
