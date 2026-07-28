package eu.exeris.benchmarks.targets.restateapp.application;

import com.nimbusds.jose.JWSAlgorithm;
import com.nimbusds.jose.JWSHeader;
import com.nimbusds.jose.JWSVerifier;
import com.nimbusds.jose.crypto.RSASSASigner;
import com.nimbusds.jose.crypto.RSASSAVerifier;
import com.nimbusds.jwt.JWTClaimsSet;
import com.nimbusds.jwt.SignedJWT;

import java.security.KeyPair;
import java.security.KeyPairGenerator;
import java.security.interfaces.RSAPublicKey;
import java.util.Date;
import java.util.Optional;
import java.util.UUID;

/**
 * RS256 (RSA-2048) signed JWT issue/verify — auth-crypto parity with the
 * reference stacks (quarkus-benchmark-app AuthTokenService, spring-benchmark-app
 * SecurityConfig, exeris-community-app BenchmarkTokenIssuer): keypair generated
 * at boot, token issued once on register, signature + expiry verified on every
 * authenticated request. Claims surface matches the references: sub = principal
 * UUID, iss, aud, exp (now + 1h), iat, and a {@code kid} header.
 *
 * The keypair is per-instance (one instance is created at boot; the references
 * use a static initializer — same generate-at-boot cost). Not for production use.
 */
public final class BearerTokenService {

    static final String KID = "benchmark-key-1";
    static final String ISSUER = "https://benchmark.exeris.local";
    static final String AUD = "exeris-benchmark";

    private final RSASSASigner signer;
    private final JWSVerifier verifier;

    public BearerTokenService() {
        try {
            KeyPairGenerator gen = KeyPairGenerator.getInstance("RSA");
            gen.initialize(2048);
            KeyPair keyPair = gen.generateKeyPair();
            this.signer = new RSASSASigner(keyPair.getPrivate());
            this.verifier = new RSASSAVerifier((RSAPublicKey) keyPair.getPublic());
        } catch (Exception e) {
            throw new IllegalStateException("RSA-2048 keypair generation failed", e);
        }
    }

    public String issue(UUID principalId) {
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
            jwt.sign(signer);
            return jwt.serialize();
        } catch (Exception e) {
            throw new IllegalStateException("JWT issue failed", e);
        }
    }

    /**
     * Returns the principal UUID when the token parses, the RS256 signature
     * verifies, and the token is unexpired — same checks as the quarkus
     * reference authenticate path.
     */
    public Optional<UUID> verify(String token) {
        if (token == null || token.isBlank()) {
            return Optional.empty();
        }
        try {
            SignedJWT jwt = SignedJWT.parse(token);
            if (!jwt.verify(verifier)) {
                return Optional.empty();
            }
            JWTClaimsSet claims = jwt.getJWTClaimsSet();
            Date expiresAt = claims.getExpirationTime();
            if (expiresAt == null || new Date().after(expiresAt)) {
                return Optional.empty();
            }
            return Optional.of(UUID.fromString(claims.getSubject()));
        } catch (Exception e) {
            return Optional.empty();
        }
    }
}
