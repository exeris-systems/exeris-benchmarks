package eu.exeris.benchmarks.targets.exeriscommunity.infrastructure.persistence;



import eu.exeris.benchmarks.targets.exeriscommunity.domain.user.FriendSummary;
import eu.exeris.benchmarks.targets.exeriscommunity.domain.user.InterestView;
import eu.exeris.benchmarks.targets.exeriscommunity.domain.user.UserSummary;
import eu.exeris.benchmarks.targets.exeriscommunity.domain.user.UserView;
import eu.exeris.kernel.spi.persistence.BaseRepository;
import eu.exeris.kernel.spi.persistence.PersistenceConnection;
import eu.exeris.kernel.spi.persistence.PersistenceStatement;
import eu.exeris.kernel.spi.persistence.QueryResult;
import eu.exeris.kernel.spi.persistence.RowCursor;
import eu.exeris.kernel.spi.persistence.TransactionalExecutor;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;
import java.util.Optional;
import java.util.UUID;

public class UserRepository implements BaseRepository<UserSummary, String> {

    private static final String READ_TOP_USERS_SQL = "SELECT id, username FROM users ORDER BY id ASC LIMIT CAST(? AS BIGINT)";
    private static final String READ_USER_BY_ID_SQL = "SELECT id, username FROM users WHERE id = CAST(? AS BIGINT)";
    private static final String USER_EXISTS_BY_ID_SQL = "SELECT EXISTS(SELECT 1 FROM users WHERE id = CAST(? AS BIGINT))";
    private static final String UPSERT_USER_SQL = "INSERT INTO users (id, username) VALUES (CAST(? AS BIGINT), ?) ON CONFLICT (id) DO UPDATE SET username = EXCLUDED.username";
    private static final String DELETE_USER_BY_ID_SQL = "DELETE FROM users WHERE id = CAST(? AS BIGINT)";
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
    private static final String READ_USERS_WITHOUT_INTERESTS_BY_ORDERED_IDS_SQL_TEMPLATE = """
        SELECT u.id, u.username, ranked.idx
        FROM users u
        JOIN (
            VALUES %s
        ) AS ranked(id_text, idx) ON CAST(u.id AS TEXT) = ranked.id_text
        LEFT JOIN user_interests ui ON ui.user_id = u.id
        WHERE ui.user_id IS NULL
        ORDER BY ranked.idx ASC
        LIMIT CAST(? AS BIGINT)
        """;

    private final TransactionalExecutor transactionalExecutor;

    public UserRepository(TransactionalExecutor transactionalExecutor) {
        this.transactionalExecutor = transactionalExecutor;
    }

    @Override
    public Optional<UserSummary> findById(String id) {
        String requiredId = Objects.requireNonNull(id, "id must not be null");
        return transactionalExecutor.query(connection -> queryUserById(connection, requiredId));
    }

    @Override
    public void save(UserSummary user) {
        UserSummary requiredUser = Objects.requireNonNull(user, "user must not be null");
        transactionalExecutor.execute(connection -> upsertUser(connection, requiredUser));
    }

    @Override
    public void deleteById(String id) {
        String requiredId = Objects.requireNonNull(id, "id must not be null");
        transactionalExecutor.execute(connection -> deleteUserById(connection, requiredId));
    }

    @Override
    public boolean existsById(String id) {
        String requiredId = Objects.requireNonNull(id, "id must not be null");
        return transactionalExecutor.query(connection -> queryUserExistsById(connection, requiredId));
    }

    public List<UserSummary> findTopUsers(int limit) {
        return transactionalExecutor.query(connection -> queryTopUsers(connection, limit));
    }

    public List<FriendSummary> findFriendsForUser(String userId, int limit) {
        return transactionalExecutor.query(connection -> queryFriendsForUser(connection, userId, limit));
    }

    public List<InterestView> findInterestsForUser(String userId, int limit) {
        return transactionalExecutor.query(connection -> queryInterestsForUser(connection, userId, limit));
    }

    public List<UserView> findTopUsersWithDetails(int userLimit, int friendLimit, int interestLimit) {
        return transactionalExecutor.inReadSession(session -> {
            List<UserSummary> users = session.query(conn -> queryTopUsers(conn, userLimit));
            if (users.isEmpty()) {
                return List.of();
            }

            List<String> userIds = new ArrayList<>(users.size());
            for (UserSummary user : users) {
                userIds.add(user.id());
            }

            Map<String, List<FriendSummary>> friendsByUser = session.query(conn -> queryFriendsForUsers(conn, userIds, friendLimit));
            Map<String, List<InterestView>> interestsByUser = session.query(conn -> queryInterestsForUsers(conn, userIds, interestLimit));

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

    public boolean ping() {
        return transactionalExecutor.query(connection -> {
            try (QueryResult result = connection.executeQuery("SELECT 1")) {
                return result.next();
            }
        });
    }

    public List<UserSummary> findUsersWithoutInterestsByOrderedIds(List<UUID> orderedIds, int limit) {
        List<UUID> ids = Objects.requireNonNull(orderedIds, "orderedIds must not be null");
        if (ids.isEmpty() || limit <= 0) {
            return List.of();
        }
        int boundedLimit = Math.min(limit, ids.size());
        return transactionalExecutor.query(connection -> queryUsersWithoutInterestsByOrderedIds(connection, ids, boundedLimit));
    }

    private static List<UserSummary> queryTopUsers(PersistenceConnection connection, int limit) {
        try (PersistenceStatement statement = connection.prepare(READ_TOP_USERS_SQL)) {
            statement.bindString(0, Integer.toString(limit));
            try (QueryResult result = statement.executeQuery()) {
                List<UserSummary> users = new ArrayList<>(Math.max(0, limit));
                while (result.next()) {
                    RowCursor row = result.row();
                    users.add(new UserSummary(row.getString(0), row.getString(1)));
                }
                return users;
            }
        }
    }

    private static Optional<UserSummary> queryUserById(PersistenceConnection connection, String id) {
        try (PersistenceStatement statement = connection.prepare(READ_USER_BY_ID_SQL)) {
            statement.bindString(0, id);
            try (QueryResult result = statement.executeQuery()) {
                if (!result.next()) {
                    return Optional.empty();
                }
                RowCursor row = result.row();
                return Optional.of(new UserSummary(row.getString(0), row.getString(1)));
            }
        }
    }

    private static boolean queryUserExistsById(PersistenceConnection connection, String id) {
        try (PersistenceStatement statement = connection.prepare(USER_EXISTS_BY_ID_SQL)) {
            statement.bindString(0, id);
            try (QueryResult result = statement.executeQuery()) {
                return result.next() && result.row().getBoolean(0);
            }
        }
    }

    private static void upsertUser(PersistenceConnection connection, UserSummary user) {
        try (PersistenceStatement statement = connection.prepare(UPSERT_USER_SQL)) {
            statement.bindString(0, Objects.requireNonNull(user.id(), "user.id must not be null"));
            statement.bindString(1, Objects.requireNonNull(user.username(), "user.username must not be null"));
            statement.executeUpdate();
        }
    }

    private static void deleteUserById(PersistenceConnection connection, String id) {
        try (PersistenceStatement statement = connection.prepare(DELETE_USER_BY_ID_SQL)) {
            statement.bindString(0, id);
            statement.executeUpdate();
        }
    }

    private static List<FriendSummary> queryFriendsForUser(PersistenceConnection connection, String userId, int limit) {
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

    private static List<InterestView> queryInterestsForUser(PersistenceConnection connection, String userId, int limit) {
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

    private static Map<String, List<FriendSummary>> queryFriendsForUsers(PersistenceConnection connection, List<String> userIds, int limit) {
        if (userIds.isEmpty()) {
            return Map.of();
        }

        String inClause = buildCastBigIntInClause(userIds.size());
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
            WHERE ranked.rn <= CAST(? AS BIGINT)
            ORDER BY ranked.user_id ASC, ranked.friend_user_id ASC
            """.formatted(inClause);

        Map<String, List<FriendSummary>> friendsByUser = new HashMap<>(userIds.size());
        try (PersistenceStatement statement = connection.prepare(sql)) {
            int bindIndex = 0;
            for (String userId : userIds) {
                statement.bindString(bindIndex++, userId);
            }
            statement.bindString(bindIndex, Integer.toString(limit));

            try (QueryResult result = statement.executeQuery()) {
                while (result.next()) {
                    RowCursor row = result.row();
                    String userId = row.getString(0);
                    friendsByUser.computeIfAbsent(userId, ignored -> new ArrayList<>())
                        .add(new FriendSummary(row.getString(1), row.getString(2)));
                }
            }
        }
        return friendsByUser;
    }

    private static Map<String, List<InterestView>> queryInterestsForUsers(PersistenceConnection connection, List<String> userIds, int limit) {
        if (userIds.isEmpty()) {
            return Map.of();
        }

        String inClause = buildCastBigIntInClause(userIds.size());
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
            WHERE ranked.rn <= CAST(? AS BIGINT)
            ORDER BY ranked.user_id ASC, ranked.interest_id ASC
            """.formatted(inClause);

        Map<String, List<InterestView>> interestsByUser = new HashMap<>(userIds.size());
        try (PersistenceStatement statement = connection.prepare(sql)) {
            int bindIndex = 0;
            for (String userId : userIds) {
                statement.bindString(bindIndex++, userId);
            }
            statement.bindString(bindIndex, Integer.toString(limit));

            try (QueryResult result = statement.executeQuery()) {
                while (result.next()) {
                    RowCursor row = result.row();
                    String userId = row.getString(0);
                    interestsByUser.computeIfAbsent(userId, ignored -> new ArrayList<>())
                        .add(new InterestView(row.getString(1), row.getString(2), row.getString(3)));
                }
            }
        }
        return interestsByUser;
    }

    private static String buildCastBigIntInClause(int size) {
        StringBuilder placeholders = new StringBuilder(size * 18);
        for (int i = 0; i < size; i++) {
            if (i > 0) {
                placeholders.append(", ");
            }
            placeholders.append("CAST(? AS BIGINT)");
        }
        return placeholders.toString();
    }

    private static List<UserSummary> queryUsersWithoutInterestsByOrderedIds(PersistenceConnection connection,
                                                                             List<UUID> orderedIds,
                                                                             int limit) {
        String sql = READ_USERS_WITHOUT_INTERESTS_BY_ORDERED_IDS_SQL_TEMPLATE
            .formatted(buildOrderedValuesClause(orderedIds.size()));
        try (PersistenceStatement statement = connection.prepare(sql)) {
            int bindIndex = 0;
            for (UUID id : orderedIds) {
                statement.bindString(bindIndex++, id.toString());
                statement.bindString(bindIndex++, Integer.toString(bindIndex / 2));
            }
            statement.bindString(bindIndex, Integer.toString(limit));

            try (QueryResult result = statement.executeQuery()) {
                List<UserSummary> users = new ArrayList<>(Math.max(0, limit));
                while (result.next()) {
                    RowCursor row = result.row();
                    users.add(new UserSummary(row.getString(0), row.getString(1)));
                }
                return users;
            }
        }
    }

    private static String buildOrderedValuesClause(int size) {
        if (size <= 0) {
            return "";
        }
        StringBuilder values = new StringBuilder(size * 24);
        for (int i = 0; i < size; i++) {
            if (i > 0) {
                values.append(", ");
            }
            values.append("(?, CAST(? AS BIGINT))");
        }
        return values.toString();
    }

}


