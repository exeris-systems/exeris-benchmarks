package eu.exeris.benchmarks.targets.springapp.application;

import eu.exeris.benchmarks.targets.springapp.api.RegisterRequest;

import org.springframework.security.oauth2.jwt.JwtClaimsSet;
import org.springframework.security.oauth2.jwt.JwtEncoder;
import org.springframework.security.oauth2.jwt.JwtEncoderParameters;
import org.springframework.stereotype.Service;

import javax.sql.DataSource;
import java.sql.Connection;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.time.Duration;
import java.time.Instant;
import java.util.List;
import java.util.Optional;
import java.util.UUID;

@Service
public class AuthTokenService {

    private static final String INSERT_USER_SQL =
        "INSERT INTO users (username, email, password_hash) VALUES (?, ?, ?) RETURNING id";

    private static final String INSERT_PRINCIPAL_SQL =
        "INSERT INTO user_principals (principal_uuid, user_id) VALUES (?::uuid, ?)";

    private final DataSource dataSource;
    private final JwtEncoder jwtEncoder;

    public AuthTokenService(DataSource dataSource, JwtEncoder jwtEncoder) {
        this.dataSource = dataSource;
        this.jwtEncoder = jwtEncoder;
    }

    public Optional<RegisteredUser> register(RegisterRequest request) {
        String username = request.username().trim();
        String email = request.email().trim().toLowerCase();
        UUID principalId = UUID.randomUUID();
        try (Connection conn = dataSource.getConnection()) {
            conn.setAutoCommit(false);
            long userId;
            try (PreparedStatement userStmt = conn.prepareStatement(INSERT_USER_SQL)) {
                userStmt.setString(1, username);
                userStmt.setString(2, email);
                userStmt.setString(3, request.password());
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
            String token = issueToken(principalId);
            return Optional.of(new RegisteredUser(Long.toString(userId), username, email, token));
        } catch (Exception e) {
            return Optional.empty();
        }
    }

    private String issueToken(UUID principalId) {
        Instant now = Instant.now();
        JwtClaimsSet claims = JwtClaimsSet.builder()
                .issuer("https://benchmark.exeris.local")
                .issuedAt(now)
                .expiresAt(now.plus(Duration.ofHours(1)))
                .subject(principalId.toString())
                .audience(List.of("exeris-benchmark"))
                .build();
        return jwtEncoder.encode(JwtEncoderParameters.from(claims)).getTokenValue();
    }

    public record RegisteredUser(String userId, String username, String email, String token) {}
}
