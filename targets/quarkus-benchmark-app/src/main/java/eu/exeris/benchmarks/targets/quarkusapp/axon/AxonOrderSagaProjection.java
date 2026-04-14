package eu.exeris.benchmarks.targets.quarkusapp.axon;

import eu.exeris.benchmarks.targets.quarkusapp.dto.OrderStatusView;

import jakarta.enterprise.context.ApplicationScoped;
import jakarta.inject.Inject;

import javax.sql.DataSource;
import java.sql.Connection;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.util.Optional;

@ApplicationScoped
public class AxonOrderSagaProjection {

    private static final String SELECT_ORDER_STATUS_SQL =
            "SELECT status, saga_id FROM orders WHERE saga_id = ? AND user_id = ?";

    @Inject
    DataSource dataSource;

    public Optional<OrderStatusView> orderStatus(String userId, String orderId) {
        String sagaIdForQuery = "saga-" + orderId;
        try {
            long uid = Long.parseLong(userId);
            try (Connection conn = dataSource.getConnection();
                 PreparedStatement ps = conn.prepareStatement(SELECT_ORDER_STATUS_SQL)) {
                ps.setString(1, sagaIdForQuery);
                ps.setLong(2, uid);
                try (ResultSet rs = ps.executeQuery()) {
                    if (rs.next()) {
                        return Optional.of(new OrderStatusView(orderId, rs.getString(1), rs.getString(2)));
                    }
                }
            }
        } catch (Exception e) {
            throw new RuntimeException("orderStatus query failed for orderId=" + orderId, e);
        }
        return Optional.empty();
    }
}
