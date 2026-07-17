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

    // FNV-1a 64-bit constants — normative in CONTRACT-v2 §4.1, identical in every stack.
    private static final long FNV1A64_OFFSET_BASIS = 0xcbf29ce484222325L;
    private static final long FNV1A64_PRIME = 0x100000001b3L;

    // decline(orderId) := Long.remainderUnsigned(fnv1a64(orderId), 1000) < 30 → exactly 3.0%.
    private static final long DECLINE_MODULUS = 1000L;
    private static final long DECLINE_THRESHOLD = 30L;

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

    @Inject
    DataSource dataSource;

    private final FaultMode faultMode;

    public OrderSagaStepService() {
        this.faultMode = parseFaultMode(System.getenv(FAULT_MODE_ENV));
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

    public boolean processPayment(long dbOrderId, String orderId, String paymentMethod) {
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
            throw new RuntimeException("processPayment failed for order " + dbOrderId, e);
        }
        // CONTRACT-v2 §4.1: deterministic per-orderId business-terminal decline. A decline is a
        // business outcome, not an infrastructure fault: it is returned, never thrown, so it can
        // never enter the §5 transient-retry path — zero retries on decline by construction.
        return !isPaymentDeclined(orderId);
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
     * CONTRACT-v2 §4.1 business-terminal decline selection — per-orderId, not per-attempt:
     * {@code decline(orderId) := Long.remainderUnsigned(fnv1a64(orderId), 1000) < 30}, i.e.
     * exactly 3.0% of the deterministic orderId population, identical subset in every stack
     * and every run.
     */
    public boolean isPaymentDeclined(String orderId) {
        return switch (faultMode) {
            case OFF -> false;
            case TERMINAL -> Long.remainderUnsigned(stableHash64(orderId), DECLINE_MODULUS) < DECLINE_THRESHOLD;
        };
    }

    /** FNV-1a 64-bit over the UTF-8 bytes of the orderId string, unsigned arithmetic. */
    private static long stableHash64(String orderId) {
        long hash = FNV1A64_OFFSET_BASIS;
        for (byte b : orderId.getBytes(StandardCharsets.UTF_8)) {
            hash ^= (b & 0xffL);
            hash *= FNV1A64_PRIME;
        }
        return hash;
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
