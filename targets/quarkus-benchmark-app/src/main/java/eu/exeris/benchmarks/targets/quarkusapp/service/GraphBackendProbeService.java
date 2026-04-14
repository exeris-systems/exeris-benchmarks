package eu.exeris.benchmarks.targets.quarkusapp.service;

import jakarta.enterprise.context.ApplicationScoped;
import jakarta.inject.Inject;
import org.eclipse.microprofile.config.inject.ConfigProperty;
import org.neo4j.driver.AuthTokens;
import org.neo4j.driver.GraphDatabase;
import org.neo4j.driver.SessionConfig;

import javax.sql.DataSource;
import java.sql.Connection;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.util.LinkedHashMap;
import java.util.Locale;
import java.util.Map;

@ApplicationScoped
public class GraphBackendProbeService {

    private static final String BACKEND_PGQ = "pgq";
    private static final String BACKEND_NEO4J = "neo4j";

    @Inject
    DataSource dataSource;

    @ConfigProperty(name = "exeris.graph.backend.type", defaultValue = BACKEND_PGQ)
    String backendType;

    @ConfigProperty(name = "exeris.graph.neo4j.uri", defaultValue = "")
    String neo4jUri;

    @ConfigProperty(name = "exeris.graph.neo4j.user", defaultValue = "")
    String neo4jUser;

    @ConfigProperty(name = "exeris.graph.neo4j.password", defaultValue = "")
    String neo4jPassword;

    @ConfigProperty(name = "exeris.graph.neo4j.database", defaultValue = "neo4j")
    String neo4jDatabase;

    @ConfigProperty(name = "exeris.axon.mode", defaultValue = "event-sourcing-outbox")
    String axonMode;

    public Map<String, Object> status() {
        String normalizedBackend = normalizeBackend(backendType);
        boolean up = BACKEND_NEO4J.equals(normalizedBackend) ? probeNeo4j() : probePgq();

        Map<String, Object> response = new LinkedHashMap<>();
        response.put("backend_type", normalizedBackend);
        response.put("saga_framework", "axon-framework");
        response.put("event_backend", axonMode);
        response.put("graph_backend", BACKEND_NEO4J.equals(normalizedBackend) ? "neo4j-bolt" : "postgres-graph-pgq");
        response.put("graph_up", up);
        return response;
    }

    private boolean probePgq() {
        try (Connection connection = dataSource.getConnection();
             PreparedStatement stmt = connection.prepareStatement("SELECT 1");
             ResultSet rs = stmt.executeQuery()) {
            return rs.next() && rs.getInt(1) == 1;
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