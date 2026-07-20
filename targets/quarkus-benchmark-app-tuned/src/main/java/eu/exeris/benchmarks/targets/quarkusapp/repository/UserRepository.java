package eu.exeris.benchmarks.targets.quarkusapp.repository;

import eu.exeris.benchmarks.targets.quarkusapp.dto.FriendSummary;
import eu.exeris.benchmarks.targets.quarkusapp.dto.InterestView;
import eu.exeris.benchmarks.targets.quarkusapp.dto.UserSummary;
import eu.exeris.benchmarks.targets.quarkusapp.dto.UserView;

import jakarta.enterprise.context.ApplicationScoped;
import jakarta.inject.Inject;

import javax.sql.DataSource;
import java.sql.Connection;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;

/**
 * Pure-JDBC user repository (no Hibernate/ORM, no Panache).
 *
 * <p>This is the JDBC counterpart of the ORM-backed {@code quarkus-benchmark-app}
 * repository. The SQL query shapes are kept identical to the native queries the ORM
 * variant issued (top-N users, windowed friends, windowed interests) so the only
 * measured difference between the two targets is the data-access layer itself
 * (Hibernate/Panache plumbing vs. raw {@link PreparedStatement}/{@link ResultSet}),
 * not the queries. The three statements run on a single connection borrowed from the
 * Agroal pool, enlisted in the caller's JTA transaction.
 */
@ApplicationScoped
public class UserRepository {

    private static final String TOP_USERS_SQL =
            "SELECT id, username FROM users ORDER BY id ASC LIMIT ?";

    // Single-row indexed read (PK lookup) for the lightweight runtime-bound scenario:
    // trivial DB cost (~microseconds) so throughput reflects the runtime + connection
    // pool + JSON serialization path, not Postgres. Kept identical across targets.
    private static final String USER_BY_ID_SQL =
            "SELECT id, username FROM users WHERE id = ?";

    private static final String PING_SQL = "SELECT 1";

    @Inject
    DataSource dataSource;

    public List<UserView> findTopUsersWithDetails(int userLimit, int friendLimit, int interestLimit) {
        try (Connection connection = dataSource.getConnection()) {
            List<UserSummary> users = queryTopUsers(connection, userLimit);
            if (users.isEmpty()) {
                return List.of();
            }

            List<Long> userIds = new ArrayList<>(users.size());
            for (UserSummary user : users) {
                userIds.add(parseNumericId(user.id()));
            }

            Map<String, List<FriendSummary>> friendsByUser = queryFriendsForUsers(connection, userIds, friendLimit);
            Map<String, List<InterestView>> interestsByUser = queryInterestsForUsers(connection, userIds, interestLimit);

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
        } catch (SQLException exception) {
            throw new IllegalStateException("Failed to read top users with details", exception);
        }
    }

    public UserSummary findUserById(long id) {
        try (Connection connection = dataSource.getConnection();
             PreparedStatement statement = connection.prepareStatement(USER_BY_ID_SQL)) {
            statement.setLong(1, id);
            try (ResultSet resultSet = statement.executeQuery()) {
                if (resultSet.next()) {
                    // Fairness (JDBC accessor equalization, 2026-07-20): read by column index rather
                    // than by name, symmetric with the exeris target — avoids pgjdbc's per-call
                    // column-name→index lookup (PgResultSet.findColumn). SQL: SELECT id, username.
                    return new UserSummary(
                            Long.toString(resultSet.getLong(1)),
                            resultSet.getString(2));
                }
                return null;
            }
        } catch (SQLException exception) {
            throw new IllegalStateException("Failed to read user by id", exception);
        }
    }

    public boolean ping() {
        try (Connection connection = dataSource.getConnection();
             PreparedStatement statement = connection.prepareStatement(PING_SQL);
             ResultSet resultSet = statement.executeQuery()) {
            return resultSet.next() && resultSet.getInt(1) == 1;
        } catch (SQLException exception) {
            return false;
        }
    }

    private static List<UserSummary> queryTopUsers(Connection connection, int limit) throws SQLException {
        if (limit <= 0) {
            return List.of();
        }
        try (PreparedStatement statement = connection.prepareStatement(TOP_USERS_SQL)) {
            statement.setInt(1, limit);
            try (ResultSet resultSet = statement.executeQuery()) {
                List<UserSummary> users = new ArrayList<>(limit);
                while (resultSet.next()) {
                    // Fairness (JDBC accessor equalization, 2026-07-20): by-index read, symmetric
                    // with the exeris target (no findColumn). SQL: SELECT id, username.
                    users.add(new UserSummary(
                            Long.toString(resultSet.getLong(1)),
                            resultSet.getString(2)));
                }
                return users;
            }
        }
    }

    private static Map<String, List<FriendSummary>> queryFriendsForUsers(
            Connection connection, List<Long> userIds, int limit) throws SQLException {
        if (userIds.isEmpty() || limit <= 0) {
            return Map.of();
        }

        String sql = """
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
                    WHERE f.user_id IN (%s)
                ) ranked
                WHERE ranked.rn <= ?
                ORDER BY ranked.user_id ASC, ranked.friend_user_id ASC
                """.formatted(inClausePlaceholders(userIds.size()));

        Map<String, List<FriendSummary>> friendsByUser = new HashMap<>(userIds.size());
        try (PreparedStatement statement = connection.prepareStatement(sql)) {
            int bindIndex = bindUserIds(statement, userIds);
            statement.setInt(bindIndex, limit);
            try (ResultSet resultSet = statement.executeQuery()) {
                while (resultSet.next()) {
                    // Fairness (JDBC accessor equalization, 2026-07-20): by-index reads, symmetric
                    // with exeris (no findColumn). SQL cols: 1=user_id, 2=friend_user_id, 3=friend_username.
                    String userId = Long.toString(resultSet.getLong(1));
                    String friendId = Long.toString(resultSet.getLong(2));
                    String friendUsername = resultSet.getString(3);
                    friendsByUser.computeIfAbsent(userId, ignored -> new ArrayList<>())
                            .add(new FriendSummary(friendId, friendUsername));
                }
            }
        }
        return friendsByUser;
    }

    private static Map<String, List<InterestView>> queryInterestsForUsers(
            Connection connection, List<Long> userIds, int limit) throws SQLException {
        if (userIds.isEmpty() || limit <= 0) {
            return Map.of();
        }

        String sql = """
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
                    WHERE ui.user_id IN (%s)
                ) ranked
                WHERE ranked.rn <= ?
                ORDER BY ranked.user_id ASC, ranked.interest_id ASC
                """.formatted(inClausePlaceholders(userIds.size()));

        Map<String, List<InterestView>> interestsByUser = new HashMap<>(userIds.size());
        try (PreparedStatement statement = connection.prepareStatement(sql)) {
            int bindIndex = bindUserIds(statement, userIds);
            statement.setInt(bindIndex, limit);
            try (ResultSet resultSet = statement.executeQuery()) {
                while (resultSet.next()) {
                    // Fairness (JDBC accessor equalization, 2026-07-20): by-index reads, symmetric
                    // with exeris (no findColumn). SQL cols: 1=user_id, 2=interest_id, 3=interest_name,
                    // 4=interest_category.
                    String userId = Long.toString(resultSet.getLong(1));
                    String interestId = Long.toString(resultSet.getLong(2));
                    String name = resultSet.getString(3);
                    String category = resultSet.getString(4);
                    interestsByUser.computeIfAbsent(userId, ignored -> new ArrayList<>())
                            .add(new InterestView(interestId, name, category));
                }
            }
        }
        return interestsByUser;
    }

    private static String inClausePlaceholders(int size) {
        StringBuilder placeholders = new StringBuilder(size * 3);
        for (int i = 0; i < size; i++) {
            if (i > 0) {
                placeholders.append(", ");
            }
            placeholders.append('?');
        }
        return placeholders.toString();
    }

    private static int bindUserIds(PreparedStatement statement, List<Long> userIds) throws SQLException {
        int bindIndex = 1;
        for (Long userId : userIds) {
            statement.setLong(bindIndex++, userId);
        }
        return bindIndex;
    }

    private static long parseNumericId(String id) {
        try {
            return Long.parseLong(id);
        } catch (NumberFormatException exception) {
            throw new IllegalStateException("Invalid user id: " + id, exception);
        }
    }
}
