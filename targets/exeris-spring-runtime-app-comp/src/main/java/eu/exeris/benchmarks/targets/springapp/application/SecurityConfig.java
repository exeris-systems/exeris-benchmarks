package eu.exeris.benchmarks.targets.springapp.application;

import com.nimbusds.jose.JOSEException;
import com.nimbusds.jose.jwk.RSAKey;
import com.nimbusds.jose.jwk.gen.RSAKeyGenerator;
import com.nimbusds.jose.jwk.JWKSet;
import com.nimbusds.jose.jwk.source.ImmutableJWKSet;

import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.core.convert.converter.Converter;
import org.springframework.security.authentication.AbstractAuthenticationToken;
import org.springframework.security.oauth2.jwt.Jwt;
import org.springframework.security.oauth2.jwt.JwtDecoder;
import org.springframework.security.oauth2.jwt.JwtEncoder;
import org.springframework.security.oauth2.jwt.NimbusJwtDecoder;
import org.springframework.security.oauth2.jwt.NimbusJwtEncoder;

import javax.sql.DataSource;

/**
 * Canonical Exeris compatibility-mode security wiring.
 *
 * <p>This target runs under {@code spring.main.web-application-type=none} (kernel-owned
 * transport, no servlet container). In that mode a servlet {@code SecurityFilterChain}
 * is inert — nothing dispatches it — and worse, its mere <em>presence</em> as a bean
 * suppresses the host-runtime's compat security filter: {@code ExerisSecurityContextFilter}
 * is gated by {@code NoSecurityFilterChainCondition}, which backs off if any bean of type
 * {@code org.springframework.security.web.SecurityFilterChain} is defined. The net effect
 * of declaring a chain here was no populated {@code SecurityContext} → {@code Authentication}
 * injected as {@code null} → NPE → HTTP 500 on every authenticated endpoint.
 *
 * <p>So we deliberately do <strong>not</strong> declare {@code @EnableWebSecurity} or a
 * {@code SecurityFilterChain}. Instead we expose the pieces the compat runtime consumes:
 * <ul>
 *   <li>{@link JwtDecoder} — picked up by {@code ExerisSecurityContextFilter}
 *       (which is {@code @ConditionalOnBean(JwtDecoder)} and stands down its own
 *       compat decoder via {@code @ConditionalOnMissingBean} when this bean exists);</li>
 *   <li>a {@link Converter Converter&lt;Jwt, AbstractAuthenticationToken&gt;} bean
 *       ({@link UserIdJwtAuthenticationConverter}) — resolved by the filter through an
 *       {@code ObjectProvider}, so the principal becomes the numeric {@code user_id}
 *       rather than the raw JWT subject UUID;</li>
 *   <li>{@link JwtEncoder} / {@link RSAKey} — used by {@code /api/v1/auth/register} to
 *       mint tokens for the benchmark workload.</li>
 * </ul>
 *
 * <p>Do not re-introduce {@code @EnableWebSecurity} or a {@code SecurityFilterChain} bean:
 * under {@code web-application-type=none} they are dead weight and re-break the compat path.
 */
@Configuration
public class SecurityConfig {

    private static final RSAKey RSA_KEY;

    static {
        try {
            RSA_KEY = new RSAKeyGenerator(2048)
                    .keyID("benchmark-key-1")
                    .generate();
        } catch (JOSEException e) {
            throw new ExceptionInInitializerError(e);
        }
    }

    @Bean
    public RSAKey rsaKey() {
        return RSA_KEY;
    }

    @Bean
    public JwtEncoder jwtEncoder(RSAKey rsaKey) {
        return new NimbusJwtEncoder(new ImmutableJWKSet<>(new JWKSet(rsaKey)));
    }

    @Bean
    public JwtDecoder jwtDecoder(RSAKey rsaKey) throws JOSEException {
        return NimbusJwtDecoder.withPublicKey(rsaKey.toRSAPublicKey()).build();
    }

    /**
     * Resolves the numeric {@code user_id} from the JWT subject via a per-request DB lookup,
     * matching Exeris Community's identity-resolution cost. Consumed by the host-runtime's
     * {@code ExerisSecurityContextFilter} through an {@code ObjectProvider}, so it must be a
     * bean (it was previously buried inline inside the now-removed servlet chain).
     */
    @Bean
    public Converter<Jwt, AbstractAuthenticationToken> jwtAuthenticationConverter(DataSource dataSource) {
        return new UserIdJwtAuthenticationConverter(dataSource);
    }
}
