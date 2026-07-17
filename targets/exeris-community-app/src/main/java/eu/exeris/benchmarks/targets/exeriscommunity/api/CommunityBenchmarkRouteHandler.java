package eu.exeris.benchmarks.targets.exeriscommunity.api;

import java.lang.foreign.MemorySegment;
import java.lang.foreign.ValueLayout;
import java.net.URLDecoder;
import java.nio.charset.StandardCharsets;
import java.util.List;
import java.util.Map;
import java.util.OptionalLong;
import java.util.UUID;
import java.util.function.Function;
import java.util.function.LongConsumer;

import eu.exeris.benchmarks.targets.exeriscommunity.application.BenchmarkUseCaseService;
import eu.exeris.benchmarks.targets.exeriscommunity.domain.shop.AddToCartRequest;
import eu.exeris.benchmarks.targets.exeriscommunity.domain.shop.CartItemView;
import eu.exeris.benchmarks.targets.exeriscommunity.domain.shop.CartView;
import eu.exeris.benchmarks.targets.exeriscommunity.domain.shop.OrderResponse;
import eu.exeris.benchmarks.targets.exeriscommunity.domain.shop.OrderStatusResponse;
import eu.exeris.benchmarks.targets.exeriscommunity.domain.shop.PlaceOrderRequest;
import eu.exeris.benchmarks.targets.exeriscommunity.domain.shop.ProductView;
import eu.exeris.benchmarks.targets.exeriscommunity.domain.shop.RegisterRequest;
import eu.exeris.benchmarks.targets.exeriscommunity.domain.shop.TokenResponse;
import eu.exeris.benchmarks.targets.exeriscommunity.domain.user.UserSummary;
import eu.exeris.benchmarks.targets.exeriscommunity.domain.user.UserView;
import eu.exeris.benchmarks.targets.exeriscommunity.infrastructure.graph.GraphUnavailableException;
import eu.exeris.kernel.core.security.SecurityInterceptor;
import eu.exeris.kernel.spi.context.KernelProviders;
import eu.exeris.kernel.spi.http.HttpExchange;
import eu.exeris.kernel.spi.http.HttpHeader;
import eu.exeris.kernel.spi.http.HttpResponse;
import eu.exeris.kernel.spi.http.HttpStatus;
import eu.exeris.kernel.spi.memory.LoanedBuffer;
import eu.exeris.kernel.spi.memory.MemoryAllocator;
import eu.exeris.kernel.spi.security.ImmutableStorageContext;
import eu.exeris.kernel.spi.security.StorageContext;
import tools.jackson.core.JacksonException;
import tools.jackson.databind.ObjectMapper;

public final class CommunityBenchmarkRouteHandler {

    private static final ObjectMapper OBJECT_MAPPER = new ObjectMapper();
    private static final int USERS_LIMIT = 10;
    private static final int FRIENDS_LIMIT = 10;
    private static final int INTERESTS_LIMIT = 10;
    private static final int DEFAULT_FOF_LIMIT = 50;
    private static final int DEFAULT_RECOMMENDATION_LIMIT = 10;
    private static final byte[] PLAINTEXT_BODY = "plaintext".getBytes(StandardCharsets.US_ASCII);
    private static final List<HttpHeader> PLAINTEXT_HEADERS = List.of(new HttpHeader("content-type", "text/plain; charset=utf-8"));

    private final BenchmarkUseCaseService useCaseService;
    private final SecurityInterceptor interceptor;
    private final Function<UUID, OptionalLong> principalUserResolver;
    private final MemoryAllocator allocator;
    private record OrderBody(String order_id, String saga_id, String status) {}
    private record OrderStatusBody(String order_id, String saga_id, String status) {}

    public CommunityBenchmarkRouteHandler(BenchmarkUseCaseService useCaseService,
                                          SecurityInterceptor interceptor,
                                          Function<UUID, OptionalLong> principalUserResolver,
                                          MemoryAllocator allocator) {
        this.useCaseService = useCaseService;
        this.interceptor = interceptor;
        this.principalUserResolver = principalUserResolver;
        this.allocator = allocator;
    }

    public void handleHealth(HttpExchange exchange) {
        exchange.respond(HttpStatus.OK);
    }

    public void handlePlaintext(HttpExchange exchange) {
        LoanedBuffer responseBody = allocator.allocateNetwork(PLAINTEXT_BODY.length);
        try {
            MemorySegment.copy(MemorySegment.ofArray(PLAINTEXT_BODY), 0L, responseBody.segment(), 0L, PLAINTEXT_BODY.length);
            responseBody.setSize(PLAINTEXT_BODY.length);
            exchange.respond(new HttpResponse(
                HttpStatus.OK,
                exchange.request().version(),
                PLAINTEXT_HEADERS,
                responseBody
            ));
        } catch (RuntimeException exception) {
            responseBody.close();
            throw exception;
        }
    }

    public void handleDbPing(HttpExchange exchange) {
        if (useCaseService.pingDatabase()) {
            exchange.respond(HttpStatus.OK);
        } else {
            exchange.respond(HttpStatus.SERVICE_UNAVAILABLE);
        }
    }

    public void handleUsers(HttpExchange exchange) {
        try {
            List<UserView> users = useCaseService.findTopUsersWithDetails(USERS_LIMIT, FRIENDS_LIMIT, INTERESTS_LIMIT);
            exchange.respond(HttpStatus.OK, users);
        } catch (RuntimeException exception) {
            // Map backend/pool failures (e.g. PersistenceProviderException on
            // cold-start pool exhaustion) to 503, consistent with the sibling
            // handlers. Without this the exception escapes uncaught to the
            // PaqsScheduler virtual-thread root and the JVM default handler
            // prints a full stack on every failure (the log "storm").
            exchange.respond(HttpStatus.SERVICE_UNAVAILABLE);
        }
    }

    public void handleFriendsOfFriendsWithoutInterests(HttpExchange exchange) {
        Map<String, String> queryParams = parseQueryParams(exchange.request().path());
        UUID userId = parseRequiredUuid(queryParams.get("userId"));
        Integer limit = parseOptionalLimit(queryParams.get("limit"), DEFAULT_FOF_LIMIT);
        if (userId == null || limit == null) {
            exchange.respond(HttpStatus.BAD_REQUEST);
            return;
        }

        try {
            List<UserSummary> users = useCaseService.findFriendsOfFriendsWithoutInterests(userId, limit);
            exchange.respond(HttpStatus.OK, users);
        } catch (GraphUnavailableException graphUnavailableException) {
            exchange.respond(HttpStatus.SERVICE_UNAVAILABLE);
        }
    }

    public void handleRegister(HttpExchange exchange) {
        RegisterRequest request;
        try {
            request = parseBody(exchange, RegisterRequest.class);
        } catch (IllegalArgumentException exception) {
            exchange.respond(HttpStatus.BAD_REQUEST);
            return;
        }

        try {
            TokenResponse response = useCaseService.register(request.username(), request.email(), request.password());
            exchange.respond(HttpStatus.CREATED, Map.of(
                "token", response.token(),
                "user_id", Long.parseLong(response.userId())
            ));
        } catch (IllegalArgumentException exception) {
            exchange.respond(HttpStatus.BAD_REQUEST);
        } catch (IllegalStateException exception) {
            exchange.respond(HttpStatus.CONFLICT);
        } catch (RuntimeException exception) {
            exchange.respond(HttpStatus.SERVICE_UNAVAILABLE);
        }
    }

    public void handleRecommendedProducts(HttpExchange exchange) {
        Map<String, String> queryParams = parseQueryParams(exchange.request().path());
        Integer limit = parseOptionalLimit(queryParams.get("limit"), DEFAULT_RECOMMENDATION_LIMIT);
        if (limit == null) {
            exchange.respond(HttpStatus.BAD_REQUEST);
            return;
        }

        withAuthenticatedUser(exchange, userId -> {
            try {
                List<ProductView> products = useCaseService.getRecommendedProducts(userId, limit);
                exchange.respond(HttpStatus.OK, products);
            } catch (RuntimeException exception) {
                System.err.println("[benchmark] handleRecommendedProducts failed: " + exception);
                exchange.respond(HttpStatus.SERVICE_UNAVAILABLE);
            }
        });
    }

    public void handleAddToCart(HttpExchange exchange) {
        AddToCartRequest request;
        try {
            request = parseBody(exchange, AddToCartRequest.class);
        } catch (IllegalArgumentException exception) {
            exchange.respond(HttpStatus.BAD_REQUEST);
            return;
        }

        withAuthenticatedUser(exchange, userId -> {
            try {
                CartView cart = useCaseService.addToCart(userId, request.productId(), request.quantity());
                exchange.respond(HttpStatus.OK, toCartResponse(cart));
            } catch (IllegalArgumentException exception) {
                exchange.respond(HttpStatus.NOT_FOUND);
            }
        });
    }

    public void handleGetCart(HttpExchange exchange) {
        withAuthenticatedUser(exchange, userId -> {
            CartView cart = useCaseService.getCart(userId);
            exchange.respond(HttpStatus.OK, toCartResponse(cart));
        });
    }

    public void handlePlaceOrder(HttpExchange exchange) {
        PlaceOrderRequest request;
        try {
            request = parseBody(exchange, PlaceOrderRequest.class);
        } catch (IllegalArgumentException exception) {
            exchange.respond(HttpStatus.BAD_REQUEST);
            return;
        }

        withAuthenticatedUser(exchange, userId -> {
            try {
                OrderResponse response = useCaseService.placeOrder(
                    userId, request.cartId(), request.paymentMethod(), request.orderId());
                exchange.respond(HttpStatus.ACCEPTED,
                    new OrderBody(response.orderId(), response.sagaId(), response.status()));
            } catch (IllegalArgumentException exception) {
                exchange.respond(HttpStatus.NOT_FOUND);
            } catch (IllegalStateException exception) {
                exchange.respond(HttpStatus.CONFLICT);
            }
        });
    }

    public void handleOrderStatus(HttpExchange exchange) {
        String orderId = parseOrderIdFromPath(exchange.request().path());
        if (orderId == null) {
            exchange.respond(HttpStatus.BAD_REQUEST);
            return;
        }

        withAuthenticatedUser(exchange, userId -> {
            try {
                OrderStatusResponse response = useCaseService.getOrderStatus(orderId);
                exchange.respond(HttpStatus.OK,
                    new OrderStatusBody(response.orderId(), response.sagaId(), response.status()));
            } catch (IllegalArgumentException exception) {
                exchange.respond(HttpStatus.NOT_FOUND);
            }
        });
    }

    public void handleOrderStatusByQuery(HttpExchange exchange) {
        Map<String, String> queryParams = parseQueryParams(exchange.request().path());
        String rawOrderId = queryParams.get("order_id");
        if (rawOrderId == null) {
            rawOrderId = queryParams.get("orderId");
        }

        if (rawOrderId == null || rawOrderId.isBlank()) {
            exchange.respond(HttpStatus.BAD_REQUEST);
            return;
        }
        String orderId = rawOrderId.trim();

        withAuthenticatedUser(exchange, userId -> {
            try {
                OrderStatusResponse response = useCaseService.getOrderStatus(orderId);
                exchange.respond(HttpStatus.OK,
                    new OrderStatusBody(response.orderId(), response.sagaId(), response.status()));
            } catch (IllegalArgumentException exception) {
                exchange.respond(HttpStatus.NOT_FOUND);
            }
        });
    }

    public static void respondNoBody(HttpExchange exchange, HttpStatus status) {
        exchange.respond(HttpResponse.noBody(status, exchange.request().version()));
    }

    private static UUID parseRequiredUuid(String rawUserId) {
        if (rawUserId == null || rawUserId.isBlank()) {
            return null;
        }
        try {
            return UUID.fromString(rawUserId.trim());
        } catch (IllegalArgumentException exception) {
            return null;
        }
    }

        private static Integer parseOptionalLimit(String rawLimit, int defaultValue) {
        if (rawLimit == null || rawLimit.isBlank()) {
            return defaultValue;
        }
        try {
            int parsed = Integer.parseInt(rawLimit.trim());
            return parsed > 0 ? parsed : null;
        } catch (NumberFormatException exception) {
            return null;
        }
    }

    private static Map<String, String> parseQueryParams(String path) {
        int queryIndex = path.indexOf('?');
        if (queryIndex < 0 || queryIndex >= path.length() - 1) {
            return Map.of();
        }

        String query = path.substring(queryIndex + 1);
        Map<String, String> params = new java.util.HashMap<>();
        String[] pairs = query.split("&");
        for (String pair : pairs) {
            if (pair.isBlank()) {
                continue;
            }
            int equalsIndex = pair.indexOf('=');
            if (equalsIndex <= 0 || equalsIndex == pair.length() - 1) {
                continue;
            }
            String key = decodeQueryPart(pair.substring(0, equalsIndex));
            String value = decodeQueryPart(pair.substring(equalsIndex + 1));
            params.putIfAbsent(key, value);
        }
        return params;
    }

    private static String decodeQueryPart(String value) {
        return URLDecoder.decode(value, StandardCharsets.UTF_8);
    }

    private <T> T parseBody(HttpExchange exchange, Class<T> type) {
        if (!exchange.request().hasBody()) {
            throw new IllegalArgumentException("Missing body");
        }
        MemorySegment seg = exchange.request().body()
            .segment()
            .asSlice(0L, exchange.request().body().size());
        try {
            return OBJECT_MAPPER.readValue(new SegmentInputStream(seg), type);
        } catch (JacksonException exception) {
            throw new IllegalArgumentException("Invalid JSON", exception);
        }
    }

    private void withAuthenticatedUser(HttpExchange exchange, LongConsumer handler) {
        String bearerToken = extractBearerToken(exchange);
        if (bearerToken == null) {
            exchange.respond(HttpStatus.UNAUTHORIZED);
            return;
        }

        int len = bearerToken.length(); // JWT is ASCII — char length == byte length
        try (LoanedBuffer buf = allocator.allocateNetwork(len)) {
            MemorySegment seg = buf.segment();
            for (int i = 0; i < len; i++) {
                seg.setAtIndex(ValueLayout.JAVA_BYTE, i, (byte) bearerToken.charAt(i));
            }
            buf.setSize(len);
            boolean authenticated = interceptor.intercept(buf, () -> {
                UUID principalId = KernelProviders.PRINCIPAL_CONTEXT.get().principalId();
                OptionalLong resolved = principalUserResolver.apply(principalId);
                if (resolved.isEmpty()) {
                    exchange.respond(HttpStatus.UNAUTHORIZED);
                } else {
                    long userId = resolved.getAsLong();
                    StorageContext ctx = KernelProviders.STORAGE_CONTEXT.get();
                    // benchmark-local: align RLS key with authenticated user id for SHARED strategy
                    if (ctx.strategy() == StorageContext.IsolationStrategy.SHARED) {
                        ScopedValue.where(KernelProviders.STORAGE_CONTEXT,
                            ImmutableStorageContext.shared(Long.toString(userId)))
                            .run(() -> handler.accept(userId));
                    } else {
                        handler.accept(userId);
                    }
                }
            });
            if (!authenticated) {
                exchange.respond(HttpStatus.UNAUTHORIZED);
            }
        } catch (RuntimeException exception) {
            exchange.respond(HttpStatus.SERVICE_UNAVAILABLE);
        }
    }

    private static String extractBearerToken(HttpExchange exchange) {
        String header = exchange.request().firstHeader("Authorization").orElse(null);
        if (header == null || !header.startsWith("Bearer ")) {
            return null;
        }
        String token = header.substring("Bearer ".length()).trim();
        return token.isBlank() ? null : token;
    }

    /**
     * Extracts the API-level orderId path segment. Kept as an opaque string: the
     * CONTRACT-v2 section 3 client-generated orderId (e.g. {@code seed-scenario-i0})
     * is the public order identity; decimal DB ids (pre-v2 clients) parse the same way.
     */
    private static String parseOrderIdFromPath(String path) {
        if (path == null || path.isBlank()) {
            return null;
        }
        String pathWithoutQuery = path.split("\\?", 2)[0];
        if (!pathWithoutQuery.startsWith("/api/v1/orders/") || !pathWithoutQuery.endsWith("/status")) {
            return null;
        }
        String value = pathWithoutQuery.substring("/api/v1/orders/".length(), pathWithoutQuery.length() - "/status".length());
        if (value.isBlank() || value.indexOf('/') >= 0) {
            return null;
        }
        return value;
    }

    private static Map<String, Object> toCartResponse(CartView cart) {
        List<Map<String, Object>> items = cart.items().stream()
            .map(CommunityBenchmarkRouteHandler::toCartItemResponse)
            .toList();
        return Map.of(
            "cart_id", cart.cartId(),
            "items", items,
            "total", cart.total()
        );
    }

    private static Map<String, Object> toCartItemResponse(CartItemView item) {
        return Map.of(
            "product_id", item.productId(),
            "product_name", item.productName(),
            "quantity", item.quantity(),
            "price", item.price()
        );
    }

    private static final class SegmentInputStream extends java.io.InputStream {
        private final MemorySegment seg;
        private long pos;

        SegmentInputStream(MemorySegment seg) {
            this.seg = seg;
        }

        @Override
        public int read() {
            if (pos >= seg.byteSize()) return -1;
            return Byte.toUnsignedInt(seg.getAtIndex(ValueLayout.JAVA_BYTE, pos++));
        }

        @Override
        public int read(byte[] b, int off, int len) {
            long remaining = seg.byteSize() - pos;
            if (remaining <= 0) return -1;
            int n = (int) Math.min(len, remaining);
            MemorySegment.copy(seg, ValueLayout.JAVA_BYTE, pos, b, off, n);
            pos += n;
            return n;
        }
    }
}
