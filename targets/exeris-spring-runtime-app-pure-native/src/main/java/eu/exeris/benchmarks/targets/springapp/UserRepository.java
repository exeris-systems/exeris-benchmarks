package eu.exeris.benchmarks.targets.springapp;

import eu.exeris.kernel.spi.persistence.PersistenceConnection;
import eu.exeris.kernel.spi.persistence.PersistenceStatement;
import eu.exeris.kernel.spi.persistence.QueryResult;
import eu.exeris.kernel.spi.persistence.RowCursor;
import eu.exeris.kernel.spi.persistence.TransactionalExecutor;

import org.springframework.stereotype.Repository;

import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;

/**
 * Kernel-native counterpart of the Spring Data JPA repository stack in
 * {@code targets/exeris-spring-runtime-app-pure}.
 *
 * <p><b>Axis note.</b> The public method signatures are identical to the ORM arm's
 * {@code UserRepository} and the route handlers above it are byte-identical, so the only thing
 * that differs between the two targets is what happens below this class: Hibernate entity
 * hydration over {@code ExerisDataSource} there, prepared statements over
 * {@link TransactionalExecutor} here. That is the persistence axis, isolated.
 *
 * <p><b>SQL provenance.</b> Every statement below is copied verbatim from
 * {@code targets/exeris-community-app}'s {@code UserRepository} so that this arm and the
 * community arm issue byte-identical SQL to Postgres. Do not "improve" a query here without
 * making the same change there — a divergence would turn a runtime comparison into a
 * query-plan comparison.
 *
 * <p><b>Inherited asymmetry, deliberately preserved.</b> The single-user friends/interests reads
 * bind their parameters as strings against {@code CAST(? AS BIGINT)}, while the batch reads bind
 * typed int8 against plain placeholders. That inconsistency exists in the community arm (its
 * 2026-07-20 bind-equalisation pass covered the batch paths and the by-id path, not these two)
 * and is replicated rather than silently fixed, so the two arms stay comparable. If it is
 * corrected, correct it in both targets in the same change.
 */
@Repository
public class UserRepository {

    // Fairness (JDBC bind equalization, 2026-07-20, inherited from exeris-community-app): bind
    // typed numerics against plain placeholders, symmetric with the quarkus target (setLong/setInt,
    // no CAST). Ids arrive as decimal strings and are parsed to long at the bind site — the same
    // String→long parse quarkus does at its JAX-RS @QueryParam boundary — so both stacks issue an
    // int8 param to Postgres, not text + CAST.
    private static final String READ_TOP_USERS_SQL =
            "SELECT id, username FROM users ORDER BY id ASC LIMIT ?";
    private static final String READ_USER_BY_ID_SQL =
            "SELECT id, username FROM users WHERE id = ?";
    private static final String READ_FRIENDS_SQL = """
        SELECT u.id, u.username
        FROM friendships f
        JOIN users u ON u.id = f.friend_user_id
        WHERE f.user_id = CAST(? AS BIGINT)
        ORDER BY f.friend_user_id ASC
            LIMIT CAST(? AS BIGINT)
            """;
    private static final String READ_INTERESTS_SQL = """
        SELECT i.id, i.name, i.category
        FROM user_interests ui
        JOIN interests i ON i.id = ui.interest_id
        WHERE ui.user_id = CAST(? AS BIGINT)
        ORDER BY ui.interest_id ASC
            LIMIT CAST(? AS BIGINT)
            """;

    private final TransactionalExecutor transactionalExecutor;

    public UserRepository(TransactionalExecutor transactionalExecutor) {
        this.transactionalExecutor = transactionalExecutor;
    }

    public List<UserSummary> findTopUsers(int limit) {
        if (limit <= 0) {
            return List.of();
        }
        return transactionalExecutor.query(connection -> queryTopUsers(connection, limit));
    }

    /**
     * Single-row PK read. The native counterpart of the ORM arm's
     * {@code benchmarkUserJpaRepository.findById(id)} — same row, same projection, no entity
     * hydration. The absence of that hydration step is precisely what the light contract
     * (fixed_contract_cross_runtime_h1_single_read_v1) measures on this axis.
     */
    public UserSummary findUserById(long id) {
        return transactionalExecutor.query(connection -> queryUserById(connection, id));
    }

    public List<FriendSummary> findFriendsForUser(String userId, int limit) {
        if (limit <= 0) {
            return List.of();
        }
        return transactionalExecutor.query(connection -> queryFriendsForUser(connection, userId, limit));
    }

    public List<InterestView> findInterestsForUser(String userId, int limit) {
        if (limit <= 0) {
            return List.of();
        }
        return transactionalExecutor.query(connection -> queryInterestsForUser(connection, userId, limit));
    }

    /**
     * Heavy-contract read. Runs all three queries inside one read session, i.e. on one connection
     * in one transaction — the analogue of the ORM arm's {@code @Transactional(readOnly = true)}
     * boundary around three repository calls sharing one EntityManager.
     */
    public List<UserView> findTopUsersWithDetails(int userLimit, int friendLimit, int interestLimit) {
        return transactionalExecutor.inReadSession(session -> {
            List<UserSummary> users = session.query(connection -> queryTopUsers(connection, userLimit));
            if (users.isEmpty()) {
                return List.<UserView>of();
            }

            List<String> userIds = new ArrayList<>(users.size());
            for (UserSummary user : users) {
                userIds.add(user.id());
            }

            Map<String, List<FriendSummary>> friendsByUser =
                    session.query(connection -> queryFriendsForUsers(connection, userIds, friendLimit));
            Map<String, List<InterestView>> interestsByUser =
                    session.query(connection -> queryInterestsForUsers(connection, userIds, interestLimit));

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
        });
    }

    private static List<UserSummary> queryTopUsers(PersistenceConnection connection, int limit) {
        try (PersistenceStatement statement = connection.prepare(READ_TOP_USERS_SQL)) {
            // Fairness (JDBC bind equalization): typed int bind, matching quarkus setInt.
            statement.bindInt(0, limit);
            try (QueryResult result = statement.executeQuery()) {
                List<UserSummary> users = new ArrayList<>(Math.max(0, limit));
                while (result.next()) {
                    RowCursor row = result.row();
                    // Fairness (JDBC accessor equalization): the id column is BIGINT and the DTO
                    // field is String, so read it as a typed long by index and convert in-app.
                    // This avoids pgjdbc's getString-on-int8 machinery (initSqlType/trimString);
                    // username (text) stays getString by index.
                    users.add(new UserSummary(Long.toString(row.getLong(0)), row.getString(1)));
                }
                return users;
            }
        }
    }

    private static UserSummary queryUserById(PersistenceConnection connection, long id) {
        try (PersistenceStatement statement = connection.prepare(READ_USER_BY_ID_SQL)) {
            // Fairness (JDBC bind equalization): typed int8 bind, matching quarkus's
            // @QueryParam long → setLong. No text + CAST path.
            statement.bindLong(0, id);
            try (QueryResult result = statement.executeQuery()) {
                if (!result.next()) {
                    // null, not Optional.empty(): the ORM arm's findUserById returns null for a
                    // missing row and the route handler maps that to 404. Same contract here.
                    return null;
                }
                RowCursor row = result.row();
                return new UserSummary(Long.toString(row.getLong(0)), row.getString(1));
            }
        }
    }

    private static List<FriendSummary> queryFriendsForUser(
            PersistenceConnection connection, String userId, int limit) {
        try (PersistenceStatement statement = connection.prepare(READ_FRIENDS_SQL)) {
            statement.bindString(0, userId);
            statement.bindString(1, Integer.toString(limit));
            try (QueryResult result = statement.executeQuery()) {
                List<FriendSummary> friends = new ArrayList<>(Math.max(0, limit));
                while (result.next()) {
                    RowCursor row = result.row();
                    friends.add(new FriendSummary(row.getString(0), row.getString(1)));
                }
                return friends;
            }
        }
    }

    private static List<InterestView> queryInterestsForUser(
            PersistenceConnection connection, String userId, int limit) {
        try (PersistenceStatement statement = connection.prepare(READ_INTERESTS_SQL)) {
            statement.bindString(0, userId);
            statement.bindString(1, Integer.toString(limit));
            try (QueryResult result = statement.executeQuery()) {
                List<InterestView> interests = new ArrayList<>(Math.max(0, limit));
                while (result.next()) {
                    RowCursor row = result.row();
                    interests.add(new InterestView(row.getString(0), row.getString(1), row.getString(2)));
                }
                return interests;
            }
        }
    }

    private static Map<String, List<FriendSummary>> queryFriendsForUsers(
            PersistenceConnection connection, List<String> userIds, int limit) {
        if (userIds.isEmpty() || limit <= 0) {
            return Map.of();
        }

        String sql = """
            SELECT ranked.user_id, ranked.friend_user_id, ranked.friend_username
            FROM (
                SELECT f.user_id,
                       f.friend_user_id,
                       u.username AS friend_username,
                       row_number() OVER (PARTITION BY f.user_id ORDER BY f.friend_user_id ASC) AS rn
                FROM friendships f
                JOIN users u ON u.id = f.friend_user_id
                WHERE f.user_id IN (%s)
            ) ranked
            WHERE ranked.rn <= ?
            ORDER BY ranked.user_id ASC, ranked.friend_user_id ASC
            """.formatted(buildInClausePlaceholders(userIds.size()));

        Map<String, List<FriendSummary>> friendsByUser = new HashMap<>(userIds.size());
        try (PersistenceStatement statement = connection.prepare(sql)) {
            int bindIndex = 0;
            for (String userId : userIds) {
                // Fairness (JDBC bind equalization): typed int8 bind, matching quarkus setLong.
                statement.bindLong(bindIndex++, Long.parseLong(userId));
            }
            statement.bindInt(bindIndex, limit);

            try (QueryResult result = statement.executeQuery()) {
                while (result.next()) {
                    RowCursor row = result.row();
                    // Fairness (JDBC accessor equalization): user_id + friend_user_id are BIGINT;
                    // read them as typed longs by index and convert in-app. friend_username (text)
                    // stays getString by index.
                    String userId = Long.toString(row.getLong(0));
                    friendsByUser.computeIfAbsent(userId, ignored -> new ArrayList<>())
                            .add(new FriendSummary(Long.toString(row.getLong(1)), row.getString(2)));
                }
            }
        }
        return friendsByUser;
    }

    private static Map<String, List<InterestView>> queryInterestsForUsers(
            PersistenceConnection connection, List<String> userIds, int limit) {
        if (userIds.isEmpty() || limit <= 0) {
            return Map.of();
        }

        String sql = """
            SELECT ranked.user_id, ranked.interest_id, ranked.interest_name, ranked.interest_category
            FROM (
                SELECT ui.user_id,
                       ui.interest_id,
                       i.name AS interest_name,
                       i.category AS interest_category,
                       row_number() OVER (PARTITION BY ui.user_id ORDER BY ui.interest_id ASC) AS rn
                FROM user_interests ui
                JOIN interests i ON i.id = ui.interest_id
                WHERE ui.user_id IN (%s)
            ) ranked
            WHERE ranked.rn <= ?
            ORDER BY ranked.user_id ASC, ranked.interest_id ASC
            """.formatted(buildInClausePlaceholders(userIds.size()));

        Map<String, List<InterestView>> interestsByUser = new HashMap<>(userIds.size());
        try (PersistenceStatement statement = connection.prepare(sql)) {
            int bindIndex = 0;
            for (String userId : userIds) {
                // Fairness (JDBC bind equalization): typed int8 bind, matching quarkus setLong.
                statement.bindLong(bindIndex++, Long.parseLong(userId));
            }
            statement.bindInt(bindIndex, limit);

            try (QueryResult result = statement.executeQuery()) {
                while (result.next()) {
                    RowCursor row = result.row();
                    // Fairness (JDBC accessor equalization): user_id + interest_id are BIGINT; read
                    // them as typed longs by index and convert in-app. interest_name +
                    // interest_category (text) stay getString by index.
                    String userId = Long.toString(row.getLong(0));
                    interestsByUser.computeIfAbsent(userId, ignored -> new ArrayList<>())
                            .add(new InterestView(
                                    Long.toString(row.getLong(1)), row.getString(2), row.getString(3)));
                }
            }
        }
        return interestsByUser;
    }

    // Fairness (JDBC bind equalization): plain positional placeholders; ids are bound as typed
    // int8 (bindLong) by the callers, matching quarkus's inClausePlaceholders + setLong. No
    // per-element CAST(? AS BIGINT).
    private static String buildInClausePlaceholders(int size) {
        StringBuilder placeholders = new StringBuilder(size * 3);
        for (int i = 0; i < size; i++) {
            if (i > 0) {
                placeholders.append(", ");
            }
            placeholders.append("?");
        }
        return placeholders.toString();
    }
}
