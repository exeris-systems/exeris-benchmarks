package eu.exeris.benchmarks.targets.springapp;

import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

import eu.exeris.kernel.spi.persistence.QueryResult;
import eu.exeris.kernel.spi.persistence.TransactionalExecutor;

import java.util.List;
import java.util.Map;

/**
 * Compat-mode ingress for the second diagonal: {@code @RestController} on top of kernel-native
 * persistence.
 *
 * <h2>What this class is for</h2>
 *
 * <p>The four ladder arms cover only one diagonal of the two-axis space. {@code app-pure} is pure
 * on the web axis and compat on the persistence axis (Hibernate over {@code ExerisDataSource});
 * {@code app-pure-native} is pure on both. The combination measured here — compat web, native
 * persistence — was never built, so nobody knew whether it was even reachable.
 *
 * <p>That is the primary result this target produces, and it is binary: either
 * {@code TransactionalExecutor} works under {@code ExerisCompatDispatcher}, or the axes are
 * coupled and the best combination is unavailable. {@link ExerisPersistenceConfiguration}'s
 * adapter re-resolves {@code PersistenceEngineProvider} per call and throws with a named message
 * when the ScopedValue is unbound, so a failure here is diagnosable rather than silent.
 *
 * <p>The risk is real and specific. {@code KernelProviders.PERSISTENCE_ENGINE} is bound per
 * request by the kernel provider binder, and its coverage has NOT been universal in compat mode:
 * the compat security filter ran outside it until runtime PR #48, and flow-worker virtual threads
 * are still outside it. Whether the compat dispatch path binds it is what this arm tests.
 *
 * <h2>Deliberately NOT a copy of the compat arm's controller</h2>
 *
 * <p>{@code targets/exeris-spring-runtime-app-comp}'s controller injects a {@code JdbcTemplate}
 * for {@code /db/ping}. This target has no Spring {@code DataSource} at all, so the probe goes
 * through {@link TransactionalExecutor} — the same shape {@code app-pure-native}'s
 * {@code DbPingRouteHandler} uses. Response bodies are kept identical to every other arm so the
 * harness readiness gate cannot pass on one arm and fail on another.
 *
 * <p>{@code /graph/ping} is not implemented, matching {@code app-pure-native}: the
 * entity-read-by-id harness probes only /health, /db/ping and /api/v1/users. It must be added,
 * with the Neo4j driver, before this target is used for the saga scenario.
 *
 * <h2>Serialisation</h2>
 *
 * <p>Nothing here encodes explicitly. In compat mode {@code ExerisCompatAutoConfiguration}
 * contributes {@code exerisCompatJacksonConverter}, and {@code ExerisCompatJsonConverterFactory}
 * selects {@code JacksonJsonHttpMessageConverter} because {@code tools.jackson.databind} is on
 * the classpath — the Jackson 3 line the whole ladder shares. That converter builds its own
 * mapper from the classloader, so {@code app-pure-native}'s explicit {@code JsonConfiguration} /
 * {@code JsonEncoder} pair has no counterpart here and both were dropped rather than left inert.
 * Both arms therefore encode with Jackson 3 defaults, but through different objects — a stated
 * difference, not a claim of identity. Verify with a body checksum in
 * {@code tools/preflight-ladder-arms.sh} before trusting any pair that spans it.
 */
@RestController
public class SpringBenchmarkController {

    private final UserService userService;
    private final TransactionalExecutor transactionalExecutor;

    public SpringBenchmarkController(
            UserService userService, TransactionalExecutor transactionalExecutor) {
        this.userService = userService;
        this.transactionalExecutor = transactionalExecutor;
    }

    /** Heavy aggregate contract: 10 users x 10 friends x 10 interests. */
    @GetMapping(value = "/api/v1/users", produces = "application/json")
    public List<UserView> readUsers() {
        return userService.findFrozenContractUsers();
    }

    /** Light single-read contract. 404 on a missing row, matching every other arm. */
    @GetMapping(value = "/api/v1/user", produces = "application/json")
    public ResponseEntity<UserSummary> readUser(@RequestParam("id") long id) {
        UserSummary user = userService.findUserById(id);
        if (user == null) {
            return ResponseEntity.notFound().build();
        }
        return ResponseEntity.ok(user);
    }

    @GetMapping(value = "/health", produces = "application/json")
    public Map<String, String> health() {
        return Map.of("status", "ok");
    }

    @GetMapping(value = "/db/ping", produces = "application/json")
    public ResponseEntity<Map<String, String>> dbPing() {
        boolean reachable = transactionalExecutor.query(connection -> {
            try (QueryResult result = connection.executeQuery("SELECT 1")) {
                return result.next() && result.row().getInt(0) == 1;
            }
        });

        if (reachable) {
            return ResponseEntity.ok(Map.of("status", "ok"));
        }
        return ResponseEntity.status(503).body(Map.of("status", "down"));
    }
}
