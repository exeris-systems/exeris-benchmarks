package eu.exeris.benchmarks.targets.quarkusapp.service;

import jakarta.enterprise.context.ApplicationScoped;
import jakarta.inject.Inject;

import eu.exeris.benchmarks.targets.quarkusapp.dto.ProductView;

import javax.sql.DataSource;
import java.math.BigDecimal;
import java.sql.Connection;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;

@ApplicationScoped
public class ProductCatalogService {

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

    @Inject
    DataSource dataSource;

    @Inject
    GraphShopService graphShopService;

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

    public Map<String, ProductView> byId(List<String> productIds) {
        if (productIds.isEmpty()) {
            return Map.of();
        }
        Map<String, ProductView> dbProducts = fetchProductsByIdFromDb(productIds);
        if (dbProducts.size() == productIds.size()) {
            return dbProducts;
        }
        Map<String, ProductView> resolved = new HashMap<>(dbProducts);
        Map<String, ProductView> fallbackById = new HashMap<>();
        for (ProductView product : FALLBACK_PRODUCTS) {
            fallbackById.put(product.id(), product);
        }
        for (String productId : productIds) {
            resolved.computeIfAbsent(productId, id -> fallbackById.getOrDefault(
                    id,
                    new ProductView(id, "Product_" + id, new BigDecimal("9.99"), "General")
            ));
        }
        return resolved;
    }

    private List<ProductView> fetchProductsFromDb(int limit) {
        List<ProductView> products = new ArrayList<>();
        String sql = "SELECT id, name, price, category FROM products ORDER BY id ASC LIMIT ?";
        try (Connection connection = dataSource.getConnection();
             PreparedStatement statement = connection.prepareStatement(sql)) {
            statement.setInt(1, Math.max(1, limit));
            try (ResultSet rs = statement.executeQuery()) {
                while (rs.next()) {
                    products.add(new ProductView(
                            Long.toString(rs.getLong("id")),
                            rs.getString("name"),
                            rs.getBigDecimal("price"),
                            rs.getString("category")
                    ));
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
        String sql = "SELECT id, name, price, category FROM products WHERE id = ANY (?) LIMIT ?";
        try (Connection connection = dataSource.getConnection();
             PreparedStatement statement = connection.prepareStatement(sql)) {
            statement.setArray(1, connection.createArrayOf("bigint", ids.toArray(new Long[0])));
            statement.setInt(2, Math.max(1, limit));
            try (ResultSet rs = statement.executeQuery()) {
                while (rs.next()) {
                    products.add(new ProductView(
                            Long.toString(rs.getLong("id")),
                            rs.getString("name"),
                            rs.getBigDecimal("price"),
                            rs.getString("category")
                    ));
                }
            }
        } catch (Exception ignored) {
            return List.of();
        }
        return products;
    }

    private Map<String, ProductView> fetchProductsByIdFromDb(List<String> productIds) {
        Map<String, ProductView> products = new HashMap<>();
        String sql = "SELECT id, name, price, category FROM products WHERE id = ANY (?)";
        try (Connection connection = dataSource.getConnection();
             PreparedStatement statement = connection.prepareStatement(sql)) {
            Long[] ids = new Long[productIds.size()];
            for (int index = 0; index < productIds.size(); index++) {
                ids[index] = Long.parseLong(productIds.get(index));
            }
            statement.setArray(1, connection.createArrayOf("bigint", ids));
            try (ResultSet rs = statement.executeQuery()) {
                while (rs.next()) {
                    ProductView product = new ProductView(
                            Long.toString(rs.getLong("id")),
                            rs.getString("name"),
                            rs.getBigDecimal("price"),
                            rs.getString("category")
                    );
                    products.put(product.id(), product);
                }
            }
        } catch (Exception ignored) {
            return Map.of();
        }
        return products;
    }
}