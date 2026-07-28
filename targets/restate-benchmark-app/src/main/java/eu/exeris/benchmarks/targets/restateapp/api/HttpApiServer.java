package eu.exeris.benchmarks.targets.restateapp.api;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.sun.net.httpserver.HttpExchange;
import com.sun.net.httpserver.HttpServer;

import eu.exeris.benchmarks.targets.restateapp.api.Dtos.CartAddRequest;
import eu.exeris.benchmarks.targets.restateapp.api.Dtos.CartView;
import eu.exeris.benchmarks.targets.restateapp.api.Dtos.CreateOrderRequest;
import eu.exeris.benchmarks.targets.restateapp.api.Dtos.ErrorResponse;
import eu.exeris.benchmarks.targets.restateapp.api.Dtos.OrderStatusView;
import eu.exeris.benchmarks.targets.restateapp.api.Dtos.OrderTerminalView;
import eu.exeris.benchmarks.targets.restateapp.api.Dtos.ProductView;
import eu.exeris.benchmarks.targets.restateapp.api.Dtos.RegisterRequest;
import eu.exeris.benchmarks.targets.restateapp.api.Dtos.RegisterResponse;
import eu.exeris.benchmarks.targets.restateapp.application.AuthTokenService;
import eu.exeris.benchmarks.targets.restateapp.application.BearerTokenService;
import eu.exeris.benchmarks.targets.restateapp.application.OrderSagaClient;
import eu.exeris.benchmarks.targets.restateapp.application.ProductCatalogService;
import eu.exeris.benchmarks.targets.restateapp.application.ShopSagaStateService;
import eu.exeris.benchmarks.targets.restateapp.saga.OrderSagaRequest;
import eu.exeris.benchmarks.targets.restateapp.saga.OrderSagaResult;
import eu.exeris.benchmarks.targets.restateapp.saga.OrderStatusProjection;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

import java.io.IOException;
import java.io.OutputStream;
import java.net.InetSocketAddress;
import java.net.URI;
import java.nio.charset.StandardCharsets;
import java.util.List;
import java.util.Optional;
import java.util.UUID;
import java.util.concurrent.Executors;

/**
 * k6-facing HTTP facade (HTTP/1.1, JDK built-in com.sun.net.httpserver on
 * virtual threads). Exposes the exact endpoint surface of the reference
 * stacks so scenarios/e2e-shop-order-saga/k6.js runs unchanged:
 *
 *   GET  /health
 *   POST /api/v1/auth/register
 *   GET  /api/v1/products/recommended?limit=N
 *   POST /api/v1/cart/add
 *   GET  /api/v1/cart
 *   POST /api/v1/orders                       (v2 request-response: 200 + terminal outcome)
 *   GET  /api/v1/orders/{orderId}/status
 */
public final class HttpApiServer {

    private static final Logger log = LoggerFactory.getLogger(HttpApiServer.class);

    private final ObjectMapper objectMapper;
    private final BearerTokenService tokenService;
    private final AuthTokenService authTokenService;
    private final ProductCatalogService productCatalogService;
    private final ShopSagaStateService shopSagaStateService;
    private final OrderSagaClient orderSagaClient;
    private final OrderStatusProjection projection;

    private HttpServer server;

    public HttpApiServer(
            ObjectMapper objectMapper,
            BearerTokenService tokenService,
            AuthTokenService authTokenService,
            ProductCatalogService productCatalogService,
            ShopSagaStateService shopSagaStateService,
            OrderSagaClient orderSagaClient,
            OrderStatusProjection projection
    ) {
        this.objectMapper = objectMapper;
        this.tokenService = tokenService;
        this.authTokenService = authTokenService;
        this.productCatalogService = productCatalogService;
        this.shopSagaStateService = shopSagaStateService;
        this.orderSagaClient = orderSagaClient;
        this.projection = projection;
    }

    public void start(int port) throws IOException {
        server = HttpServer.create(new InetSocketAddress(port), 1024);
        server.setExecutor(Executors.newVirtualThreadPerTaskExecutor());
        server.createContext("/health", this::handleHealth);
        server.createContext("/api/v1/auth/register", this::handleRegister);
        server.createContext("/api/v1/products/recommended", this::handleRecommended);
        server.createContext("/api/v1/cart/add", this::handleCartAdd);
        server.createContext("/api/v1/cart", this::handleCart);
        server.createContext("/api/v1/orders", this::handleOrders);
        server.start();
        log.info("HTTP facade listening on port {}", port);
    }

    public void stop() {
        if (server != null) {
            server.stop(0);
        }
    }

    private void handleHealth(HttpExchange exchange) throws IOException {
        if (!"GET".equals(exchange.getRequestMethod())) {
            sendStatus(exchange, 405);
            return;
        }
        sendJson(exchange, 200, "{\"status\":\"UP\"}".getBytes(StandardCharsets.UTF_8));
    }

    private void handleRegister(HttpExchange exchange) throws IOException {
        if (!"POST".equals(exchange.getRequestMethod())) {
            sendStatus(exchange, 405);
            return;
        }
        RegisterRequest request = readBody(exchange, RegisterRequest.class);
        if (request == null || isBlank(request.username()) || isBlank(request.email()) || isBlank(request.password())) {
            sendJson(exchange, 400, new ErrorResponse("invalid_register_request"));
            return;
        }
        Optional<AuthTokenService.RegisteredUser> registered =
                authTokenService.register(request.username(), request.email(), request.password());
        if (registered.isEmpty()) {
            sendJson(exchange, 409, new ErrorResponse("user_exists"));
            return;
        }
        AuthTokenService.RegisteredUser user = registered.get();
        sendJson(exchange, 201, new RegisterResponse(user.token(), user.userId()));
    }

    private void handleRecommended(HttpExchange exchange) throws IOException {
        if (!"GET".equals(exchange.getRequestMethod())) {
            sendStatus(exchange, 405);
            return;
        }
        Long userId = authenticate(exchange);
        if (userId == null) {
            return;
        }
        int limit = parseLimit(exchange.getRequestURI());
        List<ProductView> products = productCatalogService.recommendedProducts(userId, limit);
        sendJson(exchange, 200, products);
    }

    private void handleCartAdd(HttpExchange exchange) throws IOException {
        if (!"POST".equals(exchange.getRequestMethod())) {
            sendStatus(exchange, 405);
            return;
        }
        Long userId = authenticate(exchange);
        if (userId == null) {
            return;
        }
        CartAddRequest request = readBody(exchange, CartAddRequest.class);
        if (request == null || isBlank(request.productId()) || request.quantity() <= 0) {
            sendJson(exchange, 400, new ErrorResponse("invalid_cart_request"));
            return;
        }
        try {
            CartView cart = shopSagaStateService.addToCart(
                    Long.toString(userId), request.productId(), request.quantity());
            sendJson(exchange, 201, cart);
        } catch (RuntimeException e) {
            log.warn("addToCart failed for user {}: {}", userId, e.getMessage());
            sendJson(exchange, 500, new ErrorResponse("cart_add_failed"));
        }
    }

    private void handleCart(HttpExchange exchange) throws IOException {
        if (!"GET".equals(exchange.getRequestMethod())) {
            sendStatus(exchange, 405);
            return;
        }
        Long userId = authenticate(exchange);
        if (userId == null) {
            return;
        }
        try {
            CartView cart = shopSagaStateService.getOrCreateCart(Long.toString(userId));
            sendJson(exchange, 200, cart);
        } catch (RuntimeException e) {
            log.warn("getCart failed for user {}: {}", userId, e.getMessage());
            sendJson(exchange, 500, new ErrorResponse("cart_read_failed"));
        }
    }

    /** Dispatches POST /api/v1/orders and GET /api/v1/orders/{orderId}/status. */
    private void handleOrders(HttpExchange exchange) throws IOException {
        String path = exchange.getRequestURI().getPath();
        if ("/api/v1/orders".equals(path) || "/api/v1/orders/".equals(path)) {
            handleCreateOrder(exchange);
            return;
        }
        if ("GET".equals(exchange.getRequestMethod()) && path.startsWith("/api/v1/orders/") && path.endsWith("/status")) {
            String orderId = path.substring("/api/v1/orders/".length(), path.length() - "/status".length());
            handleOrderStatus(exchange, orderId);
            return;
        }
        sendStatus(exchange, 404);
    }

    private void handleCreateOrder(HttpExchange exchange) throws IOException {
        if (!"POST".equals(exchange.getRequestMethod())) {
            sendStatus(exchange, 405);
            return;
        }
        Long userId = authenticate(exchange);
        if (userId == null) {
            return;
        }
        CreateOrderRequest request = readBody(exchange, CreateOrderRequest.class);
        if (request == null || isBlank(request.cartId()) || isBlank(request.paymentMethod())) {
            sendJson(exchange, 400, new ErrorResponse("invalid_order_request"));
            return;
        }
        if (!shopSagaStateService.hasCartForUser(Long.toString(userId), request.cartId())) {
            sendJson(exchange, 404, new ErrorResponse("cart_not_found"));
            return;
        }
        // CONTRACT-v2 §3: prefer the client-generated orderId (deterministic seeded
        // population, prerequisite for the §4.1 exact decline oracle); fall back to
        // a server-generated UUID when the harness does not supply one.
        String orderId = isBlank(request.orderId())
                ? UUID.randomUUID().toString()
                : request.orderId().trim();
        String sagaId = "saga-" + UUID.randomUUID();
        try {
            OrderSagaResult result = orderSagaClient.run(new OrderSagaRequest(
                    orderId, Long.toString(userId), request.cartId().trim(),
                    request.paymentMethod().trim(), sagaId));
            // v2 request-response: terminal outcome in the 200 body — k6 skips polling.
            sendJson(exchange, 200, new OrderTerminalView(result.orderId(), result.status(), result.sagaId()));
        } catch (OrderSagaClient.SagaSubmissionException e) {
            log.error("order {} saga submission failed: {}", orderId, e.getMessage());
            sendJson(exchange, 502, new ErrorResponse("saga_submission_failed"));
        }
    }

    private void handleOrderStatus(HttpExchange exchange, String orderId) throws IOException {
        Long userId = authenticate(exchange);
        if (userId == null) {
            return;
        }
        Optional<OrderStatusProjection.OrderStatusEntry> status =
                projection.findForUser(Long.toString(userId), orderId);
        if (status.isEmpty()) {
            sendJson(exchange, 404, new ErrorResponse("order_not_found"));
            return;
        }
        sendJson(exchange, 200, new OrderStatusView(orderId, status.get().status(), status.get().sagaId()));
    }

    /**
     * Returns the authenticated userId, or null after writing the 401 response.
     * RS256 signature + expiry check, then the principal→user_id DB lookup —
     * the same two-step auth cost every reference stack pays per request.
     */
    private Long authenticate(HttpExchange exchange) throws IOException {
        String header = exchange.getRequestHeaders().getFirst("Authorization");
        if (header != null && header.regionMatches(true, 0, "Bearer ", 0, 7)) {
            Optional<UUID> principalId = tokenService.verify(header.substring(7).trim());
            if (principalId.isPresent()) {
                Optional<Long> userId = authTokenService.findUserId(principalId.get());
                if (userId.isPresent()) {
                    return userId.get();
                }
            }
        }
        sendJson(exchange, 401, new ErrorResponse("unauthorized"));
        return null;
    }

    private <T> T readBody(HttpExchange exchange, Class<T> type) {
        try {
            byte[] body = exchange.getRequestBody().readAllBytes();
            if (body.length == 0) {
                return null;
            }
            return objectMapper.readValue(body, type);
        } catch (Exception e) {
            return null;
        }
    }

    private void sendJson(HttpExchange exchange, int status, Object body) throws IOException {
        sendJson(exchange, status, objectMapper.writeValueAsBytes(body));
    }

    private void sendJson(HttpExchange exchange, int status, byte[] body) throws IOException {
        exchange.getResponseHeaders().set("Content-Type", "application/json");
        exchange.sendResponseHeaders(status, body.length);
        try (OutputStream out = exchange.getResponseBody()) {
            out.write(body);
        }
    }

    private void sendStatus(HttpExchange exchange, int status) throws IOException {
        exchange.sendResponseHeaders(status, -1);
        exchange.close();
    }

    private static boolean isBlank(String value) {
        return value == null || value.trim().isEmpty();
    }

    private static int parseLimit(URI uri) {
        String query = uri.getQuery();
        if (query != null) {
            for (String param : query.split("&")) {
                if (param.startsWith("limit=")) {
                    try {
                        int limit = Integer.parseInt(param.substring(6));
                        if (limit > 0) {
                            return Math.min(limit, 50);
                        }
                    } catch (NumberFormatException ignored) {
                    }
                }
            }
        }
        return 10;
    }
}
