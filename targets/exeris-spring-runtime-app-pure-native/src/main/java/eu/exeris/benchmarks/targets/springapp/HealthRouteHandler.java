package eu.exeris.benchmarks.targets.springapp;

import eu.exeris.kernel.spi.http.HttpMethod;
import eu.exeris.spring.runtime.web.ExerisRequestHandler;
import eu.exeris.spring.runtime.web.ExerisRoute;
import eu.exeris.spring.runtime.web.ExerisServerRequest;
import eu.exeris.spring.runtime.web.ExerisServerResponse;

import org.springframework.http.MediaType;
import org.springframework.stereotype.Component;

import java.util.Map;

/**
 * Liveness probe used by the driver readiness gate. Body kept identical to the compat arm's
 * {@code {"status":"ok"}} so the gate cannot pass on one arm and fail on the other.
 *
 * <p>One class per route: {@code @ExerisRoute} is {@code @Target(TYPE)}, so it cannot be
 * placed on an {@code @Bean} factory method — the auto-configuration reads it off the bean's
 * type via {@code findAnnotationOnBean}.
 */
@Component
@ExerisRoute(method = HttpMethod.GET, path = "/health")
public class HealthRouteHandler implements ExerisRequestHandler {

    private final byte[] body;

    public HealthRouteHandler(JsonEncoder jsonEncoder) {
        this.body = jsonEncoder.encode(Map.of("status", "ok"));
    }

    @Override
    public ExerisServerResponse handle(ExerisServerRequest request) {
        return ExerisServerResponse.ok()
                .contentType(MediaType.APPLICATION_JSON)
                .body(body);
    }
}
