package eu.exeris.benchmarks.targets.exeriscommunity.infrastructure.graph;

import eu.exeris.kernel.spi.graph.GraphEngine;
import eu.exeris.kernel.spi.graph.GraphSession;
import eu.exeris.kernel.spi.graph.model.GraphEdgeDescriptor;
import eu.exeris.kernel.spi.graph.model.GraphTraversal;

import java.util.ArrayList;
import java.util.HashSet;
import java.util.List;
import java.util.Set;
import java.util.UUID;

public final class GraphFriendsOfFriendsAdapter {

    private static final GraphEdgeDescriptor FOLLOWS_EDGE = GraphEdgeDescriptor.create("User", "FOLLOWS", "User");

    private final GraphEngine graphEngine;

    public GraphFriendsOfFriendsAdapter(GraphEngine graphEngine) {
        this.graphEngine = graphEngine;
    }

    public List<GraphEdgeDescriptor> edgeDescriptors() {
        return List.of(FOLLOWS_EDGE);
    }

    public List<UUID> findSecondDegreeNeighborIds(UUID userId, int limit) {
        int boundedLimit = Math.max(0, limit);
        if (boundedLimit == 0) {
            return List.of();
        }

        if (graphEngine == null) {
            throw new GraphUnavailableException("Graph traversal unavailable",
                new IllegalStateException("Graph engine not configured"));
        }

        try (GraphSession session = graphEngine.openSession()) {
            List<UUID> firstDegree = session.traverseBreadthFirst(GraphTraversal.create(userId, FOLLOWS_EDGE, 1));
            List<UUID> secondHopRaw = session.traverseBreadthFirst(GraphTraversal.create(userId, FOLLOWS_EDGE, 2));

            Set<UUID> excludedIds = new HashSet<>(firstDegree.size() + 1);
            excludedIds.add(userId);
            excludedIds.addAll(firstDegree);

            List<UUID> secondDegree = new ArrayList<>(Math.min(secondHopRaw.size(), boundedLimit));
            for (UUID id : secondHopRaw) {
                if (excludedIds.contains(id)) {
                    continue;
                }
                secondDegree.add(id);
                if (secondDegree.size() >= boundedLimit) {
                    break;
                }
            }
            return secondDegree;
        } catch (RuntimeException exception) {
            throw new GraphUnavailableException("Graph traversal unavailable", exception);
        }
    }
}
