package eu.exeris.benchmarks.targets.restateapp.application;

import javax.crypto.Mac;
import javax.crypto.spec.SecretKeySpec;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.SecureRandom;
import java.time.Duration;
import java.time.Instant;
import java.util.Base64;
import java.util.Optional;

/**
 * Stateless HMAC-SHA256 bearer token: payload "uid=&lt;id&gt;;exp=&lt;epochSeconds&gt;"
 * base64url-encoded, dot, base64url signature. The k6 harness only
 * round-trips the token verbatim; this keeps the facade free of a JWT
 * dependency while still carrying and verifying the user identity.
 *
 * The signing key is process-local and random per start (benchmark sessions
 * never outlive the target process), overridable via EXERIS_AUTH_TOKEN_SECRET
 * for multi-process setups.
 */
public final class BearerTokenService {

    private static final Duration TOKEN_TTL = Duration.ofHours(1);
    private static final Base64.Encoder B64_ENCODER = Base64.getUrlEncoder().withoutPadding();
    private static final Base64.Decoder B64_DECODER = Base64.getUrlDecoder();

    private final SecretKeySpec key;

    public BearerTokenService(String secret) {
        byte[] keyBytes = (secret == null || secret.isBlank())
                ? randomKey()
                : secret.getBytes(StandardCharsets.UTF_8);
        this.key = new SecretKeySpec(keyBytes, "HmacSHA256");
    }

    public String issue(long userId) {
        long expiresAt = Instant.now().plus(TOKEN_TTL).getEpochSecond();
        String payload = "uid=" + userId + ";exp=" + expiresAt;
        String encodedPayload = B64_ENCODER.encodeToString(payload.getBytes(StandardCharsets.UTF_8));
        return encodedPayload + "." + B64_ENCODER.encodeToString(sign(encodedPayload));
    }

    /** Returns the userId when the token is well-formed, correctly signed, and unexpired. */
    public Optional<Long> verify(String token) {
        if (token == null || token.isBlank()) {
            return Optional.empty();
        }
        int dot = token.indexOf('.');
        if (dot <= 0 || dot == token.length() - 1) {
            return Optional.empty();
        }
        String encodedPayload = token.substring(0, dot);
        try {
            byte[] providedSignature = B64_DECODER.decode(token.substring(dot + 1));
            if (!MessageDigest.isEqual(providedSignature, sign(encodedPayload))) {
                return Optional.empty();
            }
            String payload = new String(B64_DECODER.decode(encodedPayload), StandardCharsets.UTF_8);
            long userId = -1L;
            long expiresAt = -1L;
            for (String part : payload.split(";")) {
                if (part.startsWith("uid=")) {
                    userId = Long.parseLong(part.substring(4));
                } else if (part.startsWith("exp=")) {
                    expiresAt = Long.parseLong(part.substring(4));
                }
            }
            if (userId < 0 || expiresAt < Instant.now().getEpochSecond()) {
                return Optional.empty();
            }
            return Optional.of(userId);
        } catch (IllegalArgumentException | NullPointerException e) {
            return Optional.empty();
        }
    }

    private byte[] sign(String encodedPayload) {
        try {
            Mac mac = Mac.getInstance("HmacSHA256");
            mac.init(key);
            return mac.doFinal(encodedPayload.getBytes(StandardCharsets.UTF_8));
        } catch (Exception e) {
            throw new IllegalStateException("HmacSHA256 unavailable", e);
        }
    }

    private static byte[] randomKey() {
        byte[] keyBytes = new byte[32];
        new SecureRandom().nextBytes(keyBytes);
        return keyBytes;
    }
}
