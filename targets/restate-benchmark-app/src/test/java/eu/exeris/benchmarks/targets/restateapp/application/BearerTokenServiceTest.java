package eu.exeris.benchmarks.targets.restateapp.application;

import org.junit.jupiter.api.Test;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;

final class BearerTokenServiceTest {

    @Test
    void issuedTokenRoundTripsUserId() {
        BearerTokenService service = new BearerTokenService("test-secret");
        String token = service.issue(42L);
        assertEquals(42L, service.verify(token).orElseThrow());
    }

    @Test
    void tamperedTokenIsRejected() {
        BearerTokenService service = new BearerTokenService("test-secret");
        String token = service.issue(42L);
        assertTrue(service.verify(token + "x").isEmpty());
        assertTrue(service.verify("y" + token).isEmpty());
    }

    @Test
    void tokenSignedWithDifferentKeyIsRejected() {
        BearerTokenService issuer = new BearerTokenService("secret-a");
        BearerTokenService verifier = new BearerTokenService("secret-b");
        assertTrue(verifier.verify(issuer.issue(42L)).isEmpty());
    }

    @Test
    void malformedTokensAreRejected() {
        BearerTokenService service = new BearerTokenService("test-secret");
        assertTrue(service.verify(null).isEmpty());
        assertTrue(service.verify("").isEmpty());
        assertTrue(service.verify("no-dot").isEmpty());
        assertTrue(service.verify(".leading-dot").isEmpty());
        assertTrue(service.verify("trailing-dot.").isEmpty());
        assertTrue(service.verify("not!base64.also!not").isEmpty());
    }
}
