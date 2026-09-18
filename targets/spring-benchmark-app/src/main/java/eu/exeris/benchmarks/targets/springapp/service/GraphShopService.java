package eu.exeris.benchmarks.targets.springapp.application;

import org.neo4j.driver.Driver;
import org.springframework.beans.factory.ObjectProvider;
import org.springframework.stereotype.Component;

import javax.sql.DataSource;
import java.nio.charset.StandardCharsets;
import java.sql.Connection;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.UUID;

/**
 * Graph-backed operations for the e2e-shop-order-saga scenario.
 *
 * Neo4j path (driver != null): Cypher queries against the seeded Neo4j instance.
 *   (:User {id: UUID string, pg_id: Long})  (:Product {id: UUID string, pg_id: Long})
 *   (:User)-[:BOUGHT]->(:Product)
 *   (:Product)-[:SIMILAR_TO]->(:Product)
 *   (:User)-[:IN_CART {quantity}]->(:Product)
 *
 * PGQ path (driver == null): SQL queries against in_cart_edges / similar_to_edges / bought_edges.
 *   Node identity: UUID.nameUUIDFromBytes("user-{id}" / "product-{id}" in UTF-8).
 *   Table names match Exeris Kernel CommunityGraphDialect: in_cart_edges, bought_edges, similar_to_edges.
 *   See runtime/db/seed/v4_pgq_graph.sql for DDL.
 *
 * Mirrors Exeris Community GraphShopAdapter structurally for benchmark equivalence.
 */
@Component
public class GraphShopService {

    // CONTRACT-v2 §2 graph identity, changed 2026-07-31.
    //
    // Node key is the UUID nameUUIDFromBytes("user-"/"product-" + pgId), not the
    // Postgres integer, because the Exeris graph SPI is UUID-typed and its Neo4j
    // dialect parses every returned id with UUID.fromString — an integer-keyed graph
    // is literally unreadable from that stack. The PGQ track already used exactly
    // this identity (see the PGQ SQL below); it was only the Neo4j seed that had
    // diverged, so this converges two fixtures rather than bending one.
    //
    // The purchase edge is (:User)-[:BOUGHT]->(:Product) rather than the reverse
    // (:User)-[:BOUGHT]->(:Product) for the same reason: the dialect emits
    // "->" unconditionally and ignores GraphEdgeDescriptor.direction() entirely, so
    // an incoming traversal is not expressible there. BOUGHT is also the name the
    // PGQ track already uses (bought_edges).
    //
    // rec.pg_id, not rec.id: this stack can read the domain key straight out of the
    // graph. exeris-community cannot — its SPI hands back only the node UUID, so it
    // pays an extra Postgres resolve per recommendation. That difference is a real
    // consequence of the SPI's identity model and is deliberately left visible
    // rather than equalised away.
    private static final String RECOMMEND_CYPHER =
            "MATCH (u:User {id: $uid})-[:BOUGHT]->(bought:Product)-[:SIMILAR_TO]->(rec:Product) " +
            "RETURN DISTINCT rec.pg_id AS productId LIMIT $limit";

    private static final String CART_READ_CYPHER =
            "MATCH (u:User {id: $uid})-[:IN_CART]->(p:Product) RETURN p.pg_id AS productId";

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

    private final Driver driver;
    private final DataSource dataSource;

    public GraphShopService(ObjectProvider<Driver> driverProvider, DataSource dataSource) {
        this.driver = driverProvider.getIfAvailable();
        this.dataSource = dataSource;
    }

    public List<Long> recommendedProductIds(long userId, int limit) {
        if (driver != null) {
            try (var session = driver.session()) {
                return session.run(RECOMMEND_CYPHER,
                                Map.<String, Object>of("uid", userNodeId(userId).toString(), "limit", limit))
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
            try (var session = driver.session()) {
                return session.run(CART_READ_CYPHER, Map.<String, Object>of("uid", userNodeId(userId).toString()))
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
            try (var session = driver.session()) {
                session.run(CART_UPSERT_CYPHER,
                        Map.<String, Object>of("uid", userNodeId(userId).toString(), "pid", productNodeId(productId).toString(), "qty", quantity));
            } catch (Exception ignored) {
            }
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
