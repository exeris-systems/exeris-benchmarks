package eu.exeris.benchmarks.targets.quarkusapp.axon;

import jakarta.enterprise.context.ApplicationScoped;

import org.jboss.logging.Logger;

import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.time.Duration;

/**
 * Ends an LRA from outside its context.
 *
 * <p>The gateway callback that settles a payment arrives with no LRA context header —
 * the gateway knows nothing about LRA, by design, since it must be identical for every
 * stack. So the LRA is ended by calling the coordinator directly with the id this arm
 * persisted on the order row, rather than by annotating a resource method
 * {@code @LRA(end = true)} and having to smuggle the context back in.
 *
 * <p>close -> the coordinator invokes the participant's {@code @Complete}.
 * cancel -> it invokes {@code @Compensate}, which is where §2's LIFO unwind lives.
 */
@ApplicationScoped
public class LraClient {

    private static final Logger LOG = Logger.getLogger(LraClient.class);

    private final HttpClient http = HttpClient.newBuilder()
            .connectTimeout(Duration.ofSeconds(5))
            .build();

    public boolean close(String lraId) {
        return end(lraId, "close");
    }

    public boolean cancel(String lraId) {
        return end(lraId, "cancel");
    }

    private boolean end(String lraId, String action) {
        try {
            HttpRequest request = HttpRequest.newBuilder()
                    .uri(URI.create(lraId + "/" + action))
                    .timeout(Duration.ofSeconds(20))
                    .PUT(HttpRequest.BodyPublishers.noBody())
                    .build();
            HttpResponse<String> response =
                    http.send(request, HttpResponse.BodyHandlers.ofString());
            if (response.statusCode() >= 200 && response.statusCode() < 300) {
                return true;
            }
            // Not swallowed: an LRA that neither closes nor cancels leaves the saga
            // unterminated, and the §7 O0 accounting will surface it as unresolved
            // rather than as a compensation that silently did not happen.
            LOG.errorf("LRA %s %s returned HTTP %d: %s", lraId, action,
                    response.statusCode(), response.body());
            return false;
        } catch (Exception e) {
            LOG.errorf(e, "LRA %s %s failed", lraId, action);
            return false;
        }
    }
}
