package eu.exeris.benchmarks.targets.restateapp.application;

import javax.sql.DataSource;
import java.sql.Connection;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.util.Optional;
import java.util.UUID;

/**
 * Registration path — mirrors spring-benchmark-app AuthTokenService: one
 * transaction inserting users + user_principals, then a bearer token issue.
 * A unique violation (retried username) surfaces as empty → HTTP 409.
 */
public final class AuthTokenService {

    private static final String INSERT_USER_SQL =
        "INSERT INTO users (username, email, password_hash) VALUES (?, ?, ?) RETURNING id";

    private static final String INSERT_PRINCIPAL_SQL =
        "INSERT INTO user_principals (principal_uuid, user_id) VALUES (?::uuid, ?)";

    private final DataSource dataSource;
    private final BearerTokenService tokenService;

    public AuthTokenService(DataSource dataSource, BearerTokenService tokenService) {
        this.dataSource = dataSource;
        this.tokenService = tokenService;
    }

    public Optional<RegisteredUser> register(String rawUsername, String rawEmail, String password) {
        String username = rawUsername.trim();
        String email = rawEmail.trim().toLowerCase();
        UUID principalId = UUID.randomUUID();
        try (Connection conn = dataSource.getConnection()) {
            conn.setAutoCommit(false);
            long userId;
            try (PreparedStatement userStmt = conn.prepareStatement(INSERT_USER_SQL)) {
                userStmt.setString(1, username);
                userStmt.setString(2, email);
                userStmt.setString(3, password);
                try (ResultSet rs = userStmt.executeQuery()) {
                    if (!rs.next()) {
                        conn.rollback();
                        return Optional.empty();
                    }
                    userId = rs.getLong(1);
                }
            }
            try (PreparedStatement principalStmt = conn.prepareStatement(INSERT_PRINCIPAL_SQL)) {
                principalStmt.setString(1, principalId.toString());
                principalStmt.setLong(2, userId);
                principalStmt.executeUpdate();
            }
            conn.commit();
            String token = tokenService.issue(userId);
            return Optional.of(new RegisteredUser(Long.toString(userId), username, email, token));
        } catch (Exception e) {
            return Optional.empty();
        }
    }

    public record RegisteredUser(String userId, String username, String email, String token) {}
}
