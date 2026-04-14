package eu.exeris.benchmarks.targets.exeriscommunity.infrastructure.persistence;

import eu.exeris.benchmarks.targets.exeriscommunity.domain.shop.CartItemView;
import eu.exeris.kernel.spi.persistence.PersistenceStatement;
import eu.exeris.kernel.spi.persistence.QueryResult;
import eu.exeris.kernel.spi.persistence.TransactionalExecutor;
import java.util.List;

public final class OrderRepository {

    private static final String CREATE_ORDER_SQL =
        "INSERT INTO orders (user_id, status, saga_id) VALUES (?, 'SAGA_INITIATED', '') RETURNING id";

    private static final String INSERT_ORDER_ITEM_SQL =
        "INSERT INTO order_items (order_id, product_id, quantity, price) VALUES (?, ?, ?, CAST(? AS DECIMAL(10,2)))";

    private static final String UPDATE_SAGA_ID_SQL =
        "UPDATE orders SET saga_id = ? WHERE id = ?";

    private static final String UPDATE_ORDER_STATUS_SQL =
        "UPDATE orders SET status = ?, updated_at = CURRENT_TIMESTAMP WHERE id = ?";

    private static final String GET_ORDER_STATUS_SQL =
        "SELECT status FROM orders WHERE id = ?";

    private static final String GET_SAGA_ID_SQL =
        "SELECT saga_id FROM orders WHERE id = ?";

    private static final String FIND_ORDER_ID_BY_SAGA_SQL =
        "SELECT id FROM orders WHERE saga_id = ? LIMIT 1";

    private final TransactionalExecutor executor;

    public OrderRepository(TransactionalExecutor executor) {
        this.executor = executor;
    }

    public long createOrderWithItems(long userId, List<CartItemView> items) {
        long[] idHolder = {-1L};
        executor.executeManaged(conn -> {
            try (PersistenceStatement stmt = conn.prepare(CREATE_ORDER_SQL)) {
                stmt.bindLong(0, userId);
                try (QueryResult qr = stmt.executeQuery()) {
                    if (qr.next()) {
                        idHolder[0] = qr.row().getLong(0);
                    }
                }
            }
            if (idHolder[0] <= 0L) {
                throw new IllegalStateException("Failed to create order: generated order id was not resolved");
            }
            for (CartItemView item : items) {
                try (PersistenceStatement stmt = conn.prepare(INSERT_ORDER_ITEM_SQL)) {
                    stmt.bindLong(0, idHolder[0])
                        .bindLong(1, item.productId())
                        .bindInt(2, item.quantity())
                        .bindString(3, String.valueOf(item.price()))
                        .executeUpdate();
                }
            }
        });
        return idHolder[0];
    }

    public void updateSagaId(long orderId, String sagaId) {
        executor.executeManaged(conn -> {
            try (PersistenceStatement stmt = conn.prepare(UPDATE_SAGA_ID_SQL)) {
                stmt.bindString(0, sagaId).bindLong(1, orderId).executeUpdate();
            }
        });
    }

    public void updateOrderStatus(long orderId, String status) {
        executor.executeManaged(conn -> {
            try (PersistenceStatement stmt = conn.prepare(UPDATE_ORDER_STATUS_SQL)) {
                stmt.bindString(0, status).bindLong(1, orderId).executeUpdate();
            }
        });
    }

    public String getOrderStatus(long orderId) {
        return executor.query(conn -> {
            try (PersistenceStatement stmt = conn.prepare(GET_ORDER_STATUS_SQL)) {
                stmt.bindLong(0, orderId);
                try (QueryResult qr = stmt.executeQuery()) {
                    return qr.next() ? qr.row().getString(0) : null;
                }
            }
        });
    }

    public String getSagaId(long orderId) {
        return executor.query(conn -> {
            try (PersistenceStatement stmt = conn.prepare(GET_SAGA_ID_SQL)) {
                stmt.bindLong(0, orderId);
                try (QueryResult qr = stmt.executeQuery()) {
                    return qr.next() ? qr.row().getString(0) : null;
                }
            }
        });
    }

    public Long findOrderIdBySagaId(String sagaId) {
        return executor.query(conn -> {
            try (PersistenceStatement stmt = conn.prepare(FIND_ORDER_ID_BY_SAGA_SQL)) {
                stmt.bindString(0, sagaId);
                try (QueryResult qr = stmt.executeQuery()) {
                    return qr.next() ? qr.row().getLong(0) : null;
                }
            }
        });
    }

}
