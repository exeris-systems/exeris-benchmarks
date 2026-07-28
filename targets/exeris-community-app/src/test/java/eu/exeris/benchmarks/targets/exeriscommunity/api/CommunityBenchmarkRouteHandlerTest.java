package eu.exeris.benchmarks.targets.exeriscommunity.api;

import java.lang.foreign.ValueLayout;
import java.nio.charset.StandardCharsets;
import java.util.List;
import java.util.Map;
import java.util.OptionalLong;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertTrue;
import org.junit.jupiter.api.Test;

import eu.exeris.benchmarks.targets.exeriscommunity.application.BenchmarkUseCaseService;
import eu.exeris.benchmarks.targets.exeriscommunity.domain.shop.CartView;
import eu.exeris.benchmarks.targets.exeriscommunity.domain.shop.OrderResponse;
import eu.exeris.benchmarks.targets.exeriscommunity.domain.shop.OrderStatusResponse;
import eu.exeris.benchmarks.targets.exeriscommunity.domain.shop.ProductView;
import eu.exeris.benchmarks.targets.exeriscommunity.domain.shop.TokenResponse;
import eu.exeris.benchmarks.targets.exeriscommunity.domain.user.UserSummary;
import eu.exeris.benchmarks.targets.exeriscommunity.domain.user.UserView;
import eu.exeris.benchmarks.targets.exeriscommunity.infrastructure.graph.GraphUnavailableException;
import eu.exeris.benchmarks.targets.exeriscommunity.security.BenchmarkJwtSecurityProvider;
import eu.exeris.benchmarks.targets.exeriscommunity.security.BenchmarkTokenIssuer;
import eu.exeris.kernel.core.security.SecurityInterceptor;
import eu.exeris.kernel.spi.http.HttpMethod;
import eu.exeris.kernel.spi.http.HttpRequest;
import eu.exeris.kernel.spi.http.HttpStatus;
import eu.exeris.kernel.spi.http.HttpVersion;
import tools.jackson.core.JacksonException;
import tools.jackson.databind.ObjectMapper;

final class CommunityBenchmarkRouteHandlerTest {

    private static final ObjectMapper OBJECT_MAPPER = new ObjectMapper();

    @Test
    void healthRouteRespondsWithNoBodyStatusOk() {
        BenchmarkUseCaseService useCaseService = new StaticUseCaseService();
        CommunityBenchmarkRouteHandler handler = new CommunityBenchmarkRouteHandler(
            useCaseService,
            testSecurityProvider(),
            ignored -> OptionalLong.of(1L),
            new TestSupport.CapturingAllocator()
        );
        TestSupport.CapturingExchange exchange = TestSupport.CapturingExchange.get("/health");

        handler.handleHealth(exchange);

        assertNotNull(exchange.response());
        assertFalse(exchange.response().hasBody());
        assertEquals(HttpStatus.OK, exchange.response().status());
    }

    @Test
    void plaintextRouteRespondsWithPlaintextBody() {
        BenchmarkUseCaseService useCaseService = new StaticUseCaseService();
        TestSupport.CapturingAllocator allocator = new TestSupport.CapturingAllocator();
        CommunityBenchmarkRouteHandler handler = new CommunityBenchmarkRouteHandler(
            useCaseService,
            testSecurityProvider(),
            ignored -> OptionalLong.of(1L),
            allocator
        );
        TestSupport.CapturingExchange exchange = TestSupport.CapturingExchange.get("/plaintext");

        handler.handlePlaintext(exchange);

        assertNotNull(exchange.response());
        assertTrue(exchange.response().hasBody());
        assertEquals(HttpStatus.OK, exchange.response().status());

        byte[] payload = exchange.response().body()
            .segment()
            .asSlice(0L, exchange.response().body().size())
            .toArray(ValueLayout.JAVA_BYTE);

        assertEquals("plaintext", new String(payload, StandardCharsets.US_ASCII));
        assertEquals(0, allocator.lastAllocated().closeCount());

        exchange.response().body().close();
        assertEquals(1, allocator.lastAllocated().closeCount());
    }

    @Test
    void respondNoBodyKeepsHttp2Version() {
        TestSupport.CapturingExchange exchange = new TestSupport.CapturingExchange(HttpRequest.noBody(
            HttpMethod.GET,
            "/health",
            HttpVersion.HTTP_2,
            List.of()
        ));

        CommunityBenchmarkRouteHandler.respondNoBody(exchange, HttpStatus.BAD_REQUEST);

        assertNotNull(exchange.response());
        assertEquals(HttpVersion.HTTP_2, exchange.response().version());
        assertEquals(HttpStatus.BAD_REQUEST, exchange.response().status());
    }

    @Test
    void usersRouteRespondsWithJsonBodyAndBufferHandedOff() {
        BenchmarkUseCaseService useCaseService = new StaticUseCaseService();
        TestSupport.CapturingAllocator allocator = new TestSupport.CapturingAllocator();
        CommunityBenchmarkRouteHandler handler = new CommunityBenchmarkRouteHandler(
            useCaseService,
            testSecurityProvider(),
            ignored -> OptionalLong.of(1L),
            allocator
        );
        TestSupport.AsyncCapturingExchange exchange = TestSupport.AsyncCapturingExchange.get("/api/v1/users", allocator);

        handler.handleUsers(exchange);

        assertNotNull(exchange.response());
        assertTrue(exchange.response().hasBody());
        assertEquals(HttpStatus.OK, exchange.response().status());
        assertEquals(0, allocator.lastAllocated().closeCount());

        exchange.consumeBody();

        assertEquals(1, allocator.lastAllocated().closeCount());
    }

    @Test
    void friendsOfFriendsWithoutInterestsRouteRespondsWithJsonBodyAndStatusOk() {
        UUID userId = UUID.randomUUID();
        BenchmarkUseCaseService useCaseService = new StaticUseCaseService();
        TestSupport.CapturingAllocator allocator = new TestSupport.CapturingAllocator();
        CommunityBenchmarkRouteHandler handler = new CommunityBenchmarkRouteHandler(
            useCaseService,
            testSecurityProvider(),
            ignored -> OptionalLong.of(1L),
            allocator
        );
        TestSupport.AsyncCapturingExchange exchange = TestSupport.AsyncCapturingExchange.get(
            "/api/v1/graph/friends-of-friends/without-interests?userId=" + userId + "&limit=2",
            allocator
        );

        handler.handleFriendsOfFriendsWithoutInterests(exchange);

        assertNotNull(exchange.response());
        assertTrue(exchange.response().hasBody());
        assertEquals(HttpStatus.OK, exchange.response().status());
        assertEquals(0, allocator.lastAllocated().closeCount());

        exchange.consumeBody();

        assertEquals(1, allocator.lastAllocated().closeCount());
    }

    @Test
    void friendsOfFriendsWithoutInterestsRouteRespondsBadRequestWhenUserIdMissing() {
        BenchmarkUseCaseService useCaseService = new StaticUseCaseService();
        CommunityBenchmarkRouteHandler handler = new CommunityBenchmarkRouteHandler(
            useCaseService,
            testSecurityProvider(),
            ignored -> OptionalLong.of(1L),
            new TestSupport.CapturingAllocator()
        );
        TestSupport.CapturingExchange exchange = TestSupport.CapturingExchange.get(
            "/api/v1/graph/friends-of-friends/without-interests?limit=10"
        );

        handler.handleFriendsOfFriendsWithoutInterests(exchange);

        assertNotNull(exchange.response());
        assertFalse(exchange.response().hasBody());
        assertEquals(HttpStatus.BAD_REQUEST, exchange.response().status());
    }

    @Test
    void friendsOfFriendsWithoutInterestsRouteRespondsServiceUnavailableOnGraphFailure() {
        BenchmarkUseCaseService useCaseService = new GraphFailingUseCaseService();
        CommunityBenchmarkRouteHandler handler = new CommunityBenchmarkRouteHandler(
            useCaseService,
            testSecurityProvider(),
            ignored -> OptionalLong.of(1L),
            new TestSupport.CapturingAllocator()
        );
        TestSupport.CapturingExchange exchange = TestSupport.CapturingExchange.get(
            "/api/v1/graph/friends-of-friends/without-interests?userId=" + UUID.randomUUID()
        );

        handler.handleFriendsOfFriendsWithoutInterests(exchange);

        assertNotNull(exchange.response());
        assertFalse(exchange.response().hasBody());
        assertEquals(HttpStatus.SERVICE_UNAVAILABLE, exchange.response().status());
    }

    @Test
    void registerRouteReturnsCreatedOnValidPayload() {
        TestSupport.CapturingAllocator allocator = new TestSupport.CapturingAllocator();
        CommunityBenchmarkRouteHandler handler = new CommunityBenchmarkRouteHandler(
            new StaticUseCaseService(),
            testSecurityProvider(),
            ignored -> OptionalLong.of(1L),
            allocator
        );
        TestSupport.AsyncCapturingExchange exchange = TestSupport.AsyncCapturingExchange.postJson(
            "/api/v1/auth/register",
            "{\"username\":\"alice\",\"email\":\"alice@shop.local\",\"password\":\"secret\"}",
            Map.of(),
            allocator
        );

        handler.handleRegister(exchange);

        assertEquals(HttpStatus.CREATED, exchange.response().status());
        assertTrue(exchange.response().hasBody());
    }

    @Test
    void scenarioRoutesReturnExpectedStatusesForHappyPath() {
        BenchmarkTokenIssuer issuer = new BenchmarkTokenIssuer();
        String token = issuer.issueToken(UUID.randomUUID());
        TestSupport.CapturingAllocator allocator = new TestSupport.CapturingAllocator();
        CommunityBenchmarkRouteHandler handler = new CommunityBenchmarkRouteHandler(
            new StaticUseCaseService(),
            new SecurityInterceptor(new BenchmarkJwtSecurityProvider(
                Map.of(BenchmarkTokenIssuer.KID, issuer.publicKey()),
                BenchmarkTokenIssuer.ISSUER,
                BenchmarkTokenIssuer.AUD
            )),
            ignored -> OptionalLong.of(1L),
            allocator
        );

        TestSupport.AsyncCapturingExchange recommended = TestSupport.AsyncCapturingExchange.get(
            "/api/v1/products/recommended?limit=10",
            Map.of("Authorization", "Bearer " + token),
            allocator
        );
        handler.handleRecommendedProducts(recommended);
        assertEquals(HttpStatus.OK, recommended.response().status());

        TestSupport.AsyncCapturingExchange addCart = TestSupport.AsyncCapturingExchange.postJson(
            "/api/v1/cart/add",
            "{\"productId\":1,\"quantity\":2}",
            Map.of("Authorization", "Bearer " + token),
            allocator
        );
        handler.handleAddToCart(addCart);
        assertEquals(HttpStatus.OK, addCart.response().status());

        TestSupport.AsyncCapturingExchange getCart = TestSupport.AsyncCapturingExchange.get(
            "/api/v1/cart",
            Map.of("Authorization", "Bearer " + token),
            allocator
        );
        handler.handleGetCart(getCart);
        assertEquals(HttpStatus.OK, getCart.response().status());

        TestSupport.AsyncCapturingExchange placeOrder = TestSupport.AsyncCapturingExchange.postJson(
            "/api/v1/orders",
            "{\"cartId\":1,\"paymentMethod\":\"CARD\"}",
            Map.of("Authorization", "Bearer " + token),
            allocator
        );
        handler.handlePlaceOrder(placeOrder);
        assertEquals(HttpStatus.ACCEPTED, placeOrder.response().status());

        TestSupport.AsyncCapturingExchange status = TestSupport.AsyncCapturingExchange.get(
            "/api/v1/orders/1/status",
            Map.of("Authorization", "Bearer " + token),
            allocator
        );
        handler.handleOrderStatus(status);
        assertEquals(HttpStatus.OK, status.response().status());
    }

    @Test
    void addToCartRouteAcceptsSnakeCasePayload() {
        BenchmarkTokenIssuer issuer = new BenchmarkTokenIssuer();
        String token = issuer.issueToken(UUID.randomUUID());
        TestSupport.CapturingAllocator allocator = new TestSupport.CapturingAllocator();
        CommunityBenchmarkRouteHandler handler = new CommunityBenchmarkRouteHandler(
            new StaticUseCaseService(),
            new SecurityInterceptor(new BenchmarkJwtSecurityProvider(
                Map.of(BenchmarkTokenIssuer.KID, issuer.publicKey()),
                BenchmarkTokenIssuer.ISSUER,
                BenchmarkTokenIssuer.AUD
            )),
            ignored -> OptionalLong.of(1L),
            allocator
        );

        TestSupport.AsyncCapturingExchange addCart = TestSupport.AsyncCapturingExchange.postJson(
            "/api/v1/cart/add",
            "{\"product_id\":1,\"quantity\":2}",
            Map.of("Authorization", "Bearer " + token),
            allocator
        );

        handler.handleAddToCart(addCart);

        assertEquals(HttpStatus.OK, addCart.response().status());
    }

    @Test
    void placeOrderRouteAcceptsSnakeCasePayload() {
        BenchmarkTokenIssuer issuer = new BenchmarkTokenIssuer();
        String token = issuer.issueToken(UUID.randomUUID());
        TestSupport.CapturingAllocator allocator = new TestSupport.CapturingAllocator();
        CommunityBenchmarkRouteHandler handler = new CommunityBenchmarkRouteHandler(
            new StaticUseCaseService(),
            new SecurityInterceptor(new BenchmarkJwtSecurityProvider(
                Map.of(BenchmarkTokenIssuer.KID, issuer.publicKey()),
                BenchmarkTokenIssuer.ISSUER,
                BenchmarkTokenIssuer.AUD
            )),
            ignored -> OptionalLong.of(1L),
            allocator
        );

        TestSupport.AsyncCapturingExchange placeOrder = TestSupport.AsyncCapturingExchange.postJson(
            "/api/v1/orders",
            "{\"cart_id\":1,\"payment_method\":\"CARD\"}",
            Map.of("Authorization", "Bearer " + token),
            allocator
        );

        handler.handlePlaceOrder(placeOrder);

        assertEquals(HttpStatus.ACCEPTED, placeOrder.response().status());

        Map<String, Object> responseBody = parseJsonResponse(placeOrder);
        assertTrue(responseBody.get("order_id") instanceof String);
        assertEquals("9007199254740993", responseBody.get("order_id"));

        placeOrder.consumeBody();
    }

    @Test
    void placeOrderRouteAdoptsClientGeneratedOrderIdVerbatim() {
        // CONTRACT-v2 section 3: the client-generated seeded orderId in the POST body
        // is the API-level order identity — and the section 4.1 decline key — so it
        // must round-trip verbatim, never replaced by the server-side DB id.
        BenchmarkTokenIssuer issuer = new BenchmarkTokenIssuer();
        String token = issuer.issueToken(UUID.randomUUID());
        TestSupport.CapturingAllocator allocator = new TestSupport.CapturingAllocator();
        CommunityBenchmarkRouteHandler handler = new CommunityBenchmarkRouteHandler(
            new StaticUseCaseService(),
            new SecurityInterceptor(new BenchmarkJwtSecurityProvider(
                Map.of(BenchmarkTokenIssuer.KID, issuer.publicKey()),
                BenchmarkTokenIssuer.ISSUER,
                BenchmarkTokenIssuer.AUD
            )),
            ignored -> OptionalLong.of(1L),
            allocator
        );

        String clientOrderId = "exeris-saga-v2-measurement-i0";
        TestSupport.AsyncCapturingExchange placeOrder = TestSupport.AsyncCapturingExchange.postJson(
            "/api/v1/orders",
            "{\"cart_id\":1,\"payment_method\":\"CARD\",\"order_id\":\"" + clientOrderId + "\"}",
            Map.of("Authorization", "Bearer " + token),
            allocator
        );

        handler.handlePlaceOrder(placeOrder);

        assertEquals(HttpStatus.ACCEPTED, placeOrder.response().status());

        Map<String, Object> responseBody = parseJsonResponse(placeOrder);
        assertEquals(clientOrderId, responseBody.get("order_id"));

        placeOrder.consumeBody();
    }

    @Test
    void orderStatusRouteAcceptsClientGeneratedOrderIdPathSegment() {
        BenchmarkTokenIssuer issuer = new BenchmarkTokenIssuer();
        String token = issuer.issueToken(UUID.randomUUID());
        TestSupport.CapturingAllocator allocator = new TestSupport.CapturingAllocator();
        CommunityBenchmarkRouteHandler handler = new CommunityBenchmarkRouteHandler(
            new StaticUseCaseService(),
            new SecurityInterceptor(new BenchmarkJwtSecurityProvider(
                Map.of(BenchmarkTokenIssuer.KID, issuer.publicKey()),
                BenchmarkTokenIssuer.ISSUER,
                BenchmarkTokenIssuer.AUD
            )),
            ignored -> OptionalLong.of(1L),
            allocator
        );

        String clientOrderId = "exeris-saga-v2-measurement-i0";
        TestSupport.AsyncCapturingExchange status = TestSupport.AsyncCapturingExchange.get(
            "/api/v1/orders/" + clientOrderId + "/status",
            Map.of("Authorization", "Bearer " + token),
            allocator
        );

        handler.handleOrderStatus(status);

        assertEquals(HttpStatus.OK, status.response().status());

        Map<String, Object> responseBody = parseJsonResponse(status);
        assertEquals(clientOrderId, responseBody.get("order_id"));

        status.consumeBody();
    }

    @Test
    void orderStatusByQueryRouteAcceptsSnakeCaseOrderIdParam() {
        BenchmarkTokenIssuer issuer = new BenchmarkTokenIssuer();
        String token = issuer.issueToken(UUID.randomUUID());
        TestSupport.CapturingAllocator allocator = new TestSupport.CapturingAllocator();
        CommunityBenchmarkRouteHandler handler = new CommunityBenchmarkRouteHandler(
            new StaticUseCaseService(),
            new SecurityInterceptor(new BenchmarkJwtSecurityProvider(
                Map.of(BenchmarkTokenIssuer.KID, issuer.publicKey()),
                BenchmarkTokenIssuer.ISSUER,
                BenchmarkTokenIssuer.AUD
            )),
            ignored -> OptionalLong.of(1L),
            allocator
        );

        long largeOrderId = 9_007_199_254_740_993L;
        TestSupport.AsyncCapturingExchange status = TestSupport.AsyncCapturingExchange.get(
            "/api/v1/orders/status?order_id=" + largeOrderId,
            Map.of("Authorization", "Bearer " + token),
            allocator
        );

        handler.handleOrderStatusByQuery(status);

        assertEquals(HttpStatus.OK, status.response().status());

        Map<String, Object> responseBody = parseJsonResponse(status);
        assertTrue(responseBody.get("order_id") instanceof String);
        assertEquals(Long.toString(largeOrderId), responseBody.get("order_id"));

        status.consumeBody();
    }

    @Test
    void orderStatusByQueryRouteAcceptsCamelCaseOrderIdParam() {
        BenchmarkTokenIssuer issuer = new BenchmarkTokenIssuer();
        String token = issuer.issueToken(UUID.randomUUID());
        TestSupport.CapturingAllocator allocator = new TestSupport.CapturingAllocator();
        CommunityBenchmarkRouteHandler handler = new CommunityBenchmarkRouteHandler(
            new StaticUseCaseService(),
            new SecurityInterceptor(new BenchmarkJwtSecurityProvider(
                Map.of(BenchmarkTokenIssuer.KID, issuer.publicKey()),
                BenchmarkTokenIssuer.ISSUER,
                BenchmarkTokenIssuer.AUD
            )),
            ignored -> OptionalLong.of(1L),
            allocator
        );

        TestSupport.AsyncCapturingExchange status = TestSupport.AsyncCapturingExchange.get(
            "/api/v1/orders/status?orderId=1",
            Map.of("Authorization", "Bearer " + token),
            allocator
        );

        handler.handleOrderStatusByQuery(status);

        assertEquals(HttpStatus.OK, status.response().status());
    }

    @Test
    void orderStatusRouteSerializesOrderIdAsString() {
        BenchmarkTokenIssuer issuer = new BenchmarkTokenIssuer();
        String token = issuer.issueToken(UUID.randomUUID());
        TestSupport.CapturingAllocator allocator = new TestSupport.CapturingAllocator();
        CommunityBenchmarkRouteHandler handler = new CommunityBenchmarkRouteHandler(
            new StaticUseCaseService(),
            new SecurityInterceptor(new BenchmarkJwtSecurityProvider(
                Map.of(BenchmarkTokenIssuer.KID, issuer.publicKey()),
                BenchmarkTokenIssuer.ISSUER,
                BenchmarkTokenIssuer.AUD
            )),
            ignored -> OptionalLong.of(1L),
            allocator
        );
        long largeOrderId = 9_007_199_254_740_993L;

        TestSupport.AsyncCapturingExchange status = TestSupport.AsyncCapturingExchange.get(
            "/api/v1/orders/" + largeOrderId + "/status",
            Map.of("Authorization", "Bearer " + token),
            allocator
        );

        handler.handleOrderStatus(status);

        assertEquals(HttpStatus.OK, status.response().status());

        Map<String, Object> responseBody = parseJsonResponse(status);
        assertTrue(responseBody.get("order_id") instanceof String);
        assertEquals(Long.toString(largeOrderId), responseBody.get("order_id"));

        status.consumeBody();
    }

    private static Map<String, Object> parseJsonResponse(TestSupport.AsyncCapturingExchange exchange) {
        byte[] payload = exchange.response().body()
            .segment()
            .asSlice(0L, exchange.response().body().size())
            .toArray(ValueLayout.JAVA_BYTE);
        try {
            return OBJECT_MAPPER.readValue(payload, Map.class);
        } catch (JacksonException exception) {
            throw new AssertionError("Failed to deserialize JSON response", exception);
        }
    }

    private static SecurityInterceptor testSecurityProvider() {
        BenchmarkTokenIssuer issuer = new BenchmarkTokenIssuer();
        return new SecurityInterceptor(new BenchmarkJwtSecurityProvider(
            Map.of(BenchmarkTokenIssuer.KID, issuer.publicKey()),
            BenchmarkTokenIssuer.ISSUER,
            BenchmarkTokenIssuer.AUD
        ));
    }

    private static final class StaticUseCaseService implements BenchmarkUseCaseService {

        @Override
        public boolean pingDatabase() {
            return true;
        }

        @Override
        public List<UserView> findTopUsersWithDetails(int userLimit, int friendLimit, int interestLimit) {
            return List.of();
        }

        @Override
        public UserSummary findUserById(String id) {
            return new UserSummary(id, "user-" + id);
        }

        @Override
        public List<UserSummary> findFriendsOfFriendsWithoutInterests(UUID userId, int limit) {
            return List.of(new UserSummary(UUID.randomUUID().toString(), "fof-user"));
        }

        @Override
        public TokenResponse register(String username, String email, String password) {
            return new TokenResponse("token", "1");
        }

        @Override
        public List<ProductView> getRecommendedProducts(long userId, int limit) {
            return List.of(new ProductView(1L, "Product_1", 9.99d, "Books"));
        }

        @Override
        public CartView addToCart(long userId, long productId, int quantity) {
            return new CartView(1L, List.of(), 0.0d);
        }

        @Override
        public CartView getCart(long userId) {
            return new CartView(1L, List.of(), 0.0d);
        }

        @Override
        public OrderResponse placeOrder(long userId, long cartId, String paymentMethod, String clientOrderId) {
            // Mirrors the production adoption rule: client-generated orderId verbatim,
            // decimal DB id fallback when the client supplies none.
            String orderId = (clientOrderId == null || clientOrderId.isBlank())
                ? "9007199254740993"
                : clientOrderId.trim();
            return new OrderResponse(orderId, "saga-1", "SAGA_INITIATED");
        }

        @Override
        public OrderStatusResponse getOrderStatus(String orderId) {
            return new OrderStatusResponse(orderId, "saga-1", "COMPLETED");
        }
    }

    private static final class GraphFailingUseCaseService implements BenchmarkUseCaseService {

        @Override
        public boolean pingDatabase() {
            return true;
        }

        @Override
        public List<UserView> findTopUsersWithDetails(int userLimit, int friendLimit, int interestLimit) {
            return List.of();
        }

        @Override
        public UserSummary findUserById(String id) {
            return new UserSummary(id, "user-" + id);
        }

        @Override
        public List<UserSummary> findFriendsOfFriendsWithoutInterests(UUID userId, int limit) {
            throw new GraphUnavailableException("graph unavailable", new IllegalStateException("graph down"));
        }

        @Override
        public TokenResponse register(String username, String email, String password) {
            throw new UnsupportedOperationException();
        }

        @Override
        public List<ProductView> getRecommendedProducts(long userId, int limit) {
            throw new UnsupportedOperationException();
        }

        @Override
        public CartView addToCart(long userId, long productId, int quantity) {
            throw new UnsupportedOperationException();
        }

        @Override
        public CartView getCart(long userId) {
            throw new UnsupportedOperationException();
        }

        @Override
        public OrderResponse placeOrder(long userId, long cartId, String paymentMethod, String clientOrderId) {
            throw new UnsupportedOperationException();
        }

        @Override
        public OrderStatusResponse getOrderStatus(String orderId) {
            throw new UnsupportedOperationException();
        }
    }

}
