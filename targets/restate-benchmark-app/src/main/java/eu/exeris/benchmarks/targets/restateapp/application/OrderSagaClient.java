package eu.exeris.benchmarks.targets.restateapp.application;

import com.fasterxml.jackson.databind.ObjectMapper;
import eu.exeris.benchmarks.targets.restateapp.saga.OrderSagaRequest;
import eu.exeris.benchmarks.targets.restateapp.saga.OrderSagaResult;

import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.nio.charset.StandardCharsets;
import java.time.Duration;

/**
 * Facade → restate-server ingress bridge. Submits the saga request-response
 * over the documented v1.7 ingress path
 * (POST {ingress}/restate/call/OrderSaga/run) with the client orderId as the
 * `idempotency-key` header (CONTRACT-v2 §3: orderId is the idempotency key).
 * The call blocks until the saga handler returns its terminal outcome; a
 * duplicate orderId within the idempotency retention window returns the
 * stored terminal result without re-execution.
 */
public final class OrderSagaClient {

    private static final Duration CALL_TIMEOUT = Duration.ofSeconds(60);

    private final HttpClient httpClient;
    private final ObjectMapper objectMapper;
    private final URI callUri;

    public OrderSagaClient(String ingressBaseUrl, ObjectMapper objectMapper) {
        this.httpClient = HttpClient.newBuilder()
                .connectTimeout(Duration.ofSeconds(5))
                .build();
        this.objectMapper = objectMapper;
        String base = ingressBaseUrl.endsWith("/")
                ? ingressBaseUrl.substring(0, ingressBaseUrl.length() - 1)
                : ingressBaseUrl;
        this.callUri = URI.create(base + "/restate/call/OrderSaga/run");
    }

    public OrderSagaResult run(OrderSagaRequest request) throws SagaSubmissionException {
        try {
            byte[] body = objectMapper.writeValueAsBytes(request);
            HttpRequest httpRequest = HttpRequest.newBuilder(callUri)
                    .timeout(CALL_TIMEOUT)
                    .header("content-type", "application/json")
                    .header("idempotency-key", request.orderId())
                    .POST(HttpRequest.BodyPublishers.ofByteArray(body))
                    .build();
            HttpResponse<byte[]> response = httpClient.send(httpRequest, HttpResponse.BodyHandlers.ofByteArray());
            if (response.statusCode() != 200) {
                throw new SagaSubmissionException("restate ingress returned HTTP " + response.statusCode()
                        + " for order " + request.orderId() + ": "
                        + new String(response.body(), StandardCharsets.UTF_8));
            }
            return objectMapper.readValue(response.body(), OrderSagaResult.class);
        } catch (SagaSubmissionException e) {
            throw e;
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
            throw new SagaSubmissionException("interrupted while awaiting saga outcome for order "
                    + request.orderId(), e);
        } catch (Exception e) {
            throw new SagaSubmissionException("saga submission failed for order " + request.orderId(), e);
        }
    }

    public static final class SagaSubmissionException extends Exception {
        public SagaSubmissionException(String message) {
            super(message);
        }

        public SagaSubmissionException(String message, Throwable cause) {
            super(message, cause);
        }
    }
}
