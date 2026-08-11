package eu.exeris.benchmarks.targets.springapp.application;

import org.springframework.boot.autoconfigure.condition.ConditionalOnProperty;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.http.HttpMethod;
import org.springframework.security.config.annotation.web.builders.HttpSecurity;
import org.springframework.security.config.annotation.web.configuration.EnableWebSecurity;
import org.springframework.security.config.http.SessionCreationPolicy;
import org.springframework.security.oauth2.jwt.JwtDecoder;
import org.springframework.security.web.SecurityFilterChain;

import javax.sql.DataSource;

/**
 * The servlet {@link SecurityFilterChain} — the only part of this application's security setup
 * that costs anything per request — behind a switch.
 *
 * <p>Default is ON ({@code matchIfMissing = true}), so {@code spring-hibernate} is unchanged and
 * this annotation is a no-op unless the property is explicitly set to false.
 *
 * <h2>Why the switch exists</h2>
 *
 * <p>The hosting rung in the Spring ladder — {@code spring-hibernate} to
 * {@code spring-on-exeris-pure}, 121.52 us/req, x1.127 — crosses an unmeasured boundary. This arm
 * runs a filter chain that reaches an authorization decision on every request even when the match
 * is {@code permitAll}; the Exeris arm carries no Spring Security at all. The repo's fairness
 * rules forbid borrowing the Exeris-side bound (+0.14 %) for it, because a {@code FilterChainProxy}
 * dispatch with {@code SecurityContextHolder} lifecycle and {@code AuthorizationManager} evaluation
 * is a different and heavier mechanism. Against a 121.52 us step, a chain costing 10 / 20 / 30 us
 * would be 8.2 / 16.5 / 24.7 % of the entire hosting gain.
 *
 * <h2>Why this class exists separately from SecurityConfig</h2>
 *
 * <p>Boot-verify forced the split, and the failure is worth recording: gating the whole of
 * {@code SecurityConfig} also removed its {@code JwtEncoder} bean, which {@code AuthTokenService}
 * requires, and the application refused to start. Only the chain belongs behind the switch — the
 * JWT key material and codecs stay unconditional because they cost nothing on the request path.
 * Keeping them also means the two arms differ by the chain alone rather than by a bean graph.
 *
 * <p>Disabling this bean is still not sufficient on its own: with
 * {@code spring-boot-starter-security} on the classpath, Boot's {@code SecurityAutoConfiguration}
 * would install a DEFAULT chain (HTTP basic + form login), which is MORE per-request work than the
 * permitAll chain below. The {@code spring-hibernate-nosec} env file therefore also excludes the
 * three security auto-configurations. Boot-verify contract: no {@code springSecurityFilterChain}
 * registration in the log, and 200 on both read endpoints with no Authorization header.
 */
@Configuration
@EnableWebSecurity
@ConditionalOnProperty(
        name = "benchmark.security.filter-chain.enabled",
        havingValue = "true",
        matchIfMissing = true)
public class SecurityFilterChainConfig {

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
