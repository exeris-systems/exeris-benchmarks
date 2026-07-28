package eu.exeris.benchmarks.targets.restateapp.application;

import com.nimbusds.jwt.SignedJWT;
import org.junit.jupiter.api.Test;

import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;

final class BearerTokenServiceTest {

    @Test
    void issuedTokenRoundTripsPrincipalId() {
        BearerTokenService service = new BearerTokenService();
        UUID principalId = UUID.randomUUID();
        String token = service.issue(principalId);
        assertEquals(principalId, service.verify(token).orElseThrow());
    }

    @Test
    void issuedTokenCarriesReferenceClaimsSurface() throws Exception {
        BearerTokenService service = new BearerTokenService();
        SignedJWT jwt = SignedJWT.parse(service.issue(UUID.randomUUID()));
        assertEquals("RS256", jwt.getHeader().getAlgorithm().getName());
        assertEquals(BearerTokenService.KID, jwt.getHeader().getKeyID());
        assertEquals(BearerTokenService.ISSUER, jwt.getJWTClaimsSet().getIssuer());
        assertEquals(BearerTokenService.AUD, jwt.getJWTClaimsSet().getAudience().getFirst());
        assertTrue(jwt.getJWTClaimsSet().getExpirationTime()
                .after(jwt.getJWTClaimsSet().getIssueTime()));
    }

    @Test
    void tamperedTokenIsRejected() {
        BearerTokenService service = new BearerTokenService();
        String token = service.issue(UUID.randomUUID());
        assertTrue(service.verify(token + "x").isEmpty());
        assertTrue(service.verify("y" + token).isEmpty());
    }

    @Test
    void tokenSignedWithDifferentKeypairIsRejected() {
        BearerTokenService issuer = new BearerTokenService();
        BearerTokenService verifier = new BearerTokenService();
        assertTrue(verifier.verify(issuer.issue(UUID.randomUUID())).isEmpty());
    }

    @Test
    void malformedTokensAreRejected() {
        BearerTokenService service = new BearerTokenService();
        assertTrue(service.verify(null).isEmpty());
        assertTrue(service.verify("").isEmpty());
        assertTrue(service.verify("no-dot").isEmpty());
        assertTrue(service.verify(".leading-dot").isEmpty());
        assertTrue(service.verify("trailing-dot.").isEmpty());
        assertTrue(service.verify("not!base64.also!not.sig").isEmpty());
    }
}
