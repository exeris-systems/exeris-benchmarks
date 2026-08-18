package eu.exeris.benchmarks.targets.springapp;

import eu.exeris.kernel.spi.http.HttpMethod;
import eu.exeris.kernel.spi.http.HttpStatus;
import eu.exeris.spring.runtime.web.ExerisRequestHandler;
import eu.exeris.spring.runtime.web.ExerisRoute;
import eu.exeris.spring.runtime.web.ExerisServerRequest;
import eu.exeris.spring.runtime.web.ExerisServerResponse;

import org.springframework.http.MediaType;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Component;

import java.util.Map;

/**
 * DB-connectivity probe hit by the comparative harness Stage-4 preflight. Same {@code SELECT 1}
 * and same response bodies as the compat arm's controller method.
 *
 * <p>{@code /graph/ping} is deliberately not implemented here: the entity-read-by-id harness
 * probes only /health, /db/ping and /api/v1/users. It must be added, together with the Neo4j
 * driver dependency, before this target is used for the saga scenario.
 */
@Component
@ExerisRoute(method = HttpMethod.GET, path = "/db/ping")
public class DbPingRouteHandler implements ExerisRequestHandler {

    private final JdbcTemplate jdbcTemplate;
    private final JsonEncoder jsonEncoder;

    public DbPingRouteHandler(JdbcTemplate jdbcTemplate, JsonEncoder jsonEncoder) {
        this.jdbcTemplate = jdbcTemplate;
        this.jsonEncoder = jsonEncoder;
    }

    @Override
    public ExerisServerResponse handle(ExerisServerRequest request) {
        Integer one = jdbcTemplate.queryForObject("SELECT 1", Integer.class);
        if (one != null && one == 1) {
            return ExerisServerResponse.ok()
                    .contentType(MediaType.APPLICATION_JSON)
                    .body(jsonEncoder.encode(Map.of("status", "ok")));
        }
        return ExerisServerResponse.status(HttpStatus.SERVICE_UNAVAILABLE)
                .contentType(MediaType.APPLICATION_JSON)
                .body(jsonEncoder.encode(Map.of("status", "down")));
    }
}
