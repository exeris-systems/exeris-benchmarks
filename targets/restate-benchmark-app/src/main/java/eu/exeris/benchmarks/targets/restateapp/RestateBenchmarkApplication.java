package eu.exeris.benchmarks.targets.restateapp;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.zaxxer.hikari.HikariConfig;
import com.zaxxer.hikari.HikariDataSource;

import dev.restate.sdk.endpoint.Endpoint;
import dev.restate.sdk.http.vertx.RestateHttpServer;

import eu.exeris.benchmarks.targets.restateapp.api.HttpApiServer;
import eu.exeris.benchmarks.targets.restateapp.application.AuthTokenService;
import eu.exeris.benchmarks.targets.restateapp.application.BearerTokenService;
import eu.exeris.benchmarks.targets.restateapp.application.GraphShopService;
import eu.exeris.benchmarks.targets.restateapp.application.OrderSagaClient;
import eu.exeris.benchmarks.targets.restateapp.application.ProductCatalogService;
import eu.exeris.benchmarks.targets.restateapp.application.ShopSagaStateService;
import eu.exeris.benchmarks.targets.restateapp.saga.OrderSagaSqlSteps;
import eu.exeris.benchmarks.targets.restateapp.saga.OrderSagaWorkflow;
import eu.exeris.benchmarks.targets.restateapp.saga.OrderStatusProjection;
import eu.exeris.benchmarks.targets.restateapp.saga.SagaFaultMode;
import eu.exeris.benchmarks.targets.restateapp.saga.SagaRetryPolicyConfig;

import org.neo4j.driver.AuthTokens;
import org.neo4j.driver.Driver;
import org.neo4j.driver.GraphDatabase;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.nio.charset.StandardCharsets;
import java.time.Duration;
import java.util.Locale;
import java.util.Map;

/**
 * Restate benchmark target for e2e-shop-order-saga (CONTRACT-v2).
 *
 * Deployment unit (CONTRACT-v2 §1): this service JVM + an externally launched
 * restate-server. This process hosts BOTH the k6-facing HTTP facade
 * (EXERIS_PORT, default 9004) and the Restate SDK service endpoint
 * (RESTATE_SDK_PORT, default 9084) that restate-server invokes.
 *
 * POST /api/v1/orders → facade submits OrderSaga/run to the restate-server
 * ingress (idempotency-key = client orderId) and returns the terminal saga
 * outcome in the 200 response body (v2 request-response model).
 */
public final class RestateBenchmarkApplication {

    private static final Logger log = LoggerFactory.getLogger(RestateBenchmarkApplication.class);

    public static void main(String[] args) throws Exception {
        Map<String, String> env = System.getenv();

        int facadePort = intEnv(env, "EXERIS_PORT", 9004);
        int sdkPort = intEnv(env, "RESTATE_SDK_PORT", 9084);
        String ingressUrl = env.getOrDefault("RESTATE_INGRESS_URL", "http://localhost:8080");
        String adminUrl = env.getOrDefault("RESTATE_ADMIN_URL", "http://localhost:9070");
        String advertisedSdkUrl = env.getOrDefault("RESTATE_SDK_ADVERTISED_URL", "http://localhost:" + sdkPort);
        boolean autoRegister = !"false".equalsIgnoreCase(env.getOrDefault("RESTATE_AUTO_REGISTER", "true"));

        HikariDataSource dataSource = buildDataSource(env);
        Driver neo4jDriver = buildNeo4jDriver(env);

        ObjectMapper objectMapper = new ObjectMapper()
                .disable(com.fasterxml.jackson.databind.DeserializationFeature.FAIL_ON_UNKNOWN_PROPERTIES);
        SagaFaultMode faultMode = SagaFaultMode.fromEnv(env);
        SagaRetryPolicyConfig retryConfig = SagaRetryPolicyConfig.fromEnv(env);
        log.info("saga fault mode: {}; retry policy (CONTRACT-v2 §5): maxAttempts={}, initialBackoffMs={}, factor={}, jitter=none",
                faultMode, retryConfig.maxAttempts(), retryConfig.initialBackoffMs(), retryConfig.backoffFactor());

        OrderStatusProjection projection = new OrderStatusProjection();
        OrderSagaSqlSteps sqlSteps = new OrderSagaSqlSteps(dataSource);
        OrderSagaWorkflow workflow = new OrderSagaWorkflow(sqlSteps, projection, faultMode, retryConfig);

        // Service-level invocation retry policy pinned at bind time so
        // restate-server defaults (max-attempts=70) are never trusted (§5).
        Endpoint.Builder endpoint = Endpoint.bind(workflow,
                configurator -> configurator.invocationRetryPolicy(retryConfig.toInvocationRetryPolicy()));
        int boundSdkPort = RestateHttpServer.listen(endpoint, sdkPort);
        log.info("Restate SDK endpoint listening on port {}", boundSdkPort);

        if (autoRegister) {
            // Background so facade startup (and /health) is not gated on restate-server.
            Thread.ofVirtual().name("restate-deployment-register")
                    .start(() -> registerDeployment(adminUrl, advertisedSdkUrl));
        }

        GraphShopService graphShopService = new GraphShopService(neo4jDriver, dataSource);
        // RS256 RSA-2048 keypair generated at boot — auth parity with the reference stacks.
        BearerTokenService tokenService = new BearerTokenService();
        HttpApiServer facade = new HttpApiServer(
                objectMapper,
                tokenService,
                new AuthTokenService(dataSource, tokenService),
                new ProductCatalogService(dataSource, graphShopService),
                new ShopSagaStateService(dataSource, graphShopService),
                new OrderSagaClient(ingressUrl, objectMapper),
                projection
        );
        facade.start(facadePort);

        Runtime.getRuntime().addShutdownHook(new Thread(() -> {
            facade.stop();
            dataSource.close();
            if (neo4jDriver != null) {
                neo4jDriver.close();
            }
        }, "restate-benchmark-app-shutdown"));

        log.info("restate-benchmark-app up: facade=:{} sdk=:{} ingress={} admin={}",
                facadePort, boundSdkPort, ingressUrl, adminUrl);
        Thread.currentThread().join();
    }

    private static HikariDataSource buildDataSource(Map<String, String> env) {
        HikariConfig config = new HikariConfig();
        config.setJdbcUrl(env.getOrDefault("EXERIS_DB_JDBC_URL",
                "jdbc:postgresql://localhost:5432/postgres?prepareThreshold=1"));
        config.setUsername(env.getOrDefault("EXERIS_DB_USERNAME", "postgres"));
        config.setPassword(env.getOrDefault("EXERIS_DB_PASSWORD", "postgres"));
        config.setMinimumIdle(intEnv(env, "EXERIS_DB_POOL_MIN_SIZE", 16));
        config.setMaximumPoolSize(intEnv(env, "EXERIS_DB_POOL_MAX_SIZE", 256));
        config.setPoolName("restate-benchmark-app");
        // Lazy pool init: the launcher's health poll may hit /health before
        // benchmark-postgres finishes coming up; don't fail-fast at startup.
        config.setInitializationFailTimeout(-1);
        return new HikariDataSource(config);
    }

    /**
     * Neo4j driver is created only on the neo4j graph track
     * (EXERIS_GRAPH_BACKEND_TYPE=neo4j, exported by the baseline runner);
     * otherwise the GraphShopService falls back to the PGQ SQL path — the same
     * switch the reference stacks use.
     */
    private static Driver buildNeo4jDriver(Map<String, String> env) {
        String backendType = env.getOrDefault("EXERIS_GRAPH_BACKEND_TYPE", "").trim().toLowerCase(Locale.ROOT);
        if (!"neo4j".equals(backendType)) {
            return null;
        }
        String uri = env.getOrDefault("EXERIS_GRAPH_NEO4J_URI", "bolt://localhost:7687");
        String user = env.getOrDefault("EXERIS_GRAPH_NEO4J_USER", "neo4j");
        String password = env.getOrDefault("EXERIS_GRAPH_NEO4J_PASSWORD", "benchmark");
        return GraphDatabase.driver(uri, AuthTokens.basic(user, password));
    }

    /**
     * Best-effort deployment registration against the restate-server admin API
     * (POST /deployments, force=true for benchmark re-runs). Retries while the
     * admin endpoint comes up; failure is non-fatal so an operator can still
     * register manually via `restate deployments register`.
     */
    private static void registerDeployment(String adminUrl, String advertisedSdkUrl) {
        String base = adminUrl.endsWith("/") ? adminUrl.substring(0, adminUrl.length() - 1) : adminUrl;
        String body = "{\"uri\":\"" + advertisedSdkUrl + "\",\"force\":true}";
        HttpClient client = HttpClient.newBuilder().connectTimeout(Duration.ofSeconds(2)).build();
        HttpRequest request = HttpRequest.newBuilder(URI.create(base + "/deployments"))
                .timeout(Duration.ofSeconds(10))
                .header("content-type", "application/json")
                .POST(HttpRequest.BodyPublishers.ofString(body, StandardCharsets.UTF_8))
                .build();
        for (int attempt = 1; attempt <= 30; attempt++) {
            try {
                HttpResponse<String> response = client.send(request, HttpResponse.BodyHandlers.ofString());
                if (response.statusCode() >= 200 && response.statusCode() < 300) {
                    log.info("registered deployment {} at {} (attempt {})", advertisedSdkUrl, base, attempt);
                    return;
                }
                log.warn("deployment registration attempt {} returned HTTP {}: {}",
                        attempt, response.statusCode(), response.body());
            } catch (InterruptedException e) {
                Thread.currentThread().interrupt();
                return;
            } catch (Exception e) {
                log.info("deployment registration attempt {} failed ({}); retrying", attempt, e.getMessage());
            }
            try {
                Thread.sleep(1000);
            } catch (InterruptedException e) {
                Thread.currentThread().interrupt();
                return;
            }
        }
        log.warn("deployment auto-registration gave up after 30 attempts — register manually: "
                + "restate deployments register {}", advertisedSdkUrl);
    }

    private static int intEnv(Map<String, String> env, String name, int fallback) {
        String value = env.get(name);
        if (value == null || value.isBlank()) {
            return fallback;
        }
        try {
            return Integer.parseInt(value.trim());
        } catch (NumberFormatException e) {
            log.warn("{}='{}' is not an integer — defaulting to {}", name, value, fallback);
            return fallback;
        }
    }

    private RestateBenchmarkApplication() {
    }
}
