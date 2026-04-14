package eu.exeris.benchmarks.targets.quarkusapp.service;

import eu.exeris.benchmarks.targets.quarkusapp.dto.RegisterRequest;

import com.nimbusds.jose.JWSAlgorithm;
import com.nimbusds.jose.JWSHeader;
import com.nimbusds.jose.JWSVerifier;
import com.nimbusds.jose.crypto.RSASSASigner;
import com.nimbusds.jose.crypto.RSASSAVerifier;
import com.nimbusds.jwt.JWTClaimsSet;
import com.nimbusds.jwt.SignedJWT;

import jakarta.enterprise.context.ApplicationScoped;
import jakarta.inject.Inject;

import javax.sql.DataSource;
import java.security.KeyPair;
import java.security.KeyPairGenerator;
import java.security.interfaces.RSAPublicKey;
import java.sql.Connection;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.util.Date;
import java.util.Optional;
import java.util.UUID;

@ApplicationScoped
public class AuthTokenService {

    private static final String KID = "benchmark-key-1";
    private static final String ISSUER = "https://benchmark.exeris.local";
    private static final String AUD = "exeris-benchmark";

    private static final KeyPair KEY_PAIR;
    private static final RSASSASigner SIGNER;
    private static final JWSVerifier VERIFIER;

    static {
        try {
            KeyPairGenerator gen = KeyPairGenerator.getInstance("RSA");
            gen.initialize(2048);
            KEY_PAIR = gen.generateKeyPair();
            SIGNER = new RSASSASigner(KEY_PAIR.getPrivate());
            VERIFIER = new RSASSAVerifier((RSAPublicKey) KEY_PAIR.getPublic());
        } catch (Exception e) {
            throw new ExceptionInInitializerError(e);
        }
    }

    private static final String INSERT_USER_SQL =
        "INSERT INTO users (username, email, password_hash) VALUES (?, ?, ?) RETURNING id";

    private static final String INSERT_PRINCIPAL_SQL =
        "INSERT INTO user_principals (principal_uuid, user_id) VALUES (?::uuid, ?)";

    private static final String FIND_USER_ID_SQL =
        "SELECT user_id FROM user_principals WHERE principal_uuid = ?::uuid";

    @Inject
    DataSource dataSource;

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

    public Optional<String> authenticate(String authorizationHeader) {
        if (authorizationHeader == null || !authorizationHeader.startsWith("Bearer ")) {
            return Optional.empty();
        }
        String token = authorizationHeader.substring("Bearer ".length()).trim();
        if (token.isEmpty()) {
            return Optional.empty();
        }
        try {
            SignedJWT jwt = SignedJWT.parse(token);
            if (!jwt.verify(VERIFIER)) {
                return Optional.empty();
            }
            JWTClaimsSet claims = jwt.getJWTClaimsSet();
            if (new Date().after(claims.getExpirationTime())) {
                return Optional.empty();
            }
            UUID principalId = UUID.fromString(claims.getSubject());
            try (Connection conn = dataSource.getConnection();
                 PreparedStatement stmt = conn.prepareStatement(FIND_USER_ID_SQL)) {
                stmt.setString(1, principalId.toString());
                try (ResultSet rs = stmt.executeQuery()) {
                    if (!rs.next()) {
                        return Optional.empty();
                    }
                    return Optional.of(Long.toString(rs.getLong(1)));
                }
            }
        } catch (Exception e) {
            return Optional.empty();
        }
    }

    private static String issueToken(UUID principalId) {
        try {
            JWSHeader header = new JWSHeader.Builder(JWSAlgorithm.RS256).keyID(KID).build();
            Date now = new Date();
            Date exp = new Date(now.getTime() + 3_600_000L);
            JWTClaimsSet claims = new JWTClaimsSet.Builder()
                .subject(principalId.toString())
                .issuer(ISSUER)
                .audience(AUD)
                .expirationTime(exp)
                .issueTime(now)
                .build();
            SignedJWT jwt = new SignedJWT(header, claims);
            jwt.sign(SIGNER);
            return jwt.serialize();
        } catch (Exception e) {
            throw new RuntimeException("JWT issue failed", e);
        }
    }

    public record RegisteredUser(String userId, String username, String email, String token) {
    }
}