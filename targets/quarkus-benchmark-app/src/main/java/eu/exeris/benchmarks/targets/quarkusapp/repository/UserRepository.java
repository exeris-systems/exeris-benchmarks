package eu.exeris.benchmarks.targets.quarkusapp.repository;

import eu.exeris.benchmarks.targets.quarkusapp.dto.FriendSummary;
import eu.exeris.benchmarks.targets.quarkusapp.dto.InterestView;
import eu.exeris.benchmarks.targets.quarkusapp.dto.UserSummary;
import eu.exeris.benchmarks.targets.quarkusapp.dto.UserView;

import jakarta.enterprise.context.ApplicationScoped;
import jakarta.inject.Inject;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Tuple;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;

@ApplicationScoped
public class UserRepository {

    @Inject
    UserPanacheRepository userPanacheRepository;

    @Inject
    FriendshipPanacheRepository friendshipPanacheRepository;

    @Inject
    UserInterestPanacheRepository userInterestPanacheRepository;

    @Inject
    EntityManager entityManager;

    public List<UserSummary> findTopUsers(int limit) {
        return userPanacheRepository.findTopUsers(limit);
    }

    public UserSummary findUserById(long id) {
        return userPanacheRepository.findUserById(id);
    }

    public List<FriendSummary> findFriendsForUser(String userId, int limit) {
        return friendshipPanacheRepository.findFriendsForUser(userId, limit);
    }

    public List<InterestView> findInterestsForUser(String userId, int limit) {
        return userInterestPanacheRepository.findInterestsForUser(userId, limit);
    }

    public List<UserView> findTopUsersWithDetails(int userLimit, int friendLimit, int interestLimit) {
        List<UserSummary> users = findTopUsers(userLimit);
        if (users.isEmpty()) {
            return List.of();
        }

        List<Long> userIds = new ArrayList<>(users.size());
        for (UserSummary user : users) {
            userIds.add(parseNumericId(user.id()));
        }

        Map<String, List<FriendSummary>> friendsByUser = findFriendsForUsers(userIds, friendLimit);
        Map<String, List<InterestView>> interestsByUser = findInterestsForUsers(userIds, interestLimit);

        List<UserView> views = new ArrayList<>(users.size());
        for (UserSummary user : users) {
            views.add(new UserView(
                    user.id(),
                    user.username(),
                    friendsByUser.getOrDefault(user.id(), List.of()),
                    interestsByUser.getOrDefault(user.id(), List.of())
            ));
        }
        return views;
    }

    public boolean ping() {
        try {
            Integer one = (Integer) entityManager.createNativeQuery("SELECT 1").getSingleResult();
            return one != null && one == 1;
        } catch (Exception exception) {
            return false;
        }
    }

    private Map<String, List<FriendSummary>> findFriendsForUsers(List<Long> userIds, int limit) {
        if (userIds.isEmpty() || limit <= 0) {
            return Map.of();
        }

         List<Tuple> rows = entityManager.createNativeQuery(
                        """
                   SELECT ranked.user_id AS user_id,
                       ranked.friend_user_id AS friend_user_id,
                       ranked.friend_username AS friend_username
                        FROM (
                            SELECT f.user_id,
                                   f.friend_user_id,
                                   u.username AS friend_username,
                                   ROW_NUMBER() OVER (PARTITION BY f.user_id ORDER BY f.friend_user_id ASC) AS rn
                            FROM friendships f
                            JOIN users u ON u.id = f.friend_user_id
                            WHERE f.user_id IN (:userIds)
                        ) ranked
                        WHERE ranked.rn <= :limit
                        ORDER BY ranked.user_id ASC, ranked.friend_user_id ASC
                        """,
                        Tuple.class)
                .setParameter("userIds", userIds)
                .setParameter("limit", limit)
                .getResultList();

        Map<String, List<FriendSummary>> friendsByUser = new HashMap<>(userIds.size());
                for (Tuple row : rows) {
                    String userId = Long.toString(row.get("user_id", Number.class).longValue());
                    String friendId = Long.toString(row.get("friend_user_id", Number.class).longValue());
                    String friendUsername = row.get("friend_username", String.class);
            friendsByUser.computeIfAbsent(userId, ignored -> new ArrayList<>())
                    .add(new FriendSummary(friendId, friendUsername));
        }
        return friendsByUser;
    }

    private Map<String, List<InterestView>> findInterestsForUsers(List<Long> userIds, int limit) {
        if (userIds.isEmpty() || limit <= 0) {
            return Map.of();
        }

         List<Tuple> rows = entityManager.createNativeQuery(
                        """
                   SELECT ranked.user_id AS user_id,
                       ranked.interest_id AS interest_id,
                       ranked.interest_name AS interest_name,
                       ranked.interest_category AS interest_category
                        FROM (
                            SELECT ui.user_id,
                                   ui.interest_id,
                                   i.name AS interest_name,
                                   i.category AS interest_category,
                                   ROW_NUMBER() OVER (PARTITION BY ui.user_id ORDER BY ui.interest_id ASC) AS rn
                            FROM user_interests ui
                            JOIN interests i ON i.id = ui.interest_id
                            WHERE ui.user_id IN (:userIds)
                        ) ranked
                        WHERE ranked.rn <= :limit
                        ORDER BY ranked.user_id ASC, ranked.interest_id ASC
                        """,
                        Tuple.class)
                .setParameter("userIds", userIds)
                .setParameter("limit", limit)
                .getResultList();

        Map<String, List<InterestView>> interestsByUser = new HashMap<>(userIds.size());
                for (Tuple row : rows) {
                    String userId = Long.toString(row.get("user_id", Number.class).longValue());
                    String interestId = Long.toString(row.get("interest_id", Number.class).longValue());
                    String name = row.get("interest_name", String.class);
                    String category = row.get("interest_category", String.class);
            interestsByUser.computeIfAbsent(userId, ignored -> new ArrayList<>())
                    .add(new InterestView(interestId, name, category));
        }
        return interestsByUser;
    }

    private static long parseNumericId(String id) {
        try {
            return Long.parseLong(id);
        } catch (NumberFormatException exception) {
            throw new IllegalStateException("Invalid user id: " + id, exception);
        }
    }
}
