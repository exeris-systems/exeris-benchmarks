package eu.exeris.benchmarks.targets.exeriscommunity.security;

import com.nimbusds.jose.JOSEException;
import com.nimbusds.jose.JWSAlgorithm;
import com.nimbusds.jose.crypto.RSASSAVerifier;
import com.nimbusds.jwt.JWTClaimsSet;
import com.nimbusds.jwt.SignedJWT;

import eu.exeris.kernel.spi.exceptions.security.SecurityAuthenticationException;
import eu.exeris.kernel.spi.memory.LoanedBuffer;
import eu.exeris.kernel.spi.security.AuthenticationResult;
import eu.exeris.kernel.spi.security.ImmutablePrincipal;
import eu.exeris.kernel.spi.security.ImmutableStorageContext;
import eu.exeris.kernel.spi.security.SecurityProvider;
import eu.exeris.kernel.spi.security.StorageContext;

import java.lang.foreign.MemorySegment;
import java.lang.foreign.ValueLayout;
import java.nio.charset.StandardCharsets;
import java.security.interfaces.RSAPublicKey;
import java.text.ParseException;
import java.time.Instant;
import java.util.Date;
import java.util.Map;
import java.util.Optional;
import java.util.Set;
import java.util.UUID;

/**
 * App-owned SPI {@link SecurityProvider} that validates the RS256 JWTs minted by
 * {@link BenchmarkTokenIssuer}. Implemented purely against {@code eu.exeris.kernel.spi.*} and Nimbus
 * (already a dependency of this target), so the benchmark no longer imports
 * {@code eu.exeris.kernel.community.security.CommunitySecurityProvider} and stays edition-agnostic:
 * SPI + CORE is the compile base, the kernel edition is a runtime driver.
 *
 * <p>The observable contract mirrors the kernel {@code SecurityProvider} the app used before:
 * <ul>
 *   <li>{@link #authenticate} throws {@link SecurityAuthenticationException} on any failure — the
 *       core {@code SecurityInterceptor} maps that to HTTP 401;</li>
 *   <li>on success it returns an {@link AuthenticationResult} whose principal id is the token
 *       subject (a {@link UUID}) and whose storage context uses the {@code SHARED} isolation
 *       strategy — exactly what {@code CommunityBenchmarkRouteHandler} consumes
 *       ({@code PRINCIPAL_CONTEXT.principalId()} plus the {@code SHARED}-strategy RLS-key
 *       alignment).</li>
 * </ul>
 *
 * <p>Not for production use — the keys are generated in-process by the benchmark token issuer.
 */
public final class BenchmarkJwtSecurityProvider implements SecurityProvider {

    private static final String TOKEN_TYPE = "JWT";

    private final Map<String, RSAPublicKey> keysByKid;
    private final String issuer;
    private final String audience;

    public BenchmarkJwtSecurityProvider(Map<String, RSAPublicKey> keysByKid,
                                        String issuer,
                                        String audience) {
        this.keysByKid = Map.copyOf(keysByKid);
        this.issuer = issuer;
        this.audience = audience;
    }

    @Override
    public String providerId() {
        return "jwt-benchmark";
    }

    @Override
    public String providerName() {
        return "ExerisBenchmark/JWT";
    }

    @Override
    public AuthenticationResult authenticate(LoanedBuffer token) {
        SignedJWT jwt = parse(readToken(token));

        String kid = jwt.getHeader().getKeyID();
        if (kid == null) {
            throw new SecurityAuthenticationException(TOKEN_TYPE, "missing-kid");
        }
        RSAPublicKey key = keysByKid.get(kid);
        if (key == null) {
            throw new SecurityAuthenticationException(TOKEN_TYPE, "unknown-kid");
        }
        if (!JWSAlgorithm.RS256.equals(jwt.getHeader().getAlgorithm())) {
            throw new SecurityAuthenticationException(TOKEN_TYPE, "unsupported-alg");
        }
        verifySignature(jwt, key);

        JWTClaimsSet claims = claims(jwt);
        if (!issuer.equals(claims.getIssuer())) {
            throw new SecurityAuthenticationException(TOKEN_TYPE, "invalid-issuer");
        }
        if (claims.getAudience() == null || !claims.getAudience().contains(audience)) {
            throw new SecurityAuthenticationException(TOKEN_TYPE, "invalid-audience");
        }
        Date expiry = claims.getExpirationTime();
        if (expiry == null || expiry.toInstant().isBefore(Instant.now())) {
            throw new SecurityAuthenticationException(TOKEN_TYPE, "token-expired");
        }

        UUID principalId = subject(claims);
        ImmutablePrincipal principal =
            new ImmutablePrincipal(principalId, Optional.empty(), Set.of(), Set.of());
        // GLOBAL, not shared(principalId), since 2026-08-20.
        //
        // A per-subject isolation key is what CONTRACT-v2 calls an unmatched axis here: the
        // Quarkus and Spring arms carry no tenant isolation at all, so keying exeris per user
        // made it do work the comparison does not ask for. And it bought nothing -- the
        // benchmark database has ZERO row-security policies and ZERO tables with RLS enabled
        // (checked, not assumed), so the key steered pool and scope selection without ever
        // being read by a policy.
        //
        // It was not free. The kernel's engine has two entry points -- openConnection() keyed
        // "shared" and openConnection(ctx) keyed from the context -- and a request that touches
        // both mismatches, emitting BYPASS_SCOPE_MISMATCH and taking a second connection
        // outside its own request session. Measured on the 2026-08-19 campaign: 548 683
        // bypasses against 274 514 request sessions, exactly 2.0 per session, which is why this
        // arm exhausted even a 128-connection pool while quarkus-lra-jdbc peaked at 21.
        //
        // Worse than the arithmetic: the bypass path does not run ConnectionInterceptors, so
        // under RLS it hands the request a connection still carrying the previous borrower's
        // tenant GUC. A kernel-side integration test confirmed a cross-tenant read through it.
        // That defect is not ours to fix, but choosing a per-subject key is what puts this
        // scenario on the exact configuration where it fires -- with none of the isolation it
        // would otherwise be paying for.
        //
        // If this scenario ever wants to measure tenant isolation, that is a separate labelled
        // axis with RLS actually enabled, not a silent surcharge inside "cost of a saga".
        return new AuthenticationResult(principal, ImmutableStorageContext.GLOBAL);
    }

    @Override
    public StorageContext systemStorageContext() {
        return ImmutableStorageContext.system();
    }

    private void verifySignature(SignedJWT jwt, RSAPublicKey key) {
        try {
            if (!jwt.verify(new RSASSAVerifier(key))) {
                throw new SecurityAuthenticationException(TOKEN_TYPE, "signature-invalid");
            }
        } catch (JOSEException e) {
            throw new SecurityAuthenticationException(TOKEN_TYPE, "signature-invalid");
        }
    }

    private static SignedJWT parse(String raw) {
        try {
            return SignedJWT.parse(raw);
        } catch (ParseException e) {
            throw new SecurityAuthenticationException(TOKEN_TYPE, "malformed-token");
        }
    }

    private static JWTClaimsSet claims(SignedJWT jwt) {
        try {
            return jwt.getJWTClaimsSet();
        } catch (ParseException e) {
            throw new SecurityAuthenticationException(TOKEN_TYPE, "claims-missing");
        }
    }

    private static UUID subject(JWTClaimsSet claims) {
        String subject = claims.getSubject();
        if (subject == null || subject.isBlank()) {
            throw new SecurityAuthenticationException(TOKEN_TYPE, "subject-missing");
        }
        try {
            return UUID.fromString(subject);
        } catch (IllegalArgumentException e) {
            throw new SecurityAuthenticationException(TOKEN_TYPE, "invalid-subject");
        }
    }

    private static String readToken(LoanedBuffer token) {
        long size = token.size();
        if (size <= 0L) {
            throw new SecurityAuthenticationException(TOKEN_TYPE, "empty-token");
        }
        MemorySegment bytes = token.segment().asSlice(0L, size);
        return new String(bytes.toArray(ValueLayout.JAVA_BYTE), StandardCharsets.UTF_8);
    }
}
