package eu.exeris.benchmarks.targets.exeriscommunity.infrastructure.graph;

import eu.exeris.kernel.spi.graph.GraphEngine;
import eu.exeris.kernel.spi.graph.GraphSession;
import eu.exeris.kernel.spi.graph.model.GraphEdgeDescriptor;
import eu.exeris.kernel.spi.graph.model.GraphTraversal;
import java.nio.charset.StandardCharsets;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Set;
import java.util.UUID;

public final class GraphShopAdapter {

    private static final GraphEdgeDescriptor USER_BOUGHT_PRODUCT =
        GraphEdgeDescriptor.create("User", "BOUGHT", "Product");
    private static final GraphEdgeDescriptor PRODUCT_SIMILAR_TO_PRODUCT =
        GraphEdgeDescriptor.create("Product", "SIMILAR_TO", "Product");
    private static final GraphEdgeDescriptor USER_CART_PRODUCT =
        GraphEdgeDescriptor.create("User", "IN_CART", "Product");

    private final GraphEngine graphEngine;

    public GraphShopAdapter(GraphEngine graphEngine) {
        this.graphEngine = graphEngine;
    }

    public List<GraphEdgeDescriptor> edgeDescriptors() {
        return List.of(USER_BOUGHT_PRODUCT, PRODUCT_SIMILAR_TO_PRODUCT, USER_CART_PRODUCT);
    }

    public List<UUID> recommendProductNodeIdsFromGraph(long userId, int limit) {
        int boundedLimit = Math.max(0, limit);
        if (boundedLimit == 0) {
            return List.of();
        }

        if (graphEngine == null) {
            throw new GraphUnavailableException("Graph recommendation traversal unavailable",
                new IllegalStateException("Graph engine not configured"));
        }

        try (GraphSession session = graphEngine.openSession()) {
            UUID userUuid = userUuid(userId);
            List<UUID> purchasedProducts =
                session.traverseBreadthFirst(GraphTraversal.create(userUuid, USER_BOUGHT_PRODUCT, 1));

            if (purchasedProducts.isEmpty()) {
                return List.of();
            }

            Set<UUID> deduplicated = new LinkedHashSet<>();
            for (UUID purchasedProduct : purchasedProducts) {
                List<UUID> similarProducts = session.traverseBreadthFirst(
                    GraphTraversal.create(purchasedProduct, PRODUCT_SIMILAR_TO_PRODUCT, 2)
                );
                for (UUID similarProduct : similarProducts) {
                    deduplicated.add(similarProduct);
                    if (deduplicated.size() >= boundedLimit) {
                        break;
                    }
                }
                if (deduplicated.size() >= boundedLimit) {
                    break;
                }
            }

            return List.copyOf(deduplicated);
        } catch (RuntimeException exception) {
            throw new GraphUnavailableException("Graph recommendation traversal unavailable", exception);
        }
    }

    public void upsertCartEdge(long userId, long productId, int quantity) {
        if (graphEngine == null) {
            throw new GraphUnavailableException("Graph cart projection unavailable",
                new IllegalStateException("Graph engine not configured"));
        }

        try (GraphSession session = graphEngine.openSession()) {
            session.upsertEdge(
                USER_CART_PRODUCT,
                userUuid(userId),
                productUuid(productId),
                quantity,
                "{\"quantity\":" + quantity + "}"
            );
        } catch (RuntimeException exception) {
            throw new GraphUnavailableException("Graph cart projection unavailable", exception);
        }
    }

    public List<UUID> readCartProductNodeIds(long userId) {
        if (graphEngine == null) {
            throw new GraphUnavailableException("Graph cart read traversal unavailable",
                new IllegalStateException("Graph engine not configured"));
        }

        try (GraphSession session = graphEngine.openSession()) {
            List<UUID> nodeIds = session.traverseBreadthFirst(
                GraphTraversal.create(userUuid(userId), USER_CART_PRODUCT, 1)
            );
            if (nodeIds.isEmpty()) {
                return List.of();
            }
            return List.copyOf(new LinkedHashSet<>(nodeIds));
        } catch (RuntimeException exception) {
            throw new GraphUnavailableException("Graph cart read traversal unavailable", exception);
        }
    }

    private static UUID userUuid(long userId) {
        return nameUuid("user-" + userId);
    }

    private static UUID productUuid(long productId) {
        return nameUuid("product-" + productId);
    }

    private static UUID nameUuid(String value) {
        return UUID.nameUUIDFromBytes(value.getBytes(StandardCharsets.UTF_8));
    }
}
