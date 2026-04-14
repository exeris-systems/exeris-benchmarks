package eu.exeris.benchmarks.targets.exeriscommunity.security;



import com.nimbusds.jose.JWSAlgorithm;
import com.nimbusds.jose.JWSHeader;
import com.nimbusds.jose.crypto.RSASSASigner;
import com.nimbusds.jwt.JWTClaimsSet;
import com.nimbusds.jwt.SignedJWT;

import java.security.KeyPair;
import java.security.KeyPairGenerator;
import java.security.interfaces.RSAPublicKey;
import java.util.Date;
import java.util.UUID;

/**
 * Generates a static RSA-2048 keypair at class init and issues signed RS256 JWTs
 * for benchmark use. Not for production use.
 */
public final class BenchmarkTokenIssuer {

    public static final String KID = "benchmark-key-1";
    public static final String ISSUER = "https://benchmark.exeris.local";
    public static final String AUD = "exeris-benchmark";

    private static final KeyPair KEY_PAIR;

    static {
        try {
            KeyPairGenerator gen = KeyPairGenerator.getInstance("RSA");
            gen.initialize(2048);
            KEY_PAIR = gen.generateKeyPair();
        } catch (Exception e) {
            throw new ExceptionInInitializerError(e);
        }
    }

    public RSAPublicKey publicKey() {
        return (RSAPublicKey) KEY_PAIR.getPublic();
    }

    public String issueToken(UUID userId) {
        try {
            JWSHeader header = new JWSHeader.Builder(JWSAlgorithm.RS256)
                .keyID(KID)
                .build();

            Date now = new Date();
            Date exp = new Date(now.getTime() + 3_600_000L);

            JWTClaimsSet claims = new JWTClaimsSet.Builder()
                .subject(userId.toString())
                .issuer(ISSUER)
                .audience(AUD)
                .expirationTime(exp)
                .issueTime(now)
                .build();

            SignedJWT jwt = new SignedJWT(header, claims);
            jwt.sign(new RSASSASigner(KEY_PAIR.getPrivate()));
            return jwt.serialize();
        } catch (Exception e) {
            throw new RuntimeException("Failed to issue JWT", e);
        }
    }
}
