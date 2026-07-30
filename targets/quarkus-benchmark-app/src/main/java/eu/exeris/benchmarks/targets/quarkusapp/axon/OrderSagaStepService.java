package eu.exeris.benchmarks.targets.quarkusapp.axon;

import jakarta.enterprise.context.ApplicationScoped;
import jakarta.inject.Inject;

import org.jboss.logging.Logger;

import javax.sql.DataSource;
import java.nio.charset.StandardCharsets;
import java.sql.Connection;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.util.UUID;

@ApplicationScoped
public class OrderSagaStepService {

    private static final Logger LOG = Logger.getLogger(OrderSagaStepService.class);

    /**
     * CONTRACT-v2 §4.1 fault mode: {@code terminal} (default) enables the deterministic
     * per-orderId business-terminal payment decline; {@code off} disables fault injection.
     */
    private enum FaultMode { TERMINAL, OFF }

    private static final String FAULT_MODE_ENV = "EXERIS_SAGA_FAULT_MODE";

    // Pre-v2 probabilistic knobs: ignored under CONTRACT-v2 §4.1, warned about at startup.
    private static final String LEGACY_PAYMENT_FAIL_RATE_ENV = "EXERIS_SAGA_PAYMENT_FAIL_RATE";
    private static final String LEGACY_FAILURE_MODE_ENV = "EXERIS_SAGA_FAILURE_MODE";

    // The CONTRACT-v2 §4.1 FNV-1a decline rule used to be evaluated here. Under the §4
    // parking workload it lives in the external payment gateway — bit-identical constants,
    // modulus and threshold, same orderId key — so the deterministic declined subset and
    // the exact-compensation oracle are unchanged. It is NOT duplicated here: two copies of
    // a rule that must be identical everywhere is a drift waiting to happen, and a local
    // copy that nothing consults would be dead code that looks load-bearing.

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

    private static final String SETTLE_PARKED_PAYMENT_SQL =
            "UPDATE orders SET status = ?, updated_at = CURRENT_TIMESTAMP "
            + "WHERE saga_id = ? AND status = 'PAYMENT_PROCESSING' "
            + "RETURNING id";

    @Inject
    DataSource dataSource;

    private final FaultMode faultMode;

    public OrderSagaStepService() {
        this.faultMode = parseFaultMode(System.getenv(FAULT_MODE_ENV));
        if (faultMode == FaultMode.OFF) {
            // Parsed only so a stale setting is not read as authoritative: for the §4
            // parking workload the effective switch is the gateway's
            // PAYMENT_STUB_FAULT_MODE. A knob that silently no-ops is worse than none.
            LOG.warnf("%s=off has no effect in the parking workload: the CONTRACT-v2 §4.1 decline is "
                    + "decided by the external gateway. Set PAYMENT_STUB_FAULT_MODE=off instead.",
                    FAULT_MODE_ENV);
        }
        warnIfLegacyKnobSet(LEGACY_PAYMENT_FAIL_RATE_ENV);
        warnIfLegacyKnobSet(LEGACY_FAILURE_MODE_ENV);
    }

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

    public void reserveInventory(long dbOrderId) {
        try (Connection conn = dataSource.getConnection()) {
            try (PreparedStatement ps = conn.prepareStatement(RESERVE_INVENTORY_SQL)) {
                ps.setLong(1, dbOrderId);
                ps.executeUpdate();
            }
            try (PreparedStatement ps = conn.prepareStatement(UPDATE_ORDER_SQL)) {
                ps.setString(1, "INVENTORY_RESERVED");
                ps.setLong(2, dbOrderId);
                ps.executeUpdate();
            }
        } catch (Exception e) {
            throw new RuntimeException("reserveInventory failed for order " + dbOrderId, e);
        }
    }

    /**
     * CONTRACT-v2 §4 (parking workload): the forward half of {@code charge-payment}.
     * Commits the payment-requested writes and returns; the outcome is NOT decided
     * here. The caller dispatches to the external gateway and parks the saga.
     *
     * <p>The writes precede the dispatch deliberately: the {@code PAYMENT_PROCESSING}
     * status is what {@link #settleParkedPayment} compare-and-sets on, so a callback
     * that arrives before this returns would find no parked row and be ignored. At
     * ~1 ms of configured gateway delay that race is not hypothetical.
     */
    public void requestPayment(long dbOrderId) {
        try (Connection conn = dataSource.getConnection()) {
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
        } catch (Exception e) {
            throw new RuntimeException("requestPayment failed for order " + dbOrderId, e);
        }
    }

    /**
     * Claims a parked payment and resolves the saga's order row in one statement.
     *
     * <p>Compare-and-set rather than SELECT-then-UPDATE: a duplicate callback matches
     * no row and returns empty, so it can never drive the saga's continuation twice.
     * The returned db order id is the only continuation state the callback needs,
     * which is why this stack keeps no in-memory map of in-flight sagas.
     *
     * @return the db order id when this call claimed the settlement, empty when there
     *         was no saga parked on payment under {@code sagaId}
     */
    public java.util.OptionalLong settleParkedPayment(String sagaId, boolean authorized) {
        try (Connection conn = dataSource.getConnection();
             PreparedStatement ps = conn.prepareStatement(SETTLE_PARKED_PAYMENT_SQL)) {
            ps.setString(1, authorized ? "PAYMENT_AUTHORIZED" : "PAYMENT_DECLINED");
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

    public void compensatePayment(long dbOrderId) {
        try (Connection conn = dataSource.getConnection()) {
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
        } catch (Exception e) {
            throw new RuntimeException("compensatePayment failed for order " + dbOrderId, e);
        }
    }

    public void compensateReservation(long dbOrderId) {
        try (Connection conn = dataSource.getConnection()) {
            try (PreparedStatement ps = conn.prepareStatement(RESTORE_INVENTORY_SQL)) {
                ps.setLong(1, dbOrderId);
                ps.executeUpdate();
            }
            try (PreparedStatement ps = conn.prepareStatement(UPDATE_ORDER_SQL)) {
                ps.setString(1, "CANCELLED");
                ps.setLong(2, dbOrderId);
                ps.executeUpdate();
            }
        } catch (Exception e) {
            throw new RuntimeException("compensateReservation failed for order " + dbOrderId, e);
        }
    }

    public void confirmOrder(long dbOrderId) {
        try (Connection conn = dataSource.getConnection()) {
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
        } catch (Exception e) {
            throw new RuntimeException("confirmOrder failed for order " + dbOrderId, e);
        }
    }

    public void completeOrder(long dbOrderId) {
        try (Connection conn = dataSource.getConnection()) {
            try (PreparedStatement ps = conn.prepareStatement(UPDATE_ORDER_SQL)) {
                ps.setString(1, "COMPLETED");
                ps.setLong(2, dbOrderId);
                ps.executeUpdate();
            }
        } catch (Exception e) {
            throw new RuntimeException("completeOrder failed for order " + dbOrderId, e);
        }
    }

    /**
     * Terminal CANCELLED write for the backward-recovery path with no inventory
     * reservation to restore (reserve-inventory retry-budget exhaustion): the order row
     * must still leave SAGA_INITIATED so the polled projection reaches a terminal
     * outcome (oracle G3).
     */
    public void cancelOrder(long dbOrderId) {
        try (Connection conn = dataSource.getConnection()) {
            try (PreparedStatement ps = conn.prepareStatement(UPDATE_ORDER_SQL)) {
                ps.setString(1, "CANCELLED");
                ps.setLong(2, dbOrderId);
                ps.executeUpdate();
            }
        } catch (Exception e) {
            throw new RuntimeException("cancelOrder failed for order " + dbOrderId, e);
        }
    }

    /**
     * Best-effort terminal FAILED write on compensation retry-budget exhaustion so the
     * polled projection surfaces FAILED_UNRECOVERED consistently with the synchronous
     * response. Never throws: the caller is already on the unrecovered path (§5) and the
     * FAILED_UNRECOVERED outcome must not be masked by a failing status write.
     */
    public void markOrderFailed(long dbOrderId) {
        try (Connection conn = dataSource.getConnection()) {
            try (PreparedStatement ps = conn.prepareStatement(UPDATE_ORDER_SQL)) {
                ps.setString(1, "FAILED");
                ps.setLong(2, dbOrderId);
                ps.executeUpdate();
            }
        } catch (Exception e) {
            LOG.errorf(e, "markOrderFailed could not persist FAILED for order %d; "
                    + "polled status may never reach FAILED_UNRECOVERED", dbOrderId);
        }
    }

    private static FaultMode parseFaultMode(String value) {
        if (value == null || value.isBlank()) return FaultMode.TERMINAL;
        try {
            return FaultMode.valueOf(value.trim().toUpperCase());
        } catch (IllegalArgumentException e) {
            LOG.warnf("Unknown %s value '%s'; defaulting to terminal (CONTRACT-v2 §4.1).",
                    FAULT_MODE_ENV, value);
            return FaultMode.TERMINAL;
        }
    }

    private static void warnIfLegacyKnobSet(String envName) {
        String value = System.getenv(envName);
        if (value != null && !value.isBlank()) {
            LOG.warnf("%s=%s is ignored: CONTRACT-v2 §4.1 replaced probabilistic payment failure with a "
                    + "deterministic per-orderId decline (FNV-1a-64 mod 1000 < 30). Use %s=terminal|off.",
                    envName, value, FAULT_MODE_ENV);
        }
    }
}
