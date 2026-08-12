package eu.exeris.benchmarks.targets.springapp.application.axon;

import eu.exeris.benchmarks.targets.springapp.application.axon.command.CompleteOrderCommand;
import eu.exeris.benchmarks.targets.springapp.application.axon.command.ConfirmOrderCommand;
import eu.exeris.benchmarks.targets.springapp.application.axon.event.OrderConfirmedEvent;
import eu.exeris.benchmarks.targets.springapp.application.axon.event.OrderSagaCompletedEvent;

import org.axonframework.commandhandling.CommandHandler;
import org.axonframework.eventhandling.EventBus;
import org.axonframework.eventhandling.GenericEventMessage;
import org.springframework.stereotype.Component;

import javax.sql.DataSource;
import java.nio.charset.StandardCharsets;
import java.sql.Connection;
import java.sql.PreparedStatement;
import java.util.UUID;

@Component
public class OrderConfirmationService {

    private static final String INSERT_OUTBOX_SQL =
            "INSERT INTO exeris_outbox (id, aggregate_id, aggregate_type, event_type, payload, occurred_at) " +
            "VALUES (?, ?, 'ORDER', ?, ?, ?)";

    private static final String UPDATE_ORDER_SQL =
            "UPDATE orders SET status = ?, updated_at = CURRENT_TIMESTAMP WHERE id = ?";

    private final DataSource dataSource;
    private final EventBus eventBus;

    public OrderConfirmationService(DataSource dataSource, EventBus eventBus) {
        this.dataSource = dataSource;
        this.eventBus = eventBus;
    }

    @CommandHandler
    public void handle(ConfirmOrderCommand cmd) {
        try (Connection conn = dataSource.getConnection()) {
            try (PreparedStatement ps = conn.prepareStatement(UPDATE_ORDER_SQL)) {
                ps.setString(1, "CONFIRMED");
                ps.setLong(2, cmd.dbOrderId());
                ps.executeUpdate();
            }
            String payload = "{\"order_id\":" + cmd.dbOrderId() + ",\"event\":\"ORDER_CONFIRMED\"}";
            try (PreparedStatement ps = conn.prepareStatement(INSERT_OUTBOX_SQL)) {
                ps.setString(1, UUID.randomUUID().toString());
                ps.setString(2, String.valueOf(cmd.dbOrderId()));
                ps.setString(3, "ORDER_CONFIRMED");
                ps.setBytes(4, payload.getBytes(StandardCharsets.UTF_8));
                ps.setLong(5, System.currentTimeMillis());
                ps.executeUpdate();
            }
        } catch (Exception e) {
            throw new RuntimeException("confirmOrder failed for saga " + cmd.sagaId(), e);
        }
        eventBus.publish(GenericEventMessage.asEventMessage(
                new OrderConfirmedEvent(cmd.sagaId(), cmd.orderId(), cmd.userId(), cmd.dbOrderId())));
    }

    @CommandHandler
    public void handle(CompleteOrderCommand cmd) {
        try (Connection conn = dataSource.getConnection()) {
            try (PreparedStatement ps = conn.prepareStatement(UPDATE_ORDER_SQL)) {
                ps.setString(1, "COMPLETED");
                ps.setLong(2, cmd.dbOrderId());
                ps.executeUpdate();
            }
        } catch (Exception e) {
            throw new RuntimeException("completeOrder failed for saga " + cmd.sagaId(), e);
        }
        eventBus.publish(GenericEventMessage.asEventMessage(
                new OrderSagaCompletedEvent(cmd.orderId(), cmd.userId(), "", cmd.sagaId())));
    }
}
