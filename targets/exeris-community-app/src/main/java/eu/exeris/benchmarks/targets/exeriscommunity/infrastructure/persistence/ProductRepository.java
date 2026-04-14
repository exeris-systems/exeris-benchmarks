package eu.exeris.benchmarks.targets.exeriscommunity.infrastructure.persistence;



import eu.exeris.benchmarks.targets.exeriscommunity.domain.shop.ProductView;
import eu.exeris.kernel.spi.persistence.PersistenceConnection;
import eu.exeris.kernel.spi.persistence.PersistenceStatement;
import eu.exeris.kernel.spi.persistence.QueryResult;
import eu.exeris.kernel.spi.persistence.TransactionalExecutor;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.UUID;

public final class ProductRepository {

    private static final String RECOMMENDED_WITH_HISTORY_SQL =
        "SELECT DISTINCT p.id, p.name, p.price, p.category " +
        "FROM products p " +
        "JOIN product_relationships pr " +
        "  ON (p.id = pr.target_product_id OR p.id = pr.source_product_id) " +
        "WHERE p.id IN (SELECT product_id FROM user_purchase_history WHERE user_id = ?) " +
        "LIMIT ?";

    private static final String FALLBACK_PRODUCTS_SQL =
        "SELECT id, name, price, category FROM products ORDER BY id ASC LIMIT ?";

    private static final String ALL_PRODUCT_IDS_SQL =
        "SELECT id FROM products ORDER BY id ASC";

    private final TransactionalExecutor executor;

    public ProductRepository(TransactionalExecutor executor) {
        this.executor = executor;
    }

    public List<ProductView> findRecommendedForUser(long userId, int limit) {
        RuntimeException primaryFailure = null;
        List<ProductView> results = null;
        try {
            results = executor.query(conn -> {
                try (PersistenceStatement stmt = conn.prepare(RECOMMENDED_WITH_HISTORY_SQL)) {
                    stmt.bindLong(0, userId).bindInt(1, limit);
                    try (QueryResult qr = stmt.executeQuery()) {
                        List<ProductView> list = new ArrayList<>();
                        while (qr.next()) {
                            list.add(mapProduct(qr.row()));
                        }
                        return list;
                    }
                }
            });
        } catch (RuntimeException ex) {
            primaryFailure = ex;
        }

        if (results != null && !results.isEmpty()) {
            return results;
        }

        try {
            return executor.query(conn -> {
                try (PersistenceStatement stmt = conn.prepare(FALLBACK_PRODUCTS_SQL)) {
                    stmt.bindInt(0, limit);
                    try (QueryResult qr = stmt.executeQuery()) {
                        List<ProductView> list = new ArrayList<>();
                        while (qr.next()) {
                            list.add(mapProduct(qr.row()));
                        }
                        return list;
                    }
                }
            });
        } catch (RuntimeException fallbackEx) {
            if (primaryFailure != null) {
                throw primaryFailure;
            }
            throw fallbackEx;
        }
    }

    public List<ProductView> findByIdsPreserveOrder(List<Long> ids, int limit) {
        if (ids == null || ids.isEmpty() || limit <= 0) {
            return List.of();
        }

        int boundedLimit = Math.min(ids.size(), limit);
        StringBuilder sql = new StringBuilder(
            "WITH requested(id, idx) AS (VALUES "
        );
        for (int i = 0; i < boundedLimit; i++) {
            if (i > 0) {
                sql.append(",");
            }
            sql.append(" (?, ?)");
        }
        sql.append(") ")
            .append("SELECT p.id, p.name, p.price, p.category ")
            .append("FROM requested r ")
            .append("JOIN products p ON p.id = r.id ")
            .append("ORDER BY r.idx ")
            .append("LIMIT ?");

        return executor.query(conn -> {
            try (PersistenceStatement stmt = conn.prepare(sql.toString())) {
                int bindIndex = 0;
                for (int i = 0; i < boundedLimit; i++) {
                    stmt.bindLong(bindIndex++, ids.get(i));
                    stmt.bindInt(bindIndex++, i);
                }
                stmt.bindInt(bindIndex, boundedLimit);
                try (QueryResult qr = stmt.executeQuery()) {
                    List<ProductView> list = new ArrayList<>();
                    while (qr.next()) {
                        list.add(mapProduct(qr.row()));
                    }
                    return list;
                }
            }
        });
    }

    public List<Long> resolveProductIdsFromGraphNodeIds(List<UUID> nodeIds, int limit) {
        if (nodeIds == null || nodeIds.isEmpty() || limit <= 0) {
            return List.of();
        }

        List<Long> candidates = executor.query(conn -> {
            try (PersistenceStatement stmt = conn.prepare(ALL_PRODUCT_IDS_SQL);
                 QueryResult qr = stmt.executeQuery()) {
                List<Long> list = new ArrayList<>();
                while (qr.next()) {
                    list.add(qr.row().getLong(0));
                }
                return list;
            }
        });

        if (candidates.isEmpty()) {
            return List.of();
        }

        Map<UUID, Long> nodeIdToProductId = new LinkedHashMap<>(candidates.size());
        for (Long productId : candidates) {
            UUID nodeId = UUID.nameUUIDFromBytes(("product-" + productId).getBytes(StandardCharsets.UTF_8));
            nodeIdToProductId.put(nodeId, productId);
        }

        Set<Long> resolvedInOrder = new LinkedHashSet<>();
        for (UUID nodeId : nodeIds) {
            Long productId = nodeIdToProductId.get(nodeId);
            if (productId != null) {
                resolvedInOrder.add(productId);
                if (resolvedInOrder.size() >= limit) {
                    break;
                }
            }
        }

        return List.copyOf(resolvedInOrder);
    }

    private static ProductView mapProduct(eu.exeris.kernel.spi.persistence.RowCursor row) {
        long id       = row.getLong(0);
        String name   = row.getString(1);
        double price  = row.getDouble(2);
        String cat    = row.getString(3);
        return new ProductView(id, name, price, cat);
    }
}
