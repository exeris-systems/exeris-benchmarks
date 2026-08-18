package eu.exeris.benchmarks.targets.springapp.application;

import com.nimbusds.jose.JOSEException;
import com.nimbusds.jose.jwk.RSAKey;
import com.nimbusds.jose.jwk.gen.RSAKeyGenerator;
import com.nimbusds.jose.jwk.JWKSet;
import com.nimbusds.jose.jwk.source.ImmutableJWKSet;

import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.http.HttpMethod;
import org.springframework.security.config.annotation.web.builders.HttpSecurity;
import org.springframework.security.config.annotation.web.configuration.EnableWebSecurity;
import org.springframework.security.config.http.SessionCreationPolicy;
import org.springframework.security.oauth2.jwt.JwtDecoder;
import org.springframework.security.oauth2.jwt.JwtEncoder;
import org.springframework.security.oauth2.jwt.NimbusJwtDecoder;
import org.springframework.security.oauth2.jwt.NimbusJwtEncoder;
import org.springframework.security.web.SecurityFilterChain;

import javax.sql.DataSource;

@Configuration
@EnableWebSecurity
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

    @Bean
    public SecurityFilterChain filterChain(HttpSecurity http, JwtDecoder jwtDecoder, DataSource dataSource) throws Exception {
        return http
                .csrf(csrf -> csrf.disable())
                .sessionManagement(session -> session.sessionCreationPolicy(SessionCreationPolicy.STATELESS))
                .authorizeHttpRequests(auth -> auth
                        // /db/ping is a DB-connectivity readiness probe (like /health), hit by the
                        // comparative harness Stage-4 preflight. It is served unauthenticated by
                        // exeris-community-app and quarkus-benchmark-app; permit it here too so the
                        // entity-read-by-id readiness gate is apples-to-apples and Spring is not the
                        // only runtime forcing an auth filter on an infra probe.
                        .requestMatchers("/api/v1/auth/register", "/health", "/actuator/**", "/db/ping").permitAll()
                        // GET /api/v1/users is unauthenticated in the reference exeris-community-app
                        // (CommunityBenchmarkRouteHandler.handleUsers — no SecurityInterceptor) and in
                        // quarkus-benchmark-app; permit it here so the entity-read-by-id read benchmark
                        // is apples-to-apples across runtimes. Per-user / cart / order routes stay authenticated.
                        .requestMatchers(HttpMethod.GET, "/api/v1/users").permitAll()
                        // GET /api/v1/user (singular, light single-read contract) for the same reason:
                        // unauthenticated in exeris-community-app and quarkus-benchmark-app. Note the
                        // matcher above does NOT cover it — "/api/v1/users" is an exact path, so without
                        // this line the light contract would measure a 401 from the auth filter instead
                        // of the read path.
                        .requestMatchers(HttpMethod.GET, "/api/v1/user").permitAll()
                        .anyRequest().authenticated())
                // NOTE (smoke-verified 2026-08-01): "/error" is not permitted here, so any request
                // that raises an exception is forwarded to /error and re-authorized, surfacing as
                // 401 rather than its true status — e.g. ?id=abc and a missing id both return 401
                // instead of 400. Measured traffic always sends a valid ?id=N and never hits this,
                // and the behaviour predates the light contract, so it is left as-is rather than
                // changed mid-campaign-series. But do not read a 401 during a run as an auth
                // problem: check the app log for the underlying exception first.
                .oauth2ResourceServer(oauth2 -> oauth2
                        .jwt(jwt -> jwt
                                .decoder(jwtDecoder)
                                .jwtAuthenticationConverter(new UserIdJwtAuthenticationConverter(dataSource))))
                .build();
    }
}
