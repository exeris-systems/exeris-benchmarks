package eu.exeris.benchmarks.targets.exeriscommunity.infrastructure.persistence;

import eu.exeris.kernel.spi.persistence.PersistenceStatement;
import eu.exeris.kernel.spi.persistence.QueryResult;
import eu.exeris.kernel.spi.persistence.TransactionalExecutor;
import java.util.OptionalLong;
import java.util.UUID;

public final class PrincipalRepository {

    private static final String INSERT_USER_SQL =
        "INSERT INTO users (username, email, password_hash) VALUES (?, ?, ?) RETURNING id";

    private static final String INSERT_PRINCIPAL_SQL =
        "INSERT INTO user_principals (principal_uuid, user_id) VALUES (CAST(? AS UUID), ?)";

    private static final String FIND_USER_ID_BY_PRINCIPAL_SQL =
        "SELECT user_id FROM user_principals WHERE principal_uuid = CAST(? AS UUID)";

    private final TransactionalExecutor executor;

    public PrincipalRepository(TransactionalExecutor executor) {
        this.executor = executor;
    }

    public OptionalLong createUserAndBindPrincipal(String username,
                                                   String email,
                                                   String passwordHash,
                                                   UUID principalId) {
        long[] createdUserId = {-1L};
        try {
            executor.executeManaged(conn -> {
                try (PersistenceStatement createUserStmt = conn.prepare(INSERT_USER_SQL)) {
                    createUserStmt.bindString(0, username)
                        .bindString(1, email)
                        .bindString(2, passwordHash);
                    try (QueryResult result = createUserStmt.executeQuery()) {
                        if (!result.next()) {
                            throw new IllegalStateException("Cannot create user");
                        }
                        createdUserId[0] = result.row().getLong(0);
                    }
                }

                try (PersistenceStatement bindStmt = conn.prepare(INSERT_PRINCIPAL_SQL)) {
                    bindStmt.bindString(0, principalId.toString())
                        .bindLong(1, createdUserId[0])
                        .executeUpdate();
                }
            });
            return OptionalLong.of(createdUserId[0]);
        } catch (RuntimeException exception) {
            return OptionalLong.empty();
        }
    }

    public OptionalLong findUserIdByPrincipal(UUID principalId) {
        Long value = executor.query(conn -> {
            try (PersistenceStatement stmt = conn.prepare(FIND_USER_ID_BY_PRINCIPAL_SQL)) {
                stmt.bindString(0, principalId.toString());
                try (QueryResult result = stmt.executeQuery()) {
                    return result.next() ? result.row().getLong(0) : null;
                }
            }
        });
        return value == null ? OptionalLong.empty() : OptionalLong.of(value);
    }
}
