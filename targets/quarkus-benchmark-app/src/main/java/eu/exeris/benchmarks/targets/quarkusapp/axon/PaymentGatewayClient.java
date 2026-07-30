package eu.exeris.benchmarks.targets.quarkusapp.axon;

import jakarta.enterprise.context.ApplicationScoped;

import org.jboss.logging.Logger;

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
 * independent Maven modules with no common artifact. Same reason the §4.1 FNV
 * rule was duplicated before it moved into the gateway.
 *
 * <p>The callback host defaults to {@code host.docker.internal} because the
 * gateway runs in a container and calls back to this JVM on the host. Override
 * with {@code EXERIS_PAYMENT_CALLBACK_URL} when the gateway runs on the host.
 */
@ApplicationScoped
public class PaymentGatewayClient {

    private static final Logger LOG = Logger.getLogger(PaymentGatewayClient.class);

    private static final String GATEWAY_URL = System.getenv()
            .getOrDefault("EXERIS_PAYMENT_GATEWAY_URL", "http://localhost:9300/payments");

    private static final String CALLBACK_URL = System.getenv()
            .getOrDefault("EXERIS_PAYMENT_CALLBACK_URL",
                    "http://host.docker.internal:"
                            + System.getenv().getOrDefault("EXERIS_HTTP_PORT", "9002")
                            + "/api/v1/payments/callback");

    private final HttpClient http = HttpClient.newBuilder()
            .connectTimeout(Duration.ofSeconds(5))
            .build();

    /**
     * Fire-and-forget dispatch. A failure here is NOT converted into a decline: the
     * §4.1 population's expected compensation count is an exact integer derived from
     * the orderId alone, so a fake decline would corrupt the oracle. The saga parks
     * regardless and the order simply never settles — visible as a stranded saga,
     * which is the honest symptom.
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
                    LOG.warnf(failure, "payment dispatch failed for saga %s — the saga stays parked", sagaId);
                    return null;
                });
    }
}
