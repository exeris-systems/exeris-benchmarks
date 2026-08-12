package eu.exeris.benchmarks.targets.springapp.application.axon;

import eu.exeris.benchmarks.targets.springapp.application.axon.command.CompensateReservationCommand;
import eu.exeris.benchmarks.targets.springapp.application.axon.command.ReserveInventoryCommand;
import eu.exeris.benchmarks.targets.springapp.application.axon.event.InventoryReservedEvent;
import eu.exeris.benchmarks.targets.springapp.application.axon.event.ReservationCompensatedEvent;

import org.axonframework.commandhandling.CommandHandler;
import org.axonframework.eventhandling.EventBus;
import org.axonframework.eventhandling.GenericEventMessage;
import org.springframework.stereotype.Component;

import javax.sql.DataSource;
import java.sql.Connection;
import java.sql.PreparedStatement;

@Component
public class InventoryService {

    private static final String RESERVE_INVENTORY_SQL =
            "UPDATE inventory " +
            "SET reserved = reserved + 1, quantity_available = quantity_available - 1 " +
            "WHERE product_id IN (SELECT product_id FROM order_items WHERE order_id = ?) " +
            "  AND quantity_available > 0";

    private static final String RESTORE_INVENTORY_SQL =
            "UPDATE inventory " +
            "SET reserved = GREATEST(reserved - 1, 0), quantity_available = quantity_available + 1 " +
            "WHERE product_id IN (SELECT product_id FROM order_items WHERE order_id = ?)";

    private static final String UPDATE_ORDER_SQL =
            "UPDATE orders SET status = ?, updated_at = CURRENT_TIMESTAMP WHERE id = ?";

    private final DataSource dataSource;
    private final EventBus eventBus;

    public InventoryService(DataSource dataSource, EventBus eventBus) {
        this.dataSource = dataSource;
        this.eventBus = eventBus;
    }

    @CommandHandler
    public void handle(ReserveInventoryCommand cmd) {
        try (Connection conn = dataSource.getConnection()) {
            try (PreparedStatement ps = conn.prepareStatement(RESERVE_INVENTORY_SQL)) {
                ps.setLong(1, cmd.dbOrderId());
                ps.executeUpdate();
            }
            try (PreparedStatement ps = conn.prepareStatement(UPDATE_ORDER_SQL)) {
                ps.setString(1, "INVENTORY_RESERVED");
                ps.setLong(2, cmd.dbOrderId());
                ps.executeUpdate();
            }
        } catch (Exception e) {
            throw new RuntimeException("reserveInventory failed for saga " + cmd.sagaId(), e);
        }
        eventBus.publish(GenericEventMessage.asEventMessage(
                new InventoryReservedEvent(cmd.sagaId(), cmd.orderId(), cmd.userId(), cmd.dbOrderId())));
    }

    @CommandHandler
    public void handle(CompensateReservationCommand cmd) {
        try (Connection conn = dataSource.getConnection()) {
            try (PreparedStatement ps = conn.prepareStatement(RESTORE_INVENTORY_SQL)) {
                ps.setLong(1, cmd.dbOrderId());
                ps.executeUpdate();
            }
            try (PreparedStatement ps = conn.prepareStatement(UPDATE_ORDER_SQL)) {
                ps.setString(1, "CANCELLED");
                ps.setLong(2, cmd.dbOrderId());
                ps.executeUpdate();
            }
        } catch (Exception e) {
            throw new RuntimeException("compensateReservation failed for saga " + cmd.sagaId(), e);
        }
        eventBus.publish(GenericEventMessage.asEventMessage(
                new ReservationCompensatedEvent(cmd.sagaId(), cmd.orderId(), cmd.userId(), cmd.dbOrderId())));
    }
}
