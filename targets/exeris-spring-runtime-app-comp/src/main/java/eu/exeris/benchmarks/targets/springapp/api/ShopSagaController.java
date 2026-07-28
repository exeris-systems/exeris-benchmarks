package eu.exeris.benchmarks.targets.springapp.api;

import eu.exeris.benchmarks.targets.springapp.application.AuthTokenService;
import eu.exeris.benchmarks.targets.springapp.application.ProductCatalogService;
import eu.exeris.benchmarks.targets.springapp.application.ShopSagaStateService;
import eu.exeris.benchmarks.targets.springapp.application.flow.ShopOrderFlowService;

import org.springframework.context.annotation.Lazy;
import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.security.core.Authentication;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

import java.util.List;
import java.util.Optional;

@RestController
public class ShopSagaController {

    private final AuthTokenService authTokenService;
    private final ProductCatalogService productCatalogService;
    private final ShopSagaStateService shopSagaStateService;
    private final ShopOrderFlowService shopOrderFlowService;

    /**
     * {@code @Lazy} on {@link ShopOrderFlowService} breaks an architectural
     * cycle in the host-runtime's compat autoconfig: ExerisHandlerMethodRegistry
     * (scans @RestController beans) → this controller → ShopOrderFlowService →
     * ExerisFlowTemplate → ExerisFlowEngineSupplier → ExerisRuntimeLifecycle →
     * ExerisCompatDispatcher → ExerisSpringMvcBridge → ExerisHandlerMethodRegistry.
     * The break point is here because ShopOrderFlowService is not final, so
     * Spring can CGLIB-subclass it for a lazy proxy. ExerisFlowTemplate IS
     * final, so {@code @Lazy} on that class directly would fail. Worth
     * filing an upstream issue against exeris-spring-runtime.
     */
    public ShopSagaController(
            AuthTokenService authTokenService,
            ProductCatalogService productCatalogService,
            ShopSagaStateService shopSagaStateService,
            @Lazy ShopOrderFlowService shopOrderFlowService
    ) {
        this.authTokenService = authTokenService;
        this.productCatalogService = productCatalogService;
        this.shopSagaStateService = shopSagaStateService;
        this.shopOrderFlowService = shopOrderFlowService;
    }

    @PostMapping(value = "/api/v1/auth/register", produces = "application/json", consumes = "application/json")
    public ResponseEntity<Object> register(@RequestBody(required = false) RegisterRequest request) {
        if (request == null || isBlank(request.username()) || isBlank(request.email()) || isBlank(request.password())) {
            return ResponseEntity.badRequest().body(new ErrorResponse("invalid_register_request"));
        }
        Optional<AuthTokenService.RegisteredUser> registered = authTokenService.register(request);
        if (registered.isEmpty()) {
            return ResponseEntity.status(HttpStatus.CONFLICT).body(new ErrorResponse("user_exists"));
        }
        AuthTokenService.RegisteredUser user = registered.get();
        return ResponseEntity.status(HttpStatus.CREATED).body(new RegisterResponse(user.token(), user.userId()));
    }

    @GetMapping(value = "/api/v1/products/recommended", produces = "application/json")
    public ResponseEntity<Object> recommendedProducts(
            Authentication authentication,
            @RequestParam(value = "limit", required = false) Integer limit
    ) {
        long uid = Long.parseLong(authentication.getName());
        List<ProductView> products = productCatalogService.recommendedProducts(uid, normalizeLimit(limit));
        return ResponseEntity.ok(products);
    }

    @PostMapping(value = "/api/v1/cart/add", produces = "application/json", consumes = "application/json")
    public ResponseEntity<Object> addToCart(
            Authentication authentication,
            @RequestBody(required = false) CartAddRequest request
    ) {
        if (request == null || isBlank(request.productId()) || request.quantity() <= 0) {
            return ResponseEntity.badRequest().body(new ErrorResponse("invalid_cart_request"));
        }
        CartView cart = shopSagaStateService.addToCart(
                authentication.getName(), request.productId(), request.quantity(), productCatalogService);
        return ResponseEntity.status(HttpStatus.CREATED).body(cart);
    }

    @GetMapping(value = "/api/v1/cart", produces = "application/json")
    public ResponseEntity<Object> getCart(Authentication authentication) {
        CartView cart = shopSagaStateService.getOrCreateCart(authentication.getName(), productCatalogService);
        return ResponseEntity.ok(cart);
    }

    @PostMapping(value = "/api/v1/orders", produces = "application/json", consumes = "application/json")
    public ResponseEntity<Object> createOrder(
            Authentication authentication,
            @RequestBody(required = false) CreateOrderRequest request
    ) {
        if (request == null || isBlank(request.cartId()) || isBlank(request.paymentMethod())) {
            return ResponseEntity.badRequest().body(new ErrorResponse("invalid_order_request"));
        }
        Optional<OrderAcceptedView> accepted = shopOrderFlowService.createOrder(
                authentication.getName(),
                request.orderId(),
                request.cartId(),
                request.paymentMethod(),
                shopSagaStateService
        );
        if (accepted.isEmpty()) {
            return ResponseEntity.status(HttpStatus.NOT_FOUND).body(new ErrorResponse("cart_not_found"));
        }
        return ResponseEntity.status(HttpStatus.ACCEPTED).body(accepted.get());
    }

    @GetMapping(value = "/api/v1/orders/{orderId}/status", produces = "application/json")
    public ResponseEntity<Object> orderStatus(
            Authentication authentication,
            @PathVariable("orderId") String orderId
    ) {
        Optional<OrderStatusView> status = shopOrderFlowService.orderStatus(authentication.getName(), orderId);
        if (status.isEmpty()) {
            return ResponseEntity.status(HttpStatus.NOT_FOUND).body(new ErrorResponse("order_not_found"));
        }
        return ResponseEntity.ok(status.get());
    }

    private static boolean isBlank(String value) {
        return value == null || value.trim().isEmpty();
    }

    private static int normalizeLimit(Integer limit) {
        if (limit == null || limit <= 0) {
            return 10;
        }
        return Math.min(limit, 50);
    }
}