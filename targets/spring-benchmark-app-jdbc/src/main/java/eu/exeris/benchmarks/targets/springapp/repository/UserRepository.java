package eu.exeris.benchmarks.targets.springapp;

import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Repository;

import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;

/**
 * Tomcat + Spring MVC + plain JDBC — the ORM-free counterpart of {@code spring-hibernate}.
 *
 * <h2>Why this target exists</h2>
 *
 * <p>Until this arm, the persistence axis was measured only along one diagonal: Hibernate was
 * removed at the same time the web layer moved to Exeris, so the ORM's cost was measured on the
 * Exeris-hosted arm and then <em>applied</em> to Tomcat. That assumption — that Hibernate costs
 * the same under Tomcat as under Exeris — is the load-bearing premise of the Amdahl ceiling that
 * sets migration order (docs/CLAIMS.md L3). It was supported by the ladder closing to +2.0 % on
 * the ceiling-free metric, but never measured. With this arm it is measured:
 *
 * <pre>
 *                    ORM (Hibernate)          no ORM (hand-written SQL)
 *   Tomcat           spring-hibernate         spring-jdbc          &lt;- this
 *   Exeris pure      spring-on-exeris-pure    spring-on-exeris-pure-native
 * </pre>
 *
 * <p>It is also the honest commercial comparator: the cheapest change a Spring team can make,
 * involving no Exeris at all. If most of the heavy-contract gain is available by deleting
 * Hibernate alone, the runtime's claim must be stated as the increment on top of that, not as
 * the whole distance from the ORM arm.
 *
 * <h2>SQL SHAPES ARE MATCHED; THE IMPLEMENTATION IS NOT</h2>
 *
 * <p>Every statement below is shape-identical to {@code app-pure-native}'s UserRepository and to
 * {@code quarkus-jdbc}: same projections, same predicates, same ORDER BY, same
 * {@code row_number() OVER (PARTITION BY ...)} windowing, same three-queries-per-heavy-request
 * structure. What is deliberately NOT mirrored is the mechanism — this arm uses
 * {@link JdbcTemplate}, because that is what a Spring team actually writes. Hand-rolling
 * {@code Connection}/{@code PreparedStatement} to mimic the kernel API would measure a codebase
 * nobody would ship. The JdbcTemplate overhead is part of what the "Spring without ORM" option
 * costs, and belongs in the number.
 *
 * <h2>Bind and accessor equalization</h2>
 *
 * <p>Carried over from the other JDBC arms and not incidental: ids bind as typed {@code long}
 * (never text + CAST) and BIGINT columns are read with {@code getLong} rather than
 * {@code getString}, which avoids pgjdbc's getString-on-int8 path (initSqlType/trimString).
 * Text columns use {@code getString}. Deviating here would make this arm's cost differ from the
 * other no-ORM arms for reasons that have nothing to do with the axis under test.
 *
 * <h2>Transaction boundary</h2>
 *
 * <p>The heavy read keeps {@code @Transactional(readOnly = true)} on {@code UserService}, exactly
 * as the Hibernate arm does, so all three queries run on one connection in one transaction. That
 * is the analogue of the ORM arm's single-EntityManager boundary and of pure-native's
 * {@code inReadSession}. Dropping it here would hand this arm a connection-per-query profile and
 * silently change what the ORM comparison measures.
 */
@Repository
public class UserRepository {

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

    private final JdbcTemplate jdbcTemplate;

    public UserRepository(JdbcTemplate jdbcTemplate) {
        this.jdbcTemplate = jdbcTemplate;
    }

    public List<UserSummary> findTopUsers(int limit) {
        if (limit <= 0) {
            return List.of();
        }
        return jdbcTemplate.query(
                READ_TOP_USERS_SQL,
                (rs, rowNum) -> new UserSummary(Long.toString(rs.getLong(1)), rs.getString(2)),
                limit);
    }

    /**
     * Single-row PK read. The no-ORM counterpart of the Hibernate arm's
     * {@code findById(id)} — same row, same projection, no entity hydration. That missing
     * hydration step is exactly what the light contract measures on this axis.
     *
     * <p>Returns null rather than Optional.empty() for a missing row: the Hibernate arm's
     * findUserById returns null and the controller maps that to 404. Same contract here.
     */
    public UserSummary findUserById(long id) {
        List<UserSummary> rows = jdbcTemplate.query(
                READ_USER_BY_ID_SQL,
                (rs, rowNum) -> new UserSummary(Long.toString(rs.getLong(1)), rs.getString(2)),
                id);
        return rows.isEmpty() ? null : rows.get(0);
    }

    public List<FriendSummary> findFriendsForUser(String userId, int limit) {
        if (limit <= 0) {
            return List.of();
        }
        return jdbcTemplate.query(
                READ_FRIENDS_SQL,
                (rs, rowNum) -> new FriendSummary(Long.toString(rs.getLong(1)), rs.getString(2)),
                parseNumericId(userId), (long) limit);
    }

    public List<InterestView> findInterestsForUser(String userId, int limit) {
        if (limit <= 0) {
            return List.of();
        }
        return jdbcTemplate.query(
                READ_INTERESTS_SQL,
                (rs, rowNum) -> new InterestView(
                        Long.toString(rs.getLong(1)), rs.getString(2), rs.getString(3)),
                parseNumericId(userId), (long) limit);
    }

    /**
     * Heavy-contract read: three queries, one transaction. The caller
     * ({@code UserService#findFrozenContractUsers}) holds the readOnly transaction, so all three
     * run on one connection — matching the ORM arm's EntityManager boundary rather than opening
     * three.
     */
    public List<UserView> findTopUsersWithDetails(int userLimit, int friendLimit, int interestLimit) {
        List<UserSummary> users = findTopUsers(userLimit);
        if (users.isEmpty()) {
            return List.of();
        }

        List<String> userIds = new ArrayList<>(users.size());
        for (UserSummary user : users) {
            userIds.add(user.id());
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

    private Map<String, List<FriendSummary>> findFriendsForUsers(List<String> userIds, int limit) {
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

        Object[] args = buildIdArgs(userIds, limit);
        Map<String, List<FriendSummary>> friendsByUser = new HashMap<>(userIds.size());
        jdbcTemplate.query(sql, rs -> {
            String userId = Long.toString(rs.getLong(1));
            friendsByUser.computeIfAbsent(userId, ignored -> new ArrayList<>())
                    .add(new FriendSummary(Long.toString(rs.getLong(2)), rs.getString(3)));
        }, args);
        return friendsByUser;
    }

    private Map<String, List<InterestView>> findInterestsForUsers(List<String> userIds, int limit) {
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

        Object[] args = buildIdArgs(userIds, limit);
        Map<String, List<InterestView>> interestsByUser = new HashMap<>(userIds.size());
        jdbcTemplate.query(sql, rs -> {
            String userId = Long.toString(rs.getLong(1));
            interestsByUser.computeIfAbsent(userId, ignored -> new ArrayList<>())
                    .add(new InterestView(
                            Long.toString(rs.getLong(2)), rs.getString(3), rs.getString(4)));
        }, args);
        return interestsByUser;
    }

    // Ids bind as typed long, the limit last — matching the placeholder order in both windowed
    // statements and the bind types the other no-ORM arms use.
    private static Object[] buildIdArgs(List<String> userIds, int limit) {
        Object[] args = new Object[userIds.size() + 1];
        for (int i = 0; i < userIds.size(); i++) {
            args[i] = parseNumericId(userIds.get(i));
        }
        args[userIds.size()] = limit;
        return args;
    }

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

    private static long parseNumericId(String userId) {
        try {
            return Long.parseLong(userId);
        } catch (NumberFormatException ex) {
            throw new IllegalArgumentException("userId is not numeric: " + userId, ex);
        }
    }
}
