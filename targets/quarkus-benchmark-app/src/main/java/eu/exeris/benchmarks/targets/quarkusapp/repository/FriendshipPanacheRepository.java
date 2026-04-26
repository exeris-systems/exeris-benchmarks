package eu.exeris.benchmarks.targets.quarkusapp.repository;

import eu.exeris.benchmarks.targets.quarkusapp.dto.FriendSummary;
import eu.exeris.benchmarks.targets.quarkusapp.entity.FriendshipEntity;

import io.quarkus.hibernate.orm.panache.PanacheRepository;
import jakarta.enterprise.context.ApplicationScoped;
import jakarta.persistence.Tuple;
import jakarta.persistence.TypedQuery;

import java.util.ArrayList;
import java.util.List;

@ApplicationScoped
public class FriendshipPanacheRepository implements PanacheRepository<FriendshipEntity> {

    public List<FriendSummary> findFriendsForUser(String userId, int limit) {
        if (limit <= 0) {
            return List.of();
        }

        long numericUserId = parseNumericId(userId);
        TypedQuery<Tuple> query = getEntityManager().createQuery(
                """
                select f.friend.id as friendId, f.friend.username as friendUsername
                from FriendshipEntity f
                where f.id.userId = :userId
                order by f.id.friendUserId asc
                """,
                Tuple.class);
        query.setParameter("userId", numericUserId);
        query.setMaxResults(limit);

        List<Tuple> rows = query.getResultList();
        List<FriendSummary> friends = new ArrayList<>(rows.size());
        for (Tuple row : rows) {
            Long friendId = row.get("friendId", Long.class);
            String friendUsername = row.get("friendUsername", String.class);
            friends.add(new FriendSummary(Long.toString(friendId), friendUsername));
        }
        return friends;
    }

    private static long parseNumericId(String id) {
        try {
            return Long.parseLong(id);
        } catch (NumberFormatException exception) {
            throw new IllegalStateException("Invalid user id: " + id, exception);
        }
    }
}
