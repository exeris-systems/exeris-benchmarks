package eu.exeris.benchmarks.targets.springapp;

import eu.exeris.kernel.spi.http.HttpMethod;
import eu.exeris.kernel.spi.http.HttpStatus;
import eu.exeris.kernel.spi.persistence.QueryResult;
import eu.exeris.kernel.spi.persistence.TransactionalExecutor;
import eu.exeris.spring.runtime.web.ExerisRequestHandler;
import eu.exeris.spring.runtime.web.ExerisRoute;
import eu.exeris.spring.runtime.web.ExerisServerRequest;
import eu.exeris.spring.runtime.web.ExerisServerResponse;

import org.springframework.http.MediaType;
import org.springframework.stereotype.Component;

import java.util.Map;

/**
 * DB-connectivity probe hit by the comparative harness Stage-4 preflight. Same {@code SELECT 1}
 * and same response bodies as the other arms — but issued through the kernel-native
 * {@link TransactionalExecutor} rather than a {@code JdbcTemplate}, because this target has no
 * Spring {@code DataSource} at all.
 *
 * <p>Identical in shape to {@code exeris-community-app}'s {@code UserRepository#ping()}.
 *
 * <p>{@code /graph/ping} is deliberately not implemented here: the entity-read-by-id harness
 * probes only /health, /db/ping and /api/v1/users. It must be added, together with the Neo4j
 * driver dependency, before this target is used for the saga scenario.
 */
@Component
@ExerisRoute(method = HttpMethod.GET, path = "/db/ping")
public class DbPingRouteHandler implements ExerisRequestHandler {

    private final TransactionalExecutor transactionalExecutor;
    private final JsonEncoder jsonEncoder;

    public DbPingRouteHandler(TransactionalExecutor transactionalExecutor, JsonEncoder jsonEncoder) {
        this.transactionalExecutor = transactionalExecutor;
        this.jsonEncoder = jsonEncoder;
    }

    @Override
    public ExerisServerResponse handle(ExerisServerRequest request) {
        boolean reachable = transactionalExecutor.query(connection -> {
            try (QueryResult result = connection.executeQuery("SELECT 1")) {
                return result.next() && result.row().getInt(0) == 1;
            }
        });

        if (reachable) {
            return ExerisServerResponse.ok()
                    .contentType(MediaType.APPLICATION_JSON)
                    .body(jsonEncoder.encode(Map.of("status", "ok")));
        }
        return ExerisServerResponse.status(HttpStatus.SERVICE_UNAVAILABLE)
                .contentType(MediaType.APPLICATION_JSON)
                .body(jsonEncoder.encode(Map.of("status", "down")));
    }
}
