package eu.exeris.benchmarks.targets.restateapp.application;

import eu.exeris.benchmarks.targets.restateapp.api.Dtos.ProductView;

import javax.sql.DataSource;
import java.math.BigDecimal;
import java.sql.Connection;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.util.ArrayList;
import java.util.List;

/**
 * Product hydration for the recommended-products endpoint — mirrors
 * spring-benchmark-app ProductCatalogService (graph ids first, plain catalog
 * fallback, in-memory fallback last so preflight succeeds on an empty seed).
 */
public final class ProductCatalogService {

    private static final List<ProductView> FALLBACK_PRODUCTS = List.of(
            new ProductView("1", "Product_1", new BigDecimal("19.99"), "Electronics"),
            new ProductView("2", "Product_2", new BigDecimal("29.99"), "Books"),
            new ProductView("3", "Product_3", new BigDecimal("39.99"), "Clothing"),
            new ProductView("4", "Product_4", new BigDecimal("49.99"), "Home"),
            new ProductView("5", "Product_5", new BigDecimal("59.99"), "Sports"),
            new ProductView("6", "Product_6", new BigDecimal("69.99"), "Electronics"),
            new ProductView("7", "Product_7", new BigDecimal("79.99"), "Books"),
            new ProductView("8", "Product_8", new BigDecimal("89.99"), "Clothing"),
            new ProductView("9", "Product_9", new BigDecimal("99.99"), "Home"),
            new ProductView("10", "Product_10", new BigDecimal("109.99"), "Sports")
    );

    private final DataSource dataSource;
    private final GraphShopService graphShopService;

    public ProductCatalogService(DataSource dataSource, GraphShopService graphShopService) {
        this.dataSource = dataSource;
        this.graphShopService = graphShopService;
    }

    public List<ProductView> recommendedProducts(long userId, int limit) {
        List<Long> graphIds = graphShopService.recommendedProductIds(userId, limit);
        if (!graphIds.isEmpty()) {
            List<ProductView> graphProducts = fetchProductsByIdsFromDb(graphIds, limit);
            if (!graphProducts.isEmpty()) {
                return graphProducts;
            }
        }
        List<ProductView> products = fetchProductsFromDb(limit);
        if (!products.isEmpty()) {
            return products;
        }
        int boundedLimit = Math.max(1, Math.min(limit, FALLBACK_PRODUCTS.size()));
        return FALLBACK_PRODUCTS.subList(0, boundedLimit);
    }

    private List<ProductView> fetchProductsFromDb(int limit) {
        List<ProductView> products = new ArrayList<>();
        String sql = "SELECT id, name, price, category FROM products ORDER BY id ASC LIMIT ?";
        try (Connection connection = dataSource.getConnection();
             PreparedStatement statement = connection.prepareStatement(sql)) {
            statement.setInt(1, Math.max(1, limit));
            try (ResultSet rs = statement.executeQuery()) {
                while (rs.next()) {
                    products.add(mapProduct(rs));
                }
            }
        } catch (Exception ignored) {
            return List.of();
        }
        return products;
    }

    private List<ProductView> fetchProductsByIdsFromDb(List<Long> ids, int limit) {
        if (ids.isEmpty()) {
            return List.of();
        }
        List<ProductView> products = new ArrayList<>();
        String sql = "SELECT id, name, price, category FROM products WHERE id = ANY (?) ORDER BY id ASC LIMIT ?";
        try (Connection connection = dataSource.getConnection();
             PreparedStatement statement = connection.prepareStatement(sql)) {
            statement.setArray(1, connection.createArrayOf("bigint", ids.toArray()));
            statement.setInt(2, Math.max(1, limit));
            try (ResultSet rs = statement.executeQuery()) {
                while (rs.next()) {
                    products.add(mapProduct(rs));
                }
            }
        } catch (Exception ignored) {
            return List.of();
        }
        return products;
    }

    private static ProductView mapProduct(ResultSet rs) throws Exception {
        return new ProductView(
                Long.toString(rs.getLong("id")),
                rs.getString("name"),
                rs.getBigDecimal("price"),
                rs.getString("category")
        );
    }
}
