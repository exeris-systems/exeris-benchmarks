package eu.exeris.benchmarks.targets.springapp.application.axon;

import org.springframework.stereotype.Component;

import javax.sql.DataSource;
import java.sql.Connection;
import java.sql.PreparedStatement;
import java.sql.ResultSet;

@Component
public class OrderCreationService {

    private static final String INSERT_ORDER_SQL =
            "INSERT INTO orders (user_id, status, saga_id) VALUES (?, 'SAGA_INITIATED', ?) RETURNING id";

    private static final String INSERT_ORDER_ITEMS_SQL =
            "INSERT INTO order_items (order_id, product_id, quantity, price) " +
            "SELECT ?, ci.product_id, ci.quantity, ci.price " +
            "FROM cart_items ci WHERE ci.cart_id = ?";

    private final DataSource dataSource;

    public OrderCreationService(DataSource dataSource) {
        this.dataSource = dataSource;
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
}
