package eu.exeris.benchmarks.targets.springapp.application;

import org.springframework.core.convert.converter.Converter;
import org.springframework.security.authentication.AbstractAuthenticationToken;
import org.springframework.security.oauth2.jwt.Jwt;
import org.springframework.security.oauth2.server.resource.authentication.JwtAuthenticationToken;

import javax.sql.DataSource;
import java.sql.Connection;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.util.List;

/**
 * After JWT signature verification by Spring Security, resolves the numeric user_id
 * from user_principals by principal_uuid (JWT subject). This matches Exeris Community's
 * per-request DB lookup for user identity resolution — ensuring comparable auth cost.
 */
public class UserIdJwtAuthenticationConverter implements Converter<Jwt, AbstractAuthenticationToken> {

    private static final String FIND_USER_ID_SQL =
            "SELECT user_id FROM user_principals WHERE principal_uuid = ?::uuid";

    private final DataSource dataSource;

    public UserIdJwtAuthenticationConverter(DataSource dataSource) {
        this.dataSource = dataSource;
    }

    @Override
    public AbstractAuthenticationToken convert(Jwt jwt) {
        String principalUuid = jwt.getSubject();
        String userId = resolveUserId(principalUuid);
        if (userId == null) {
            throw new org.springframework.security.authentication.BadCredentialsException(
                    "principal not found: " + principalUuid);
        }
        return new JwtAuthenticationToken(jwt, List.of(), userId);
    }

    private String resolveUserId(String principalUuid) {
        try (Connection conn = dataSource.getConnection();
             PreparedStatement stmt = conn.prepareStatement(FIND_USER_ID_SQL)) {
            stmt.setString(1, principalUuid);
            try (ResultSet rs = stmt.executeQuery()) {
                if (rs.next()) {
                    return Long.toString(rs.getLong(1));
                }
                return null;
            }
        } catch (Exception e) {
            return null;
        }
    }
}
