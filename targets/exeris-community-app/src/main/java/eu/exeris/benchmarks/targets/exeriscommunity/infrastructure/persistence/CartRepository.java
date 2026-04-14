package eu.exeris.benchmarks.targets.exeriscommunity.infrastructure.persistence;

import eu.exeris.benchmarks.targets.exeriscommunity.domain.shop.CartItemView;
import eu.exeris.benchmarks.targets.exeriscommunity.domain.shop.CartView;
import eu.exeris.kernel.spi.persistence.PersistenceStatement;
import eu.exeris.kernel.spi.persistence.QueryResult;
import eu.exeris.kernel.spi.persistence.TransactionalExecutor;
import java.math.BigDecimal;
import java.util.ArrayList;
import java.util.List;

public final class CartRepository {

    private static final String FIND_ACTIVE_CART_SQL =
        "SELECT id FROM carts WHERE user_id = ? AND status = 'ACTIVE' LIMIT 1";

    private static final String CREATE_CART_SQL =
        "INSERT INTO carts (user_id, status) VALUES (?, 'ACTIVE') RETURNING id";

    private static final String ADD_ITEM_SQL =
        "INSERT INTO cart_items (cart_id, product_id, quantity, price) VALUES (?, ?, ?, CAST(? AS DECIMAL(10,2)))";

    private static final String UPSERT_ITEM_SQL =
        "INSERT INTO cart_items (cart_id, product_id, quantity, price) VALUES (?, ?, ?, CAST(? AS DECIMAL(10,2))) " +
        "ON CONFLICT (cart_id, product_id) DO UPDATE SET " +
        "quantity = cart_items.quantity + EXCLUDED.quantity, " +
        "price = EXCLUDED.price, " +
        "updated_at = CURRENT_TIMESTAMP";

    private static final String GET_CART_SQL =
        "SELECT c.id, ci.product_id, p.name, ci.quantity, ci.price " +
        "FROM carts c " +
        "JOIN cart_items ci ON c.id = ci.cart_id " +
        "JOIN products p ON ci.product_id = p.id " +
        "WHERE c.user_id = ? AND c.status = 'ACTIVE'";

    private static final String GET_PRODUCT_PRICE_SQL =
        "SELECT price FROM products WHERE id = ?";

    private final TransactionalExecutor executor;

    public CartRepository(TransactionalExecutor executor) {
        this.executor = executor;
    }

    public long getOrCreateCart(long userId) {
        Long existing = executor.query(conn -> {
            try (PersistenceStatement stmt = conn.prepare(FIND_ACTIVE_CART_SQL)) {
                stmt.bindLong(0, userId);
                try (QueryResult qr = stmt.executeQuery()) {
                    return qr.next() ? qr.row().getLong(0) : null;
                }
            }
        });
        if (existing != null) {
            return existing;
        }
        long[] idHolder = {-1L};
        executor.executeManaged(conn -> {
            try (PersistenceStatement stmt = conn.prepare(CREATE_CART_SQL)) {
                stmt.bindLong(0, userId);
                try (QueryResult qr = stmt.executeQuery()) {
                    if (qr.next()) {
                        idHolder[0] = qr.row().getLong(0);
                    }
                }
            }
        });
        return idHolder[0];
    }

    public void addItem(long cartId, long productId, int quantity, BigDecimal price) {
        executor.executeManaged(conn -> {
            try (PersistenceStatement stmt = conn.prepare(ADD_ITEM_SQL)) {
                stmt.bindLong(0, cartId)
                    .bindLong(1, productId)
                    .bindInt(2, quantity)
                    .bindString(3, price.toPlainString())
                    .executeUpdate();
            }
        });
    }

    public void addOrUpdateItem(long cartId, long productId, int quantity, BigDecimal price) {
        executor.executeManaged(conn -> {
            try (PersistenceStatement stmt = conn.prepare(UPSERT_ITEM_SQL)) {
                stmt.bindLong(0, cartId)
                    .bindLong(1, productId)
                    .bindInt(2, quantity)
                    .bindString(3, price.toPlainString())
                    .executeUpdate();
            }
        });
    }

    public CartView getCart(long userId) {
        return executor.query(conn -> {
            try (PersistenceStatement stmt = conn.prepare(GET_CART_SQL)) {
                stmt.bindLong(0, userId);
                try (QueryResult qr = stmt.executeQuery()) {
                    long cartId = -1L;
                    List<CartItemView> items = new ArrayList<>();
                    double total = 0.0;
                    while (qr.next()) {
                        if (cartId < 0) {
                            cartId = qr.row().getLong(0);
                        }
                        long productId    = qr.row().getLong(1);
                        String productName = qr.row().getString(2);
                        int quantity      = qr.row().getInt(3);
                        double price      = qr.row().getDouble(4);
                        items.add(new CartItemView(productId, productName, quantity, price));
                        total += price * quantity;
                    }
                    if (cartId < 0) {
                        // no active cart yet — return empty
                        long newCartId = getOrCreateCart(userId);
                        return new CartView(newCartId, List.of(), 0.0);
                    }
                    return new CartView(cartId, List.copyOf(items), total);
                }
            }
        });
    }

    public BigDecimal getProductPrice(long productId) {
        return executor.query(conn -> {
            try (PersistenceStatement stmt = conn.prepare(GET_PRODUCT_PRICE_SQL)) {
                stmt.bindLong(0, productId);
                try (QueryResult qr = stmt.executeQuery()) {
                    if (qr.next()) {
                        return new BigDecimal(qr.row().getString(0));
                    }
                    return BigDecimal.ZERO;
                }
            }
        });
    }
}
