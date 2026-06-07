package eu.exeris.benchmarks.targets.exeriscommunity.bootstrap;

import eu.exeris.kernel.core.bootstrap.KernelBootstrap;
import eu.exeris.kernel.spi.bootstrap.BootstrapSelector;
import eu.exeris.kernel.spi.http.HttpHandler;
import eu.exeris.kernel.spi.http.HttpKernelProviders;
import java.util.concurrent.atomic.AtomicReference;

public final class ExerisCommunityApplication {

    // Lean default: only HTTP, persistence and crypto bootstrap unless a scenario opts in.
    // Scenarios that need saga orchestration (Flow), graph queries, or the event bus export
    // EXERIS_SUBSYSTEMS with the extra subsystems — e.g. shop-order-saga sets
    // "http,persistence,graph,flow,events,crypto". Only Flow/Graph/Events are gated this way;
    // http/persistence/crypto are always required by the community target.
    private static final String DEFAULT_SUBSYSTEMS = "http,persistence,crypto";
    private static final String SUBSYSTEMS_ENV = "EXERIS_SUBSYSTEMS";
    private static final String LEGACY_ENABLE_TELEMETRY_ENV = "EXERIS_ENABLE_TELEMETRY_SUBSYSTEM";
    private static final String TELEMETRY_JFR_ENABLED_ENV = "EXERIS_TELEMETRY_JFR_ENABLED";
    private static final String HTTP_MAX_VERSION_ENV = "EXERIS_HTTP_MAX_VERSION";
    private static final String HTTP_H2C_UPGRADE_ENABLED_ENV = "EXERIS_HTTP_H2C_UPGRADE_ENABLED";
    private static final String GRAPH_BACKEND_TYPE_ENV = "EXERIS_GRAPH_BACKEND_TYPE";
    private static final String GRAPH_GRAPH_NAME_ENV = "EXERIS_GRAPH_GRAPH_NAME";
    private static final String GRAPH_NEO4J_URI_ENV = "EXERIS_GRAPH_NEO4J_URI";
    private static final String GRAPH_NEO4J_USER_ENV = "EXERIS_GRAPH_NEO4J_USER";
    private static final String GRAPH_NEO4J_PASSWORD_ENV = "EXERIS_GRAPH_NEO4J_PASSWORD";
    private static final String GRAPH_NEO4J_DATABASE_ENV = "EXERIS_GRAPH_NEO4J_DATABASE";
    private static final String TRANSPORT_CERT_PATH_ENV = "EXERIS_TRANSPORT_CERT_PATH";
    private static final String TRANSPORT_KEY_PATH_ENV = "EXERIS_TRANSPORT_KEY_PATH";
    private static final String HTTP_MAX_CONNECTIONS_ENV = "EXERIS_HTTP_MAX_CONNECTIONS";

    private ExerisCommunityApplication() {
    }

    public static void main(String[] args) throws Exception {
        AppConfig appConfig = AppConfig.fromEnv();
        boot(appConfig);
    }

    private static void boot(AppConfig appConfig) throws KernelBootstrap.BootstrapException {
        String subsystems = resolveSubsystems();
        applyBootstrapSystemProperties(appConfig, subsystems);
        AtomicReference<HttpHandler> handlerSlot = new AtomicReference<>();
        HttpHandler forwardingHandler = exchange -> {
            HttpHandler h = handlerSlot.get();
            if (h != null) {
                h.handle(exchange);
            }
        };
        try {
            ScopedValue.where(HttpKernelProviders.HTTP_SERVER_HANDLER, forwardingHandler)
                .call(() -> {
                    KernelBootstrap.builder()
                        .selector(BootstrapSelector.forNames(subsystems.split(",")))
                        .build()
                        .boot(() -> new CommunityBenchmarkRuntimeLifecycle(handlerSlot).run());
                    return null;
                });
        } catch (KernelBootstrap.BootstrapException e) {
            throw e;
        } catch (Exception e) {
            throw new RuntimeException("Exeris community bootstrap failed", e);
        }
    }

    /**
     * Resolves the kernel subsystem set to bootstrap from {@code EXERIS_SUBSYSTEMS},
     * falling back to the lean {@link #DEFAULT_SUBSYSTEMS} set. Returned value is a
     * normalized, comma-separated, de-duplicated, lower-cased list.
     */
    private static String resolveSubsystems() {
        String configured = System.getenv(SUBSYSTEMS_ENV);
        if (configured == null || configured.isBlank()) {
            return DEFAULT_SUBSYSTEMS;
        }
        java.util.LinkedHashSet<String> names = new java.util.LinkedHashSet<>();
        for (String token : configured.split(",")) {
            String name = token.trim().toLowerCase();
            if (!name.isEmpty()) {
                names.add(name);
            }
        }
        return names.isEmpty() ? DEFAULT_SUBSYSTEMS : String.join(",", names);
    }

    private static void applyBootstrapSystemProperties(AppConfig appConfig, String subsystems) {
        java.util.Set<String> enabled = java.util.Set.of(subsystems.split(","));
        System.setProperty("exeris.launcher.subsystems", subsystems);
        System.setProperty("exeris.telemetry.jfrEnabled", Boolean.toString(resolveTelemetryJfrEnabled()));
        System.setProperty("exeris.http.bindHost", "0.0.0.0");
        System.setProperty("exeris.http.port", Integer.toString(appConfig.port()));
        System.setProperty("exeris.http.mode", "SERVER");
        System.setProperty("exeris.http.maxVersion", appConfig.httpMaxVersion());
        System.setProperty("exeris.http.h2cUpgradeEnabled", Boolean.toString(appConfig.h2cUpgradeEnabled()));
        System.setProperty("exeris.http.maxConnections", Integer.toString(appConfig.maxConnections()));
        System.setProperty("exeris.persistence.jdbcUrl", appConfig.jdbcUrl());
        System.setProperty("exeris.persistence.username", appConfig.username());
        System.setProperty("exeris.persistence.password", appConfig.password());
        System.setProperty("exeris.persistence.pool.minSize", Integer.toString(appConfig.poolMinSize()));
        System.setProperty("exeris.persistence.pool.maxSize", Integer.toString(appConfig.poolMaxSize()));
        // Optional connection-acquisition timeout (ms). Only override when explicitly
        // provided so unconstrained runs keep the kernel's default; the constrained
        // smoke raises it to tolerate transient pool queuing under CPU throttling.
        setOptionalSystemProperty("exeris.persistence.connectionTimeoutMs",
                System.getenv("EXERIS_DB_CONNECTION_TIMEOUT_MS"));
        // Only configure Flow/Graph when those subsystems are part of the bootstrap set,
        // so a lean scenario does not imply saga/graph wiring it never bootstraps.
        if (enabled.contains("flow")) {
            System.setProperty("exeris.flow.persistenceEnabled", "true");
        }
        if (enabled.contains("graph")) {
            System.setProperty("exeris.graph.backendType", appConfig.backendType());
            System.setProperty("exeris.graph.graphName", appConfig.graphName());
            setOptionalSystemProperty("exeris.graph.neo4j.uri", appConfig.neo4jUri());
            setOptionalSystemProperty("exeris.graph.neo4j.user", appConfig.neo4jUser());
            setOptionalSystemProperty("exeris.graph.neo4j.password", appConfig.neo4jPassword());
            setOptionalSystemProperty("exeris.graph.neo4j.database", appConfig.neo4jDatabase());
        }
        setOptionalSystemProperty("exeris.transport.certPath", System.getenv(TRANSPORT_CERT_PATH_ENV));
        setOptionalSystemProperty("exeris.transport.keyPath", System.getenv(TRANSPORT_KEY_PATH_ENV));
    }

    private static void setOptionalSystemProperty(String key, String value) {
        if (value != null && !value.isBlank()) {
            System.setProperty(key, value);
        }
    }

    private static boolean resolveTelemetryJfrEnabled() {
        String explicit = System.getenv(TELEMETRY_JFR_ENABLED_ENV);
        if (explicit != null && !explicit.isBlank()) {
            return Boolean.parseBoolean(explicit);
        }
        return Boolean.parseBoolean(System.getenv(LEGACY_ENABLE_TELEMETRY_ENV));
    }

    private record AppConfig(
            String jdbcUrl,
            String username,
            String password,
            int port,
            String httpMaxVersion,
            boolean h2cUpgradeEnabled,
            int poolMinSize,
            int poolMaxSize,
            String backendType,
            String graphName,
            String neo4jUri,
            String neo4jUser,
            String neo4jPassword,
            String neo4jDatabase,
            int maxConnections
    ) {

        private static AppConfig fromEnv() {
            String backendType = parseGraphBackendType(System.getenv(GRAPH_BACKEND_TYPE_ENV));
            String neo4jUri = readOptionalEnv(GRAPH_NEO4J_URI_ENV);
            String neo4jUser = readOptionalEnv(GRAPH_NEO4J_USER_ENV);
            String neo4jPassword = readOptionalEnv(GRAPH_NEO4J_PASSWORD_ENV);

            if ("neo4j".equals(backendType)
                    && (neo4jUri == null || neo4jUser == null || neo4jPassword == null)) {
                throw new IllegalStateException("Missing Neo4j configuration: EXERIS_GRAPH_NEO4J_URI/USER/PASSWORD");
            }

            return new AppConfig(
                    requireEnv("EXERIS_DB_JDBC_URL"),
                    requireEnv("EXERIS_DB_USERNAME"),
                    requireEnv("EXERIS_DB_PASSWORD"),
                    parseIntOrDefault(System.getenv("EXERIS_PORT"), 8080),
                    firstNonBlankOrDefault(HTTP_MAX_VERSION_ENV, "HTTP_2"),
                    parseBooleanOrDefault(System.getenv(HTTP_H2C_UPGRADE_ENABLED_ENV), true),
                    parseIntOrDefault(firstNonBlank("EXERIS_DB_POOL_MIN_SIZE", "EXERIS_DB_POOL_MIN"), 16),
                    parseIntOrDefault(firstNonBlank("EXERIS_DB_POOL_MAX_SIZE", "EXERIS_DB_POOL_MAX"), 256),
                    backendType,
                    firstNonBlankOrDefault(GRAPH_GRAPH_NAME_ENV, "exeris_graph"),
                    neo4jUri,
                    neo4jUser,
                    neo4jPassword,
                    readOptionalEnv(GRAPH_NEO4J_DATABASE_ENV),
                    parseIntOrDefault(System.getenv(HTTP_MAX_CONNECTIONS_ENV), 1_000));
        }

        private static String parseGraphBackendType(String value) {
            if (value == null || value.isBlank()) {
                return "postgresql";
            }
            String normalized = value.trim().toLowerCase();
            return switch (normalized) {
                case "neo4j", "postgresql" -> normalized;
                default -> "postgresql";
            };
        }

        private static String readOptionalEnv(String key) {
            String value = System.getenv(key);
            if (value == null || value.isBlank()) {
                return null;
            }
            return value;
        }

        private static String firstNonBlankOrDefault(String key, String fallback) {
            String value = System.getenv(key);
            if (value == null || value.isBlank()) {
                return fallback;
            }
            return value;
        }

        private static String firstNonBlank(String primary, String fallback) {
            String primaryValue = System.getenv(primary);
            if (primaryValue != null && !primaryValue.isBlank()) {
                return primaryValue;
            }
            return System.getenv(fallback);
        }

        private static int parseIntOrDefault(String value, int fallback) {
            if (value == null || value.isBlank()) {
                return fallback;
            }
            try {
                return Integer.parseInt(value.trim());
            } catch (NumberFormatException exception) {
                return fallback;
            }
        }

        private static boolean parseBooleanOrDefault(String value, boolean fallback) {
            if (value == null || value.isBlank()) {
                return fallback;
            }
            return Boolean.parseBoolean(value.trim());
        }

        private static String requireEnv(String key) {
            String value = System.getenv(key);
            if (value == null || value.isBlank()) {
                throw new IllegalStateException("Missing required environment variable: " + key);
            }
            return value;
        }
    }
}
