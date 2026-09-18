package eu.exeris.benchmarks.targets.restateapp.saga;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.time.Duration;

/**
 * Dispatches a payment request to the external payment gateway (CONTRACT-v2 §4,
 * parking workload). The gateway answers 202 and calls back asynchronously; the
 * workflow parks on an awakeable in between.
 *
 * <p>Unlike the other targets, the callback does NOT come back to this JVM: it goes
 * straight to the Restate ingress' awakeable-resolve endpoint, and the SDK delivers
 * the payload as the awakeable's value. That is the platform-natural shape — Restate
 * owns durable execution, so an application-hosted callback route would be a
 * hand-rolled reimplementation of what the runtime already provides. Registered as
 * a §9(a) deviation: this stack's callback path does not traverse the target
 * process, so its per-callback cost lands in restate-server rather than in the JVM
 * (both are inside the §1 deployment unit, so the whole-deployment footprint still
 * captures it — but a target-JVM-only comparison would not).
 */
public final class PaymentGatewayClient {

    private static final Logger log = LoggerFactory.getLogger(PaymentGatewayClient.class);

    private static final String GATEWAY_URL = System.getenv()
            .getOrDefault("EXERIS_PAYMENT_GATEWAY_URL", "http://localhost:9300/payments");

    /**
     * Base of the Restate ingress as reachable FROM THE GATEWAY CONTAINER — a different
     * address from the one this JVM would use, and getting it wrong is silent.
     *
     * <p>Since 2026-08-19 the stack is host-networked, so this is 127.0.0.1:8080 — the
     * gateway container shares the host's network namespace and the ingress binds the
     * host's loopback. While the stack ran on the bridge this had to be the compose
     * SERVICE NAME instead (127.0.0.1 inside the gateway container was the container's own
     * loopback, and answered "Connection refused"). Either way the failure is silent in the
     * same way: the awakeable is never resolved, the workflow stays parked, the ingress call
     * ends in HttpTimeoutException, and it reads as a slow target rather than a wrong
     * address. The baseline exports EXERIS_RESTATE_INGRESS_CALLBACK_URL explicitly so the
     * wiring is decided in one place rather than by whichever default was compiled in.
     */
    private static final String RESTATE_INGRESS_URL = System.getenv()
            .getOrDefault("EXERIS_RESTATE_INGRESS_CALLBACK_URL", "http://127.0.0.1:8080");

    private final HttpClient http = HttpClient.newBuilder()
            .connectTimeout(Duration.ofSeconds(5))
            .build();

    /**
     * Fire-and-forget dispatch. A failure here is NOT converted into a decline: the
     * §4.1 population's expected compensation count is an exact integer derived from
     * the orderId alone, so a fake decline would corrupt the oracle. The workflow
     * stays parked on its awakeable and the order simply never settles — visible as
     * a stranded saga, which is the honest symptom.
     *
     * @param awakeableId the id the gateway must resolve; the callback URL is built
     *                    from it, so the gateway needs no knowledge of Restate beyond
     *                    "POST the outcome to this URL"
     */
    public void dispatch(String orderId, String sagaId, String awakeableId) {
        String callbackUrl = RESTATE_INGRESS_URL + "/restate/awakeables/" + awakeableId + "/resolve";
        String body = "{\"order_id\":\"" + orderId
                + "\",\"saga_id\":\"" + sagaId
                + "\",\"callback_url\":\"" + callbackUrl + "\"}";
        HttpRequest request = HttpRequest.newBuilder()
                .uri(URI.create(GATEWAY_URL))
                .header("Content-Type", "application/json")
                .timeout(Duration.ofSeconds(10))
                .POST(HttpRequest.BodyPublishers.ofString(body))
                .build();
        http.sendAsync(request, HttpResponse.BodyHandlers.discarding())
                .exceptionally(failure -> {
                    log.warn("payment dispatch failed for saga {} — the workflow stays parked", sagaId, failure);
                    return null;
                });
    }
}
