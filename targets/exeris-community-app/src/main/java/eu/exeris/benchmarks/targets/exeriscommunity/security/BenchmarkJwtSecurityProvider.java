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
        return new AuthenticationResult(principal, ImmutableStorageContext.shared(principalId.toString()));
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
