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

    private static final String SELECT_ORDER_STATUS_SQL =
            "SELECT status FROM orders WHERE id = ?";

    private static final String SETTLE_PARKED_PAYMENT_SQL =
            "UPDATE orders SET status = ?, updated_at = CURRENT_TIMESTAMP "
            + "WHERE saga_id = ? AND status = 'PAYMENT_PROCESSING' "
            + "RETURNING id";

    /** Terminal outcomes of the external payment gateway, persisted on the order row. */
    public static final String PAYMENT_AUTHORIZED = "PAYMENT_AUTHORIZED";
    public static final String PAYMENT_DECLINED = "PAYMENT_DECLINED";

    private final DataSource dataSource;

    public ShopOrderSqlSteps(DataSource dataSource) {
        this.dataSource = dataSource;
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
     * Flow step 1 forward, first half: commit the payment-requested writes and
     * transition the order to {@code PAYMENT_PROCESSING}. The outcome is NOT
     * decided here — under the CONTRACT-v2 §4 parking workload the step dispatches
     * to the external payment gateway and returns {@code FlowOutcome.PARK}; the
     * gateway's callback settles it.
     *
     * <p>{@code PAYMENT_PROCESSING} is precisely the state
     * {@link #settleParkedPayment} compare-and-sets on, so these writes must
     * commit before the dispatch — at ~1 ms of configured gateway delay a callback
     * racing ahead of them is not hypothetical.
     */
    public void requestPayment(long dbOrderId, String sagaId) {
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
            throw new RuntimeException("requestPayment failed for saga " + sagaId, e);
        }
    }

    /**
     * Reads the settled payment outcome for an order, or {@code null} when it has
     * not settled yet.
     *
     * <p>Deliberately a DB read rather than a memory lookup: the flow step
     * re-enters on wake (and on cross-restart resumption from the snapshot store),
     * and it must see an outcome that survived the crash. An in-memory outcome
     * would be lost, and the resumed step would re-dispatch to a gateway that has
     * already answered — parking forever.
     */
    public String readPaymentOutcome(long dbOrderId) {
        try (Connection conn = dataSource.getConnection();
             PreparedStatement ps = conn.prepareStatement(SELECT_ORDER_STATUS_SQL)) {
            ps.setLong(1, dbOrderId);
            try (ResultSet rs = ps.executeQuery()) {
                if (rs.next()) {
                    String status = rs.getString(1);
                    if (PAYMENT_AUTHORIZED.equals(status) || PAYMENT_DECLINED.equals(status)) {
                        return status;
                    }
                }
            }
        } catch (Exception e) {
            throw new RuntimeException("readPaymentOutcome failed for order " + dbOrderId, e);
        }
        return null;
    }

    /**
     * Claims a parked payment and resolves the saga's order row in one statement.
     *
     * <p>Compare-and-set rather than SELECT-then-UPDATE: a duplicate callback
     * matches no row and returns empty, so it can never wake the same flow twice.
     *
     * @return the db order id when this call claimed the settlement, empty when no
     *         saga was parked on payment under {@code sagaId}
     */
    public java.util.OptionalLong settleParkedPayment(String sagaId, boolean authorized) {
        try (Connection conn = dataSource.getConnection();
             PreparedStatement ps = conn.prepareStatement(SETTLE_PARKED_PAYMENT_SQL)) {
            ps.setString(1, authorized ? PAYMENT_AUTHORIZED : PAYMENT_DECLINED);
            ps.setString(2, sagaId);
            try (ResultSet rs = ps.executeQuery()) {
                return rs.next()
                        ? java.util.OptionalLong.of(rs.getLong(1))
                        : java.util.OptionalLong.empty();
            }
        } catch (Exception e) {
            throw new RuntimeException("settleParkedPayment failed for saga " + sagaId, e);
        }
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
