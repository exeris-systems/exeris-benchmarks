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
                        return Optional.of(new OrderStatusView(orderId, toContractStatus(rs.getString(1)), rs.getString(2)));
                    }
                }
            }
        } catch (Exception e) {
            throw new RuntimeException("orderStatus query failed for orderId=" + orderId, e);
        }
        return Optional.empty();
    }

    /**
     * Maps raw {@code orders.status} values to the CONTRACT-v2 §3 outcome vocabulary
     * (COMPLETED | COMPENSATED | FAILED_UNRECOVERED) at the read layer only — the domain
     * writes stay untouched so they remain identical across stacks. In-progress statuses
     * pass through unchanged. PAYMENT_REFUNDED is deliberately NOT mapped to COMPENSATED:
     * it is a mid-compensation state (payment refunded, reservation restore pending), and
     * surfacing it as terminal would let a poller observe COMPENSATED that can later
     * regress to FAILED_UNRECOVERED if compensate-reservation exhausts its retry budget.
     */
    private static String toContractStatus(String dbStatus) {
        return switch (dbStatus) {
            case "CONFIRMED", "COMPLETED" -> "COMPLETED";
            case "CANCELLED" -> "COMPENSATED";
            case "PAYMENT_REFUNDED" -> "COMPENSATING";
            case "FAILED" -> "FAILED_UNRECOVERED";
            default -> dbStatus;
        };
    }
}
