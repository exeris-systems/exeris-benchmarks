package eu.exeris.benchmarks.targets.exeriscommunity.application;

import eu.exeris.benchmarks.targets.exeriscommunity.domain.shop.CartView;
import eu.exeris.benchmarks.targets.exeriscommunity.domain.shop.OrderResponse;
import eu.exeris.benchmarks.targets.exeriscommunity.domain.shop.OrderStatusResponse;
import eu.exeris.benchmarks.targets.exeriscommunity.domain.shop.ProductView;
import eu.exeris.benchmarks.targets.exeriscommunity.domain.shop.TokenResponse;
import eu.exeris.benchmarks.targets.exeriscommunity.domain.user.UserSummary;
import eu.exeris.benchmarks.targets.exeriscommunity.domain.user.UserView;
import eu.exeris.benchmarks.targets.exeriscommunity.infrastructure.graph.GraphFriendsOfFriendsAdapter;
import eu.exeris.benchmarks.targets.exeriscommunity.infrastructure.graph.GraphShopAdapter;
import eu.exeris.benchmarks.targets.exeriscommunity.infrastructure.persistence.CartRepository;
import eu.exeris.benchmarks.targets.exeriscommunity.infrastructure.persistence.OrderRepository;
import eu.exeris.benchmarks.targets.exeriscommunity.infrastructure.persistence.PrincipalRepository;
import eu.exeris.benchmarks.targets.exeriscommunity.infrastructure.persistence.ProductRepository;
import eu.exeris.benchmarks.targets.exeriscommunity.infrastructure.persistence.UserRepository;
import eu.exeris.benchmarks.targets.exeriscommunity.saga.OrderSagaOrchestrator;
import eu.exeris.benchmarks.targets.exeriscommunity.security.BenchmarkTokenIssuer;
import java.math.BigDecimal;
import java.util.List;
import java.util.OptionalLong;
import java.util.UUID;
import java.util.concurrent.ConcurrentHashMap;

public final class RepositoryBackedBenchmarkUseCaseService implements BenchmarkUseCaseService {

    private final UserRepository userRepository;
    private final GraphFriendsOfFriendsAdapter graphFriendsOfFriendsAdapter;
    private final GraphShopAdapter graphShopAdapter;
    private final ProductRepository productRepository;
    private final CartRepository cartRepository;
    private final OrderRepository orderRepository;
    private final PrincipalRepository principalRepository;
    private final OrderSagaOrchestrator orderSagaOrchestrator;
    private final BenchmarkTokenIssuer tokenIssuer;

    /**
     * API-level orderId → DB (BIGSERIAL) order id. The CONTRACT-v2 section 3
     * client-generated orderId is adopted verbatim as the public order identity;
     * domain rows stay keyed on the DB id. In-process map — parity with the
     * sibling stacks' in-memory projections; cross-restart status lookup by the
     * client orderId is equally out of scope there.
     */
    private final ConcurrentHashMap<String, Long> dbOrderIdByApiOrderId = new ConcurrentHashMap<>();

    public RepositoryBackedBenchmarkUseCaseService(UserRepository userRepository,
                                                   GraphFriendsOfFriendsAdapter graphFriendsOfFriendsAdapter,
                                                   GraphShopAdapter graphShopAdapter,
                                                   ProductRepository productRepository,
                                                   CartRepository cartRepository,
                                                   OrderRepository orderRepository,
                                                   PrincipalRepository principalRepository,
                                                   OrderSagaOrchestrator orderSagaOrchestrator,
                                                   BenchmarkTokenIssuer tokenIssuer) {
        this.userRepository = userRepository;
        this.graphFriendsOfFriendsAdapter = graphFriendsOfFriendsAdapter;
        this.graphShopAdapter = graphShopAdapter;
        this.productRepository = productRepository;
        this.cartRepository = cartRepository;
        this.orderRepository = orderRepository;
        this.principalRepository = principalRepository;
        this.orderSagaOrchestrator = orderSagaOrchestrator;
        this.tokenIssuer = tokenIssuer;
    }

    @Override
    public boolean pingDatabase() {
        return userRepository.ping();
    }

    @Override
    public List<UserView> findTopUsersWithDetails(int userLimit, int friendLimit, int interestLimit) {
        return userRepository.findTopUsersWithDetails(userLimit, friendLimit, interestLimit);
    }

    @Override
    public UserSummary findUserById(String id) {
        return userRepository.findById(id).orElse(null);
    }

    @Override
    public List<UserSummary> findFriendsOfFriendsWithoutInterests(UUID userId, int limit) {
        List<UUID> orderedIds = graphFriendsOfFriendsAdapter.findSecondDegreeNeighborIds(userId, limit);
        return userRepository.findUsersWithoutInterestsByOrderedIds(orderedIds, limit);
    }

    @Override
    public TokenResponse register(String username, String email, String password) {
        if (isBlank(username) || isBlank(email) || isBlank(password)) {
            throw new IllegalArgumentException("Invalid register payload");
        }
        UUID principalId = UUID.randomUUID();
        OptionalLong userId = principalRepository.createUserAndBindPrincipal(
            username.trim(),
            email.trim(),
            password,
            principalId
        );
        if (userId.isEmpty()) {
            throw new IllegalStateException("User already exists");
        }
        String token = tokenIssuer.issueToken(principalId);
        return new TokenResponse(token, Long.toString(userId.getAsLong()));
    }

    @Override
    public List<ProductView> getRecommendedProducts(long userId, int limit) {
        int boundedLimit = Math.max(1, limit);
        try {
            List<UUID> graphNodeIds = graphShopAdapter.recommendProductNodeIdsFromGraph(userId, boundedLimit);
            List<Long> ids = productRepository.resolveProductIdsFromGraphNodeIds(graphNodeIds, boundedLimit);
            if (!ids.isEmpty()) {
                return productRepository.findByIdsPreserveOrder(ids, boundedLimit);
            }
        } catch (RuntimeException ignored) {
        }
        return productRepository.findRecommendedForUser(userId, boundedLimit);
    }

    @Override
    public CartView addToCart(long userId, long productId, int quantity) {
        if (quantity <= 0) {
            throw new IllegalArgumentException("quantity must be > 0");
        }
        BigDecimal price = cartRepository.getProductPrice(productId);
        if (price.signum() <= 0) {
            throw new IllegalArgumentException("product not found");
        }
        long cartId = cartRepository.getOrCreateCart(userId);
        cartRepository.addOrUpdateItem(cartId, productId, quantity, price);
        try {
            graphShopAdapter.upsertCartEdge(userId, productId, quantity);
        } catch (RuntimeException ignored) {
        }
        return cartRepository.getCart(userId);
    }

    @Override
    public CartView getCart(long userId) {
        try {
            graphShopAdapter.readCartProductNodeIds(userId);
        } catch (RuntimeException ignored) {
        }
        return cartRepository.getCart(userId);
    }

    @Override
    public OrderResponse placeOrder(long userId, long cartId, String paymentMethod, String clientOrderId) {
        requireSaga();
        CartView cart = cartRepository.getCart(userId);
        if (cart.items().isEmpty()) {
            throw new IllegalStateException("cart is empty");
        }
        if (cart.cartId() != cartId) {
            throw new IllegalArgumentException("cart not found");
        }

        long dbOrderId = orderRepository.createOrderWithItems(userId, cart.items());
        // CONTRACT-v2 section 3: adopt the client-generated deterministic orderId
        // verbatim as the API-level orderId — it is the input to the section 4.1
        // payment-decline rule, so minting a server-side id here would break the
        // "identical declined subset in every stack and every run" invariant.
        // Blank/absent (pre-v2 clients) falls back to the decimal DB id.
        String orderId = (clientOrderId == null || clientOrderId.isBlank())
            ? Long.toString(dbOrderId)
            : clientOrderId.trim();
        dbOrderIdByApiOrderId.putIfAbsent(orderId, dbOrderId);
        String sagaId = orderSagaOrchestrator.scheduleSaga(dbOrderId, orderId, userId, paymentMethod);
        return new OrderResponse(orderId, sagaId, "SAGA_INITIATED");
    }

    @Override
    public OrderStatusResponse getOrderStatus(String orderId) {
        requireSaga();
        Long dbOrderId = resolveDbOrderId(orderId);
        if (dbOrderId == null) {
            throw new IllegalArgumentException("order not found");
        }
        String dbStatus = orderRepository.getOrderStatus(dbOrderId);
        if (dbStatus == null) {
            throw new IllegalArgumentException("order not found");
        }

        String sagaId = orderRepository.getSagaId(dbOrderId);
        String resolvedSagaId = (sagaId == null || sagaId.isBlank()) ? "PENDING" : sagaId;

        String status = orderSagaOrchestrator.getSagaStatus(dbOrderId);
        String resolvedStatus = isSagaTerminal(status) ? status : mapFallbackSagaStatus(dbStatus);

        return new OrderStatusResponse(orderId, resolvedSagaId, resolvedStatus);
    }

    private Long resolveDbOrderId(String orderId) {
        Long mapped = dbOrderIdByApiOrderId.get(orderId);
        if (mapped != null) {
            return mapped;
        }
        try {
            // Pre-v2 clients poll by the decimal DB id directly.
            return Long.parseLong(orderId);
        } catch (NumberFormatException exception) {
            return null;
        }
    }

    private static String mapFallbackSagaStatus(String dbStatus) {
        return switch (dbStatus) {
            case "COMPLETED", "CONFIRMED" -> "COMPLETED";
            case "CANCELLED", "PAYMENT_REFUNDED" -> "COMPENSATED";
            case "FAILED" -> "FAILED";
            default -> dbStatus;
        };
    }

    private static boolean isSagaTerminal(String status) {
        return "COMPLETED".equals(status) || "COMPENSATED".equals(status) || "FAILED".equals(status);
    }

    private static boolean isBlank(String value) {
        return value == null || value.isBlank();
    }

    private void requireSaga() {
        if (orderSagaOrchestrator == null) {
            throw new IllegalStateException(
                "order saga subsystem not enabled; export EXERIS_SUBSYSTEMS including 'flow' (and 'events') to run the shop-order-saga scenario");
        }
    }
}
