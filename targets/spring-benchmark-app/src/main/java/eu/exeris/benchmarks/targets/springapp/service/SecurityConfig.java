package eu.exeris.benchmarks.targets.springapp.application;

import com.nimbusds.jose.JOSEException;
import com.nimbusds.jose.jwk.RSAKey;
import com.nimbusds.jose.jwk.gen.RSAKeyGenerator;
import com.nimbusds.jose.jwk.JWKSet;
import com.nimbusds.jose.jwk.source.ImmutableJWKSet;

import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.security.oauth2.jwt.JwtDecoder;
import org.springframework.security.oauth2.jwt.JwtEncoder;
import org.springframework.security.oauth2.jwt.NimbusJwtDecoder;
import org.springframework.security.oauth2.jwt.NimbusJwtEncoder;

import javax.sql.DataSource;

/**
 * JWT key material and codecs. Always loaded — {@code AuthTokenService} needs {@link JwtEncoder},
 * and none of these beans costs anything on the request path.
 *
 * <p>The per-request servlet {@link org.springframework.security.web.SecurityFilterChain} lives in
 * {@link SecurityFilterChainConfig}, which is switchable. Splitting them was forced by boot-verify:
 * gating this whole class removed {@code JwtEncoder} and the application failed to start.
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
}
