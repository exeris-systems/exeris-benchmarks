package eu.exeris.benchmarks.targets.exeriscommunity.application;



import eu.exeris.benchmarks.targets.exeriscommunity.domain.shop.CartView;
import eu.exeris.benchmarks.targets.exeriscommunity.domain.shop.OrderResponse;
import eu.exeris.benchmarks.targets.exeriscommunity.domain.shop.OrderStatusResponse;
import eu.exeris.benchmarks.targets.exeriscommunity.domain.shop.ProductView;
import eu.exeris.benchmarks.targets.exeriscommunity.domain.shop.TokenResponse;
import eu.exeris.benchmarks.targets.exeriscommunity.domain.user.UserSummary;
import eu.exeris.benchmarks.targets.exeriscommunity.domain.user.UserView;
import java.util.List;
import java.util.UUID;

public interface BenchmarkUseCaseService {

    boolean pingDatabase();

    List<UserView> findTopUsersWithDetails(int userLimit, int friendLimit, int interestLimit);

    List<UserSummary> findFriendsOfFriendsWithoutInterests(UUID userId, int limit);

    TokenResponse register(String username, String email, String password);

    List<ProductView> getRecommendedProducts(long userId, int limit);

    CartView addToCart(long userId, long productId, int quantity);

    CartView getCart(long userId);

    OrderResponse placeOrder(long userId, long cartId, String paymentMethod);

    OrderStatusResponse getOrderStatus(long orderId);
}
