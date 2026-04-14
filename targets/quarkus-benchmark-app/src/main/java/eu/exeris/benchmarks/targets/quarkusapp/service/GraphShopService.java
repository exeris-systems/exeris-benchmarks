package eu.exeris.benchmarks.targets.quarkusapp.service;

import jakarta.annotation.PostConstruct;
import jakarta.annotation.PreDestroy;
import jakarta.enterprise.context.ApplicationScoped;
import jakarta.inject.Inject;

import org.eclipse.microprofile.config.inject.ConfigProperty;
import org.neo4j.driver.AuthTokens;
import org.neo4j.driver.Driver;
import org.neo4j.driver.GraphDatabase;
import org.neo4j.driver.Config;
import org.neo4j.driver.SessionConfig;

import javax.sql.DataSource;
import java.nio.charset.StandardCharsets;
import java.sql.Connection;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.util.ArrayList;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Optional;
import java.util.UUID;

/**
 * Graph-backed operations for the e2e-shop-order-saga scenario.
 *
 * Neo4j path (driver != null): Cypher queries against the seeded Neo4j instance.
 *
 * PGQ path (driver == null): SQL queries against in_cart_edges / bought_edges / similar_to_edges.
 *   Node identity: UUID.nameUUIDFromBytes("user-{id}" / "product-{id}" in UTF-8).
 *   Table names match Exeris Kernel CommunityGraphDialect: in_cart_edges, bought_edges, similar_to_edges.
 *   See runtime/db/seed/v4_pgq_graph.sql for DDL.
 */
@ApplicationScoped
public class GraphShopService {

    private static final String RECOMMEND_CYPHER =
            "MATCH (u:User {id: $uid})<-[:PURCHASED_BY]-(bought:Product)-[:SIMILAR_TO]->(rec:Product) " +
            "RETURN DISTINCT rec.id AS productId LIMIT $limit";

    private static final String CART_READ_CYPHER =
            "MATCH (u:User {id: $uid})-[:IN_CART]->(p:Product) RETURN p.id AS productId";

    private static final String CART_UPSERT_CYPHER =
            "MERGE (u:User {id: $uid}) " +
            "WITH u MATCH (p:Product {id: $pid}) " +
            "MERGE (u)-[r:IN_CART]->(p) SET r.quantity = $qty";

    private static final String PGQ_CART_READ_SQL =
            "SELECT target_id FROM in_cart_edges WHERE source_id = ?";

    private static final String PGQ_CART_UPSERT_SQL =
            "INSERT INTO in_cart_edges (source_id, target_id, weight, properties) " +
            "VALUES (?, ?, ?, ?::jsonb) " +
            "ON CONFLICT (source_id, target_id, tenant_id) " +
            "DO UPDATE SET weight = EXCLUDED.weight, properties = EXCLUDED.properties";

    private static final String PGQ_RECOMMEND_SQL =
            "SELECT DISTINCT (gn.properties->>'product_id')::BIGINT AS product_id " +
            "FROM bought_edges be " +
            "JOIN similar_to_edges se ON se.source_id = be.target_id " +
            "JOIN graph_nodes gn       ON gn.id        = se.target_id " +
            "WHERE be.source_id = ? " +
            "LIMIT ?";

    @ConfigProperty(name = "exeris.graph.backend.type", defaultValue = "pgq")
    String backendType;

    @ConfigProperty(name = "exeris.graph.neo4j.uri")
    Optional<String> neo4jUri;

    @ConfigProperty(name = "exeris.graph.neo4j.user")
    Optional<String> neo4jUser;

    @ConfigProperty(name = "exeris.graph.neo4j.password")
    Optional<String> neo4jPassword;

    @ConfigProperty(name = "exeris.graph.neo4j.database", defaultValue = "neo4j")
    String neo4jDatabase;

    @ConfigProperty(name = "exeris.graph.neo4j.pool.max-size", defaultValue = "100")
    int neo4jPoolMaxSize;

    @Inject
    DataSource dataSource;

    private Driver driver;

    @PostConstruct
    void init() {
        if (!"neo4j".equals(backendType.toLowerCase(Locale.ROOT))) {
            return;
        }
        String uri  = neo4jUri.filter(s -> !s.isBlank()).orElse(null);
        String user = neo4jUser.filter(s -> !s.isBlank()).orElse(null);
        String pass = neo4jPassword.filter(s -> !s.isBlank()).orElse(null);
        if (uri == null || user == null || pass == null) {
            throw new IllegalStateException(
                "exeris.graph.backend.type=neo4j but Neo4j connection config is incomplete " +
                "(neo4j.uri / neo4j.user / neo4j.password required)");
        }
        var neo4jConfig = Config.builder()
                .withMaxConnectionPoolSize(neo4jPoolMaxSize)
                .build();
        driver = GraphDatabase.driver(uri, AuthTokens.basic(user, pass), neo4jConfig);
    }

    @PreDestroy
    void close() {
        if (driver != null) {
            try { driver.close(); } catch (Exception ignored) {}
        }
    }

    public List<Long> recommendedProductIds(long userId, int limit) {
        if (driver != null) {
            try (var session = driver.session(SessionConfig.forDatabase(
                    neo4jDatabase == null || neo4jDatabase.isBlank() ? "neo4j" : neo4jDatabase))) {
                return session.run(RECOMMEND_CYPHER,
                                Map.<String, Object>of("uid", userId, "limit", limit))
                        .list(r -> r.get("productId").asLong());
            } catch (Exception ignored) {
                return List.of();
            }
        }
        List<Long> result = new ArrayList<>();
        try (Connection conn = dataSource.getConnection();
             PreparedStatement ps = conn.prepareStatement(PGQ_RECOMMEND_SQL)) {
            ps.setObject(1, userNodeId(userId));
            ps.setInt(2, limit);
            try (ResultSet rs = ps.executeQuery()) {
                while (rs.next()) {
                    result.add(rs.getLong("product_id"));
                }
            }
        } catch (Exception ignored) {
        }
        return result;
    }

    public List<Long> cartProductIds(long userId) {
        if (driver != null) {
            try (var session = driver.session(SessionConfig.forDatabase(
                    neo4jDatabase == null || neo4jDatabase.isBlank() ? "neo4j" : neo4jDatabase))) {
                return session.run(CART_READ_CYPHER,
                                Map.<String, Object>of("uid", userId))
                        .list(r -> r.get("productId").asLong());
            } catch (Exception ignored) {
                return List.of();
            }
        }
        try (Connection conn = dataSource.getConnection();
             PreparedStatement ps = conn.prepareStatement(PGQ_CART_READ_SQL)) {
            ps.setObject(1, userNodeId(userId));
            try (ResultSet rs = ps.executeQuery()) {
                while (rs.next()) { /* consume rows */ }
            }
        } catch (Exception ignored) {
        }
        return List.of();
    }

    public void upsertCartEdge(long userId, long productId, int quantity) {
        if (driver != null) {
            try (var session = driver.session(SessionConfig.forDatabase(
                    neo4jDatabase == null || neo4jDatabase.isBlank() ? "neo4j" : neo4jDatabase))) {
                session.run(CART_UPSERT_CYPHER,
                        Map.<String, Object>of("uid", userId, "pid", productId, "qty", quantity));
            } catch (Exception ignored) {}
            return;
        }
        try (Connection conn = dataSource.getConnection();
             PreparedStatement ps = conn.prepareStatement(PGQ_CART_UPSERT_SQL)) {
            ps.setObject(1, userNodeId(userId));
            ps.setObject(2, productNodeId(productId));
            ps.setDouble(3, quantity);
            ps.setString(4, "{\"quantity\":" + quantity + "}");
            ps.executeUpdate();
        } catch (Exception ignored) {
        }
    }

    private static UUID userNodeId(long userId) {
        return UUID.nameUUIDFromBytes(("user-" + userId).getBytes(StandardCharsets.UTF_8));
    }

    private static UUID productNodeId(long productId) {
        return UUID.nameUUIDFromBytes(("product-" + productId).getBytes(StandardCharsets.UTF_8));
    }
}
