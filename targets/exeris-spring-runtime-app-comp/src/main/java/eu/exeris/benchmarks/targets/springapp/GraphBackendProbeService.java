package eu.exeris.benchmarks.targets.springapp;

import org.neo4j.driver.AuthTokens;
import org.neo4j.driver.GraphDatabase;
import org.neo4j.driver.SessionConfig;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Service;

import java.util.LinkedHashMap;
import java.util.Locale;
import java.util.Map;

@Service
public class GraphBackendProbeService {

    private static final String BACKEND_PGQ = "pgq";
    private static final String BACKEND_NEO4J = "neo4j";

    private final JdbcTemplate jdbcTemplate;
    private final String backendType;
    private final String neo4jUri;
    private final String neo4jUser;
    private final String neo4jPassword;
    private final String neo4jDatabase;
    private final String sagaEngineMode;

    public GraphBackendProbeService(
            JdbcTemplate jdbcTemplate,
            @Value("${exeris.graph.backend.type:pgq}") String backendType,
            @Value("${exeris.graph.neo4j.uri:}") String neo4jUri,
            @Value("${exeris.graph.neo4j.user:}") String neo4jUser,
            @Value("${exeris.graph.neo4j.password:}") String neo4jPassword,
            @Value("${exeris.graph.neo4j.database:neo4j}") String neo4jDatabase,
            @Value("${exeris.saga.engine.mode:exeris-flow}") String sagaEngineMode
    ) {
        this.jdbcTemplate = jdbcTemplate;
        this.backendType = backendType;
        this.neo4jUri = neo4jUri;
        this.neo4jUser = neo4jUser;
        this.neo4jPassword = neo4jPassword;
        this.neo4jDatabase = neo4jDatabase;
        this.sagaEngineMode = sagaEngineMode;
    }

    public Map<String, Object> status() {
        String normalizedBackend = normalizeBackend(backendType);
        boolean up = BACKEND_NEO4J.equals(normalizedBackend) ? probeNeo4j() : probePgq();

        Map<String, Object> response = new LinkedHashMap<>();
        response.put("backend_type", normalizedBackend);
        response.put("saga_framework", "exeris-spring-runtime-flow");
        response.put("event_backend", sagaEngineMode);
        response.put("graph_backend", BACKEND_NEO4J.equals(normalizedBackend) ? "neo4j-bolt" : "postgres-graph-pgq");
        response.put("graph_up", up);
        return response;
    }

    private boolean probePgq() {
        try {
            Integer one = jdbcTemplate.queryForObject("SELECT 1", Integer.class);
            return one != null && one == 1;
        } catch (Exception ignored) {
            return false;
        }
    }

    private boolean probeNeo4j() {
        if (isBlank(neo4jUri) || isBlank(neo4jUser) || isBlank(neo4jPassword)) {
            return false;
        }
        try (var driver = GraphDatabase.driver(neo4jUri, AuthTokens.basic(neo4jUser, neo4jPassword));
             var session = driver.session(SessionConfig.forDatabase(defaultIfBlank(neo4jDatabase, "neo4j")))) {
            Integer ok = session
                    .run("RETURN 1 AS ok")
                    .single()
                    .get("ok")
                    .asInt();
            return ok != null && ok == 1;
        } catch (Exception ignored) {
            return false;
        }
    }

    private static String normalizeBackend(String raw) {
        String value = raw == null ? "" : raw.trim().toLowerCase(Locale.ROOT);
        if (value.equals("neo4j") || value.equals("bolt")) {
            return BACKEND_NEO4J;
        }
        if (value.equals("pgq") || value.equals("postgres") || value.equals("postgresql") || value.equals("postgres-graph")) {
            return BACKEND_PGQ;
        }
        return BACKEND_PGQ;
    }

    private static String defaultIfBlank(String value, String fallback) {
        return isBlank(value) ? fallback : value;
    }

    private static boolean isBlank(String value) {
        return value == null || value.trim().isEmpty();
    }
}