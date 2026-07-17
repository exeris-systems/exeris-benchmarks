package eu.exeris.benchmarks.targets.springapp.application.flow;

import org.springframework.stereotype.Component;

import javax.sql.DataSource;
import java.nio.charset.StandardCharsets;
import java.sql.Connection;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.util.UUID;

/**
 * Side-effect bodies for the {@code shop-order-fulfillment} flow.
 *
 * <p>Every SQL string is lifted <em>verbatim</em> from the pre-migration Axon
 * services ({@code OrderCreationService}, {@code InventoryService},
 * {@code PaymentService}, {@code OrderConfirmationService}) to preserve workload
 * equivalence across the runtime swap. The status-string vocabulary
 * ({@code SAGA_INITIATED}, {@code INVENTORY_RESERVED}, {@code PAYMENT_PROCESSING},
 * {@code PAYMENT_REFUNDED}, {@code CANCELLED}, {@code CONFIRMED}, {@code COMPLETED})
 * matches what the prior projection wrote, so any downstream consumer
 * (k6/wrk validators, dashboards) reads identical status surfaces.
 *
 * <p>Calls run on the kernel-owned virtual thread that executes a {@code FlowStepAction}
 * lambda; the {@link DataSource} is the Spring-managed bean (HikariCP in the
 * baseline, {@code ExerisDataSource} adapter once the data-compat opt-in is set).
 * No Spring request scope is available inside the step body — see
 * {@code ExerisFlowDefinition} javadoc for the rationale.
 */
@Component
public class ShopOrderSqlSteps {

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
    private final PaymentFailureSimulator paymentFailureSimulator;

    public ShopOrderSqlSteps(DataSource dataSource, PaymentFailureSimulator paymentFailureSimulator) {
        this.dataSource = dataSource;
        this.paymentFailureSimulator = paymentFailureSimulator;
    }

    /**
     * Synchronously inserts {@code orders} + {@code order_items} and returns the
     * generated database order id. Called from
     * {@link ShopOrderFlowService#createOrder} (before the 202 response is returned)
     * so the API contract — "order row exists by the time the client receives
     * {@code OrderAcceptedView}" — matches the pre-migration Axon shape.
     */
    public long insertOrder(String userId, String cartId, String sagaId) {
        try (Connection conn = dataSource.getConnection()) {
            conn.setAutoCommit(false);
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
            conn.commit();
            return dbOrderId;
        } catch (Exception e) {
            throw new RuntimeException("insertOrder failed for saga " + sagaId, e);
        }
    }

    /**
     * Flow step 0 forward: reserve inventory and transition order status to
     * {@code INVENTORY_RESERVED}.
     */
    public void reserveInventory(long dbOrderId, String sagaId) {
        try (Connection conn = dataSource.getConnection()) {
            conn.setAutoCommit(false);
            try (PreparedStatement ps = conn.prepareStatement(RESERVE_INVENTORY_SQL)) {
                ps.setLong(1, dbOrderId);
                ps.executeUpdate();
            }
            try (PreparedStatement ps = conn.prepareStatement(UPDATE_ORDER_SQL)) {
                ps.setString(1, "INVENTORY_RESERVED");
                ps.setLong(2, dbOrderId);
                ps.executeUpdate();
            }
            conn.commit();
        } catch (Exception e) {
            throw new RuntimeException("reserveInventory failed for saga " + sagaId, e);
        }
    }

    /**
     * Flow step 1 forward: charge payment. Returns {@code true} on success
     * (status set to {@code PAYMENT_PROCESSING}) or {@code false} on a
     * CONTRACT-v2 section 4.1 deterministic decline (status stays
     * {@code PAYMENT_PROCESSING} but the lambda will return
     * {@code FlowOutcome.FAIL} to trigger reverse compensation). The decline is
     * selected per-{@code orderId} — the client-visible orderId string, hashed
     * by {@link PaymentFailureSimulator#shouldDecline} — never per-attempt, and
     * is business-terminal: zero retries (section 5).
     *
     * <p>The on-disk vocabulary ({@code PAYMENT_PROCESSING} on both success and
     * failure) matches the pre-migration projection — the kernel-side
     * compensation tracks the in-memory flow state independently of the
     * persisted {@code orders.status} column.
     */
    public boolean chargePayment(long dbOrderId, String orderId, String sagaId) {
        try (Connection conn = dataSource.getConnection()) {
            conn.setAutoCommit(false);
            String payload = "{\"order_id\":" + dbOrderId + ",\"event\":\"PAYMENT_REQUESTED\"}";
            try (PreparedStatement ps = conn.prepareStatement(INSERT_OUTBOX_SQL)) {
                ps.setString(1, UUID.randomUUID().toString());
                ps.setString(2, String.valueOf(dbOrderId));
                ps.setString(3, "PAYMENT_REQUESTED");
                ps.setBytes(4, payload.getBytes(StandardCharsets.UTF_8));
                ps.setLong(5, System.currentTimeMillis());
                ps.executeUpdate();
            }
            try (PreparedStatement ps = conn.prepareStatement(UPDATE_ORDER_SQL)) {
                ps.setString(1, "PAYMENT_PROCESSING");
                ps.setLong(2, dbOrderId);
                ps.executeUpdate();
            }
            conn.commit();
        } catch (Exception e) {
            throw new RuntimeException("chargePayment failed for saga " + sagaId, e);
        }
        return !paymentFailureSimulator.shouldDecline(orderId);
    }

    /**
     * Flow step 2 forward: write {@code ORDER_CONFIRMED} outbox row and set
     * {@code orders.status} to {@code CONFIRMED}.
     */
    public void confirmOrder(long dbOrderId, String sagaId) {
        try (Connection conn = dataSource.getConnection()) {
            conn.setAutoCommit(false);
            try (PreparedStatement ps = conn.prepareStatement(UPDATE_ORDER_SQL)) {
                ps.setString(1, "CONFIRMED");
                ps.setLong(2, dbOrderId);
                ps.executeUpdate();
            }
            String payload = "{\"order_id\":" + dbOrderId + ",\"event\":\"ORDER_CONFIRMED\"}";
            try (PreparedStatement ps = conn.prepareStatement(INSERT_OUTBOX_SQL)) {
                ps.setString(1, UUID.randomUUID().toString());
                ps.setString(2, String.valueOf(dbOrderId));
                ps.setString(3, "ORDER_CONFIRMED");
                ps.setBytes(4, payload.getBytes(StandardCharsets.UTF_8));
                ps.setLong(5, System.currentTimeMillis());
                ps.executeUpdate();
            }
            conn.commit();
        } catch (Exception e) {
            throw new RuntimeException("confirmOrder failed for saga " + sagaId, e);
        }
    }

    /**
     * Flow step 3 forward: set {@code orders.status} to {@code COMPLETED}.
     */
    public void completeOrder(long dbOrderId, String sagaId) {
        try (Connection conn = dataSource.getConnection()) {
            conn.setAutoCommit(false);
            try (PreparedStatement ps = conn.prepareStatement(UPDATE_ORDER_SQL)) {
                ps.setString(1, "COMPLETED");
                ps.setLong(2, dbOrderId);
                ps.executeUpdate();
            }
            conn.commit();
        } catch (Exception e) {
            throw new RuntimeException("completeOrder failed for saga " + sagaId, e);
        }
    }

    /**
     * Compensation for step 1 ({@code charge-payment}): set {@code orders.status}
     * to {@code PAYMENT_REFUNDED} and emit an {@code ORDER_COMPENSATED} outbox row.
     */
    public void refundPayment(long dbOrderId, String sagaId) {
        try (Connection conn = dataSource.getConnection()) {
            conn.setAutoCommit(false);
            try (PreparedStatement ps = conn.prepareStatement(UPDATE_ORDER_SQL)) {
                ps.setString(1, "PAYMENT_REFUNDED");
                ps.setLong(2, dbOrderId);
                ps.executeUpdate();
            }
            String payload = "{\"order_id\":" + dbOrderId + ",\"event\":\"ORDER_COMPENSATED\"}";
            try (PreparedStatement ps = conn.prepareStatement(INSERT_OUTBOX_SQL)) {
                ps.setString(1, UUID.randomUUID().toString());
                ps.setString(2, String.valueOf(dbOrderId));
                ps.setString(3, "ORDER_COMPENSATED");
                ps.setBytes(4, payload.getBytes(StandardCharsets.UTF_8));
                ps.setLong(5, System.currentTimeMillis());
                ps.executeUpdate();
            }
            conn.commit();
        } catch (Exception e) {
            throw new RuntimeException("refundPayment failed for saga " + sagaId, e);
        }
    }

    /**
     * Compensation for step 0 ({@code reserve-inventory}): restore inventory
     * counters and set {@code orders.status} to {@code CANCELLED}.
     */
    public void restoreInventory(long dbOrderId, String sagaId) {
        try (Connection conn = dataSource.getConnection()) {
            conn.setAutoCommit(false);
            try (PreparedStatement ps = conn.prepareStatement(RESTORE_INVENTORY_SQL)) {
                ps.setLong(1, dbOrderId);
                ps.executeUpdate();
            }
            try (PreparedStatement ps = conn.prepareStatement(UPDATE_ORDER_SQL)) {
                ps.setString(1, "CANCELLED");
                ps.setLong(2, dbOrderId);
                ps.executeUpdate();
            }
            conn.commit();
        } catch (Exception e) {
            throw new RuntimeException("restoreInventory failed for saga " + sagaId, e);
        }
    }
}
