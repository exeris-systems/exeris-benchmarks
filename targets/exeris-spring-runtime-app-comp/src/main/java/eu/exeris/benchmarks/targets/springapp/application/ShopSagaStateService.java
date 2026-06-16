package eu.exeris.benchmarks.targets.springapp.application;

import eu.exeris.benchmarks.targets.springapp.api.CartItemView;
import eu.exeris.benchmarks.targets.springapp.api.CartView;

import org.springframework.stereotype.Service;

import javax.sql.DataSource;
import java.math.BigDecimal;
import java.sql.Connection;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.util.ArrayList;
import java.util.List;

@Service
public class ShopSagaStateService {

    private static final String FIND_ACTIVE_CART_SQL =
        "SELECT id FROM carts WHERE user_id = ? AND status = 'ACTIVE' LIMIT 1";

    private static final String CREATE_CART_SQL =
        "INSERT INTO carts (user_id, status) VALUES (?, 'ACTIVE') RETURNING id";

    private static final String UPSERT_CART_ITEM_SQL =
        "INSERT INTO cart_items (cart_id, product_id, quantity, price) VALUES (?, ?, ?, ?) " +
        "ON CONFLICT (cart_id, product_id) DO UPDATE SET " +
        "quantity = cart_items.quantity + EXCLUDED.quantity, " +
        "price = EXCLUDED.price, " +
        "updated_at = CURRENT_TIMESTAMP";

    private static final String GET_PRODUCT_PRICE_SQL =
        "SELECT price FROM products WHERE id = ?";

    private static final String GET_CART_SQL =
        "SELECT c.id, ci.product_id, p.name, ci.quantity, ci.price " +
        "FROM carts c " +
        "JOIN cart_items ci ON c.id = ci.cart_id " +
        "JOIN products p ON ci.product_id = p.id " +
        "WHERE c.user_id = ? AND c.status = 'ACTIVE'";

    private static final String HAS_CART_SQL =
        "SELECT 1 FROM carts WHERE id = ? AND user_id = ? AND status = 'ACTIVE'";

    private final DataSource dataSource;
    private final GraphShopService graphShopService;

    public ShopSagaStateService(DataSource dataSource, GraphShopService graphShopService) {
        this.dataSource = dataSource;
        this.graphShopService = graphShopService;
    }

    public CartView addToCart(String userId, String productId, int quantity, ProductCatalogService ignored) {
        long uid = Long.parseLong(userId);
        long pid = Long.parseLong(productId);
        try (Connection conn = dataSource.getConnection()) {
            // Compat ExerisDataSource hands out autoCommit=false connections (kernel-managed
            // tx); raw-JDBC writes must commit explicitly or they roll back on close. Mirrors
            // AuthTokenService.register. On a plain autocommit DataSource this stays correct.
            conn.setAutoCommit(false);
            BigDecimal price = getProductPrice(conn, pid);
            long cartId = getOrCreateCartId(conn, uid);
            upsertCartItem(conn, cartId, pid, quantity, price);
            // Read the cart view inside the SAME write tx (it sees the just-written
            // item on this connection), THEN commit. Previously buildCartView ran
            // AFTER commit() — on the compat autoCommit=false connection that opened a
            // fresh implicit tx which was never committed (rolled back on close);
            // harmless for a SELECT but sloppy. Reading-before-commit is correct.
            CartView view = buildCartView(conn, uid);
            conn.commit();
            graphShopService.upsertCartEdge(uid, pid, quantity);
            return view;
        } catch (Exception e) {
            throw new RuntimeException("addToCart failed", e);
        }
    }

    public CartView getOrCreateCart(String userId, ProductCatalogService ignored) {
        long uid = Long.parseLong(userId);
        try (Connection conn = dataSource.getConnection()) {
            conn.setAutoCommit(false);
            getOrCreateCartId(conn, uid);
            // Read inside the same tx, before commit (see addToCart for why).
            CartView view = buildCartView(conn, uid);
            conn.commit();
            graphShopService.cartProductIds(uid);
            return view;
        } catch (Exception e) {
            throw new RuntimeException("getCart failed", e);
        }
    }

    public boolean hasCartForUser(String userId, String cartId) {
        try {
            long uid = Long.parseLong(userId);
            long cid = Long.parseLong(cartId);
            try (Connection conn = dataSource.getConnection();
                 PreparedStatement stmt = conn.prepareStatement(HAS_CART_SQL)) {
                stmt.setLong(1, cid);
                stmt.setLong(2, uid);
                try (ResultSet rs = stmt.executeQuery()) {
                    return rs.next();
                }
            }
        } catch (Exception e) {
            return false;
        }
    }

    private BigDecimal getProductPrice(Connection conn, long productId) throws Exception {
        try (PreparedStatement stmt = conn.prepareStatement(GET_PRODUCT_PRICE_SQL)) {
            stmt.setLong(1, productId);
            try (ResultSet rs = stmt.executeQuery()) {
                if (rs.next()) {
                    return rs.getBigDecimal(1);
                }
                return BigDecimal.ZERO;
            }
        }
    }

    private long getOrCreateCartId(Connection conn, long userId) throws Exception {
        try (PreparedStatement stmt = conn.prepareStatement(FIND_ACTIVE_CART_SQL)) {
            stmt.setLong(1, userId);
            try (ResultSet rs = stmt.executeQuery()) {
                if (rs.next()) {
                    return rs.getLong(1);
                }
            }
        }
        try (PreparedStatement stmt = conn.prepareStatement(CREATE_CART_SQL)) {
            stmt.setLong(1, userId);
            try (ResultSet rs = stmt.executeQuery()) {
                if (rs.next()) {
                    return rs.getLong(1);
                }
                throw new RuntimeException("Failed to create cart");
            }
        }
    }

    private void upsertCartItem(Connection conn, long cartId, long productId, int quantity, BigDecimal price) throws Exception {
        try (PreparedStatement stmt = conn.prepareStatement(UPSERT_CART_ITEM_SQL)) {
            stmt.setLong(1, cartId);
            stmt.setLong(2, productId);
            stmt.setInt(3, quantity);
            stmt.setBigDecimal(4, price);
            stmt.executeUpdate();
        }
    }

    private CartView buildCartView(Connection conn, long userId) throws Exception {
        List<CartItemView> items = new ArrayList<>();
        BigDecimal total = BigDecimal.ZERO;
        long cartId = -1L;
        try (PreparedStatement stmt = conn.prepareStatement(GET_CART_SQL)) {
            stmt.setLong(1, userId);
            try (ResultSet rs = stmt.executeQuery()) {
                while (rs.next()) {
                    cartId = rs.getLong(1);
                    String pid = Long.toString(rs.getLong(2));
                    int qty = rs.getInt(4);
                    BigDecimal price = rs.getBigDecimal(5);
                    items.add(new CartItemView(pid, qty, price));
                    total = total.add(price.multiply(BigDecimal.valueOf(qty)));
                }
            }
        }
        String cartIdStr = cartId > 0 ? Long.toString(cartId) : "0";
        return new CartView(cartIdStr, cartIdStr, Long.toString(userId), items, total);
    }
}
