package eu.exeris.benchmarks.targets.quarkusapp.axon;

import jakarta.enterprise.context.ApplicationScoped;
import jakarta.inject.Inject;

import javax.sql.DataSource;
import java.nio.charset.StandardCharsets;
import java.sql.Connection;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.util.UUID;
import java.util.concurrent.ThreadLocalRandom;

@ApplicationScoped
public class OrderSagaStepService {

    private enum FailureMode { RANDOM_SEEDED, ALWAYS_FAIL, NEVER_FAIL }

    private static final String PAYMENT_FAIL_RATE_ENV = "EXERIS_SAGA_PAYMENT_FAIL_RATE";
    private static final String FAILURE_MODE_ENV = "EXERIS_SAGA_FAILURE_MODE";

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

    private final double paymentFailureRate;
    private final FailureMode failureMode;

    public OrderSagaStepService() {
        this.paymentFailureRate = parseDoubleOrDefault(System.getenv(PAYMENT_FAIL_RATE_ENV), 0.03d);
        this.failureMode = parseFailureMode(System.getenv(FAILURE_MODE_ENV));
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

    public boolean processPayment(long dbOrderId, String paymentMethod) {
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
        return !shouldFailPayment();
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
