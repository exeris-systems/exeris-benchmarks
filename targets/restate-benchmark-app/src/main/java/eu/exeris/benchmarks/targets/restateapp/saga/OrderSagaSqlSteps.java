package eu.exeris.benchmarks.targets.restateapp.saga;

import javax.sql.DataSource;
import java.nio.charset.StandardCharsets;
import java.sql.Connection;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.util.UUID;

/**
 * Per-step Postgres domain writes of the shop-order saga. SQL shapes are
 * bit-identical to the reference Axon stacks (spring-benchmark-app
 * InventoryService / PaymentService / OrderConfirmationService /
 * OrderCreationService) — CONTRACT-v2 §2 requires identical domain
 * persistence across stacks (same writes, same datastore, same schema).
 */
public final class OrderSagaSqlSteps {

    private static final String INSERT_ORDER_SQL =
            "INSERT INTO orders (user_id, status, saga_id) VALUES (?, 'SAGA_INITIATED', ?) RETURNING id";

    private static final String INSERT_ORDER_ITEMS_SQL =
            "INSERT INTO order_items (order_id, product_id, quantity, price) " +
            "SELECT ?, ci.product_id, ci.quantity, ci.price " +
            "FROM cart_items ci WHERE ci.cart_id = ?";

    private static final String RESERVE_INVENTORY_SQL =
            "UPDATE inventory " +
            "SET reserved = reserved + 1, quantity_available = quantity_available - 1 " +
            "WHERE product_id IN (SELECT product_id FROM order_items WHERE order_id = ?) " +
            "  AND quantity_available > 0";

    private static final String RESTORE_INVENTORY_SQL =
            "UPDATE inventory " +
            "SET reserved = GREATEST(reserved - 1, 0), quantity_available = quantity_available + 1 " +
            "WHERE product_id IN (SELECT product_id FROM order_items WHERE order_id = ?)";

    private static final String INSERT_OUTBOX_SQL =
            "INSERT INTO exeris_outbox (id, aggregate_id, aggregate_type, event_type, payload, occurred_at) " +
            "VALUES (?, ?, 'ORDER', ?, ?, ?)";

    private static final String UPDATE_ORDER_SQL =
            "UPDATE orders SET status = ?, updated_at = CURRENT_TIMESTAMP WHERE id = ?";

    private final DataSource dataSource;

    public OrderSagaSqlSteps(DataSource dataSource) {
        this.dataSource = dataSource;
    }

    /** Saga start: orders row + order_items copied from the cart (mirrors OrderCreationService.insertOrder). */
    public long insertOrder(String userId, String cartId, String sagaId) {
        try (Connection conn = dataSource.getConnection()) {
            long dbOrderId;
            try (PreparedStatement ps = conn.prepareStatement(INSERT_ORDER_SQL)) {
                ps.setLong(1, Long.parseLong(userId));
                ps.setString(2, sagaId);
                try (ResultSet rs = ps.executeQuery()) {
                    rs.next();
                    dbOrderId = rs.getLong(1);
                }
            }
            try (PreparedStatement ps = conn.prepareStatement(INSERT_ORDER_ITEMS_SQL)) {
                ps.setLong(1, dbOrderId);
                ps.setLong(2, Long.parseLong(cartId));
                ps.executeUpdate();
            }
            return dbOrderId;
        } catch (Exception e) {
            throw new RuntimeException("insertOrder failed for saga " + sagaId, e);
        }
    }

    /** Forward RESERVE_INVENTORY (mirrors InventoryService ReserveInventoryCommand). */
    public void reserveInventory(long dbOrderId, String sagaId) {
        try (Connection conn = dataSource.getConnection()) {
            try (PreparedStatement ps = conn.prepareStatement(RESERVE_INVENTORY_SQL)) {
                ps.setLong(1, dbOrderId);
                ps.executeUpdate();
            }
            updateOrderStatus(conn, dbOrderId, "INVENTORY_RESERVED");
        } catch (Exception e) {
            throw new RuntimeException("reserveInventory failed for saga " + sagaId, e);
        }
    }

    /** Compensation for RESERVE_INVENTORY (mirrors InventoryService CompensateReservationCommand). */
    public void restoreInventory(long dbOrderId, String sagaId) {
        try (Connection conn = dataSource.getConnection()) {
            try (PreparedStatement ps = conn.prepareStatement(RESTORE_INVENTORY_SQL)) {
                ps.setLong(1, dbOrderId);
                ps.executeUpdate();
            }
            updateOrderStatus(conn, dbOrderId, "CANCELLED");
        } catch (Exception e) {
            throw new RuntimeException("compensateReservation failed for saga " + sagaId, e);
        }
    }

    /**
     * Forward CHARGE_PAYMENT writes (pivot step): PAYMENT_REQUESTED outbox row +
     * PAYMENT_PROCESSING status (mirrors PaymentService ProcessPaymentCommand).
     * The §4.1 decline check happens AFTER these writes, exactly like the
     * reference stacks (writes committed, then decline event / TerminalException).
     */
    public void requestPayment(long dbOrderId, String sagaId) {
        try (Connection conn = dataSource.getConnection()) {
            insertOutbox(conn, dbOrderId, "PAYMENT_REQUESTED");
            updateOrderStatus(conn, dbOrderId, "PAYMENT_PROCESSING");
        } catch (Exception e) {
            throw new RuntimeException("processPayment failed for saga " + sagaId, e);
        }
    }

    /** Compensation for CHARGE_PAYMENT (mirrors PaymentService CompensatePaymentCommand). */
    public void refundPayment(long dbOrderId, String sagaId) {
        try (Connection conn = dataSource.getConnection()) {
            updateOrderStatus(conn, dbOrderId, "PAYMENT_REFUNDED");
            insertOutbox(conn, dbOrderId, "ORDER_COMPENSATED");
        } catch (Exception e) {
            throw new RuntimeException("compensatePayment failed for saga " + sagaId, e);
        }
    }

    /** Forward CONFIRM_ORDER (mirrors OrderConfirmationService ConfirmOrderCommand). No compensation. */
    public void confirmOrder(long dbOrderId, String sagaId) {
        try (Connection conn = dataSource.getConnection()) {
            updateOrderStatus(conn, dbOrderId, "CONFIRMED");
            insertOutbox(conn, dbOrderId, "ORDER_CONFIRMED");
        } catch (Exception e) {
            throw new RuntimeException("confirmOrder failed for saga " + sagaId, e);
        }
    }

    /** Forward COMPLETE_ORDER (mirrors OrderConfirmationService CompleteOrderCommand). No compensation. */
    public void completeOrder(long dbOrderId, String sagaId) {
        try (Connection conn = dataSource.getConnection()) {
            updateOrderStatus(conn, dbOrderId, "COMPLETED");
        } catch (Exception e) {
            throw new RuntimeException("completeOrder failed for saga " + sagaId, e);
        }
    }

    private static void updateOrderStatus(Connection conn, long dbOrderId, String status) throws Exception {
        try (PreparedStatement ps = conn.prepareStatement(UPDATE_ORDER_SQL)) {
            ps.setString(1, status);
            ps.setLong(2, dbOrderId);
            ps.executeUpdate();
        }
    }

    private static void insertOutbox(Connection conn, long dbOrderId, String eventType) throws Exception {
        String payload = "{\"order_id\":" + dbOrderId + ",\"event\":\"" + eventType + "\"}";
        try (PreparedStatement ps = conn.prepareStatement(INSERT_OUTBOX_SQL)) {
            ps.setString(1, UUID.randomUUID().toString());
            ps.setString(2, String.valueOf(dbOrderId));
            ps.setString(3, eventType);
            ps.setBytes(4, payload.getBytes(StandardCharsets.UTF_8));
            ps.setLong(5, System.currentTimeMillis());
            ps.executeUpdate();
        }
    }
}
