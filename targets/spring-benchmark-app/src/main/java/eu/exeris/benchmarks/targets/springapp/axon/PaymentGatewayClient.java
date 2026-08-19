package eu.exeris.benchmarks.targets.springapp.application.axon;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.stereotype.Component;

import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.time.Duration;

/**
 * Dispatches a payment request to the external payment gateway (CONTRACT-v2 §4,
 * parking workload). The gateway answers 202 and calls back asynchronously; the
 * saga parks in between.
 *
 * <p>Deliberately duplicated per target rather than shared: the targets are
 * independent Maven modules with no common artifact, and a shared client would
 * be a fourth implementation choice that no stack would make on its own. Same
 * reason the §4.1 FNV rule is duplicated.
 *
 * <p>The callback host defaults to {@code 127.0.0.1}: the stack is host-networked, so the
 * gateway runs in a container and calls back to this JVM on the host — the same
 * wiring reason as restate-server's advertised SDK URL. Override with
 * {@code EXERIS_PAYMENT_CALLBACK_URL} when the gateway runs on the host.
 */
@Component
public class PaymentGatewayClient {

    private static final Logger log = LoggerFactory.getLogger(PaymentGatewayClient.class);

    private static final String GATEWAY_URL = System.getenv()
            .getOrDefault("EXERIS_PAYMENT_GATEWAY_URL", "http://localhost:9300/payments");

    private static final String CALLBACK_URL = System.getenv()
            .getOrDefault("EXERIS_PAYMENT_CALLBACK_URL",
                    "http://127.0.0.1:"
                            + System.getenv().getOrDefault("EXERIS_PORT", "8080")
                            + "/api/v1/payments/callback");

    private final HttpClient http = HttpClient.newBuilder()
            .connectTimeout(Duration.ofSeconds(5))
            .build();

    /**
     * Fire-and-forget dispatch. A failure here is NOT converted into a decline:
     * the §4.1 population's expected compensation count is an exact integer
     * derived from the orderId alone, so a fake decline would corrupt the oracle.
     * The saga parks regardless and the order simply never settles — visible as a
     * stranded saga, which is the honest symptom.
     */
    public void dispatch(String orderId, String sagaId) {
        String body = "{\"order_id\":\"" + orderId
                + "\",\"saga_id\":\"" + sagaId
                + "\",\"callback_url\":\"" + CALLBACK_URL + "\"}";
        HttpRequest request = HttpRequest.newBuilder()
                .uri(URI.create(GATEWAY_URL))
                .header("Content-Type", "application/json")
                .timeout(Duration.ofSeconds(10))
                .POST(HttpRequest.BodyPublishers.ofString(body))
                .build();
        http.sendAsync(request, HttpResponse.BodyHandlers.discarding())
                .exceptionally(failure -> {
                    log.warn("payment dispatch failed for saga {} — the saga stays parked", sagaId, failure);
                    return null;
                });
    }

    public String gatewayUrl() {
        return GATEWAY_URL;
    }

    public String callbackUrl() {
        return CALLBACK_URL;
    }
}
