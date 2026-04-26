package eu.exeris.benchmarks.targets.quarkusapp.controller;

import eu.exeris.benchmarks.targets.quarkusapp.axon.AxonOrderSagaService;
import eu.exeris.benchmarks.targets.quarkusapp.dto.CartAddRequest;
import eu.exeris.benchmarks.targets.quarkusapp.dto.CartView;
import eu.exeris.benchmarks.targets.quarkusapp.dto.CreateOrderRequest;
import eu.exeris.benchmarks.targets.quarkusapp.dto.ErrorResponse;
import eu.exeris.benchmarks.targets.quarkusapp.dto.OrderAcceptedView;
import eu.exeris.benchmarks.targets.quarkusapp.dto.OrderStatusView;
import eu.exeris.benchmarks.targets.quarkusapp.dto.ProductView;
import eu.exeris.benchmarks.targets.quarkusapp.dto.RegisterRequest;
import eu.exeris.benchmarks.targets.quarkusapp.dto.RegisterResponse;
import eu.exeris.benchmarks.targets.quarkusapp.service.AuthTokenService;
import eu.exeris.benchmarks.targets.quarkusapp.service.ProductCatalogService;
import eu.exeris.benchmarks.targets.quarkusapp.service.ShopSagaStateService;

import io.smallrye.common.annotation.RunOnVirtualThread;
import jakarta.inject.Inject;
import jakarta.ws.rs.Consumes;
import jakarta.ws.rs.GET;
import jakarta.ws.rs.HeaderParam;
import jakarta.ws.rs.POST;
import jakarta.ws.rs.Path;
import jakarta.ws.rs.PathParam;
import jakarta.ws.rs.Produces;
import jakarta.ws.rs.QueryParam;
import jakarta.ws.rs.core.MediaType;
import jakarta.ws.rs.core.Response;

import java.util.List;
import java.util.Optional;

@Path("/api/v1")
@Produces(MediaType.APPLICATION_JSON)
@Consumes(MediaType.APPLICATION_JSON)
@RunOnVirtualThread
public class ShopSagaResource {

    @Inject
    AuthTokenService authTokenService;

    @Inject
    ProductCatalogService productCatalogService;

    @Inject
    ShopSagaStateService shopSagaStateService;

    @Inject
    AxonOrderSagaService axonOrderSagaService;

    @POST
    @Path("/auth/register")
    public Response register(RegisterRequest request) {
        if (request == null || isBlank(request.username()) || isBlank(request.email()) || isBlank(request.password())) {
            return Response.status(Response.Status.BAD_REQUEST).entity(new ErrorResponse("invalid_register_request")).build();
        }
        Optional<AuthTokenService.RegisteredUser> registered = authTokenService.register(request);
        if (registered.isEmpty()) {
            return Response.status(Response.Status.CONFLICT).entity(new ErrorResponse("user_exists")).build();
        }
        AuthTokenService.RegisteredUser user = registered.get();
        return Response.status(Response.Status.CREATED)
                .entity(new RegisterResponse(user.token(), user.userId()))
                .build();
    }

    @GET
    @Path("/products/recommended")
    public Response recommendedProducts(@HeaderParam("Authorization") String authorization,
                                        @QueryParam("limit") Integer limit) {
        Optional<String> userId = authTokenService.authenticate(authorization);
        if (userId.isEmpty()) {
            return unauthorized();
        }
        int normalizedLimit = normalizeLimit(limit);
        long uid = Long.parseLong(userId.get());
        List<ProductView> products = productCatalogService.recommendedProducts(uid, normalizedLimit);
        return Response.ok(products).build();
    }

    @POST
    @Path("/cart/add")
    public Response addToCart(@HeaderParam("Authorization") String authorization, CartAddRequest request) {
        Optional<String> userId = authTokenService.authenticate(authorization);
        if (userId.isEmpty()) {
            return unauthorized();
        }
        if (request == null || isBlank(request.productId()) || request.quantity() <= 0) {
            return Response.status(Response.Status.BAD_REQUEST).entity(new ErrorResponse("invalid_cart_request")).build();
        }
        CartView cart = shopSagaStateService.addToCart(userId.get(), request.productId(), request.quantity(), productCatalogService);
        return Response.status(Response.Status.CREATED).entity(cart).build();
    }

    @GET
    @Path("/cart")
    public Response getCart(@HeaderParam("Authorization") String authorization) {
        Optional<String> userId = authTokenService.authenticate(authorization);
        if (userId.isEmpty()) {
            return unauthorized();
        }
        CartView cart = shopSagaStateService.getOrCreateCart(userId.get(), productCatalogService);
        return Response.ok(cart).build();
    }

    @POST
    @Path("/orders")
    public Response createOrder(@HeaderParam("Authorization") String authorization, CreateOrderRequest request) {
        Optional<String> userId = authTokenService.authenticate(authorization);
        if (userId.isEmpty()) {
            return unauthorized();
        }
        if (request == null || isBlank(request.cartId()) || isBlank(request.paymentMethod())) {
            return Response.status(Response.Status.BAD_REQUEST).entity(new ErrorResponse("invalid_order_request")).build();
        }
        Optional<OrderAcceptedView> accepted = axonOrderSagaService.createOrder(
                userId.get(),
                request.cartId(),
                request.paymentMethod()
        );
        if (accepted.isEmpty()) {
            return Response.status(Response.Status.NOT_FOUND).entity(new ErrorResponse("cart_not_found")).build();
        }
        return Response.status(Response.Status.ACCEPTED).entity(accepted.get()).build();
    }

    @GET
    @Path("/orders/{orderId}/status")
    public Response orderStatus(@HeaderParam("Authorization") String authorization,
                                @PathParam("orderId") String orderId) {
        Optional<String> userId = authTokenService.authenticate(authorization);
        if (userId.isEmpty()) {
            return unauthorized();
        }
        Optional<OrderStatusView> status = axonOrderSagaService.orderStatus(userId.get(), orderId);
        if (status.isEmpty()) {
            return Response.status(Response.Status.NOT_FOUND).entity(new ErrorResponse("order_not_found")).build();
        }
        return Response.ok(status.get()).build();
    }

    private static int normalizeLimit(Integer limit) {
        if (limit == null || limit <= 0) {
            return 10;
        }
        return Math.min(limit, 100);
    }

    private static Response unauthorized() {
        return Response.status(Response.Status.UNAUTHORIZED).entity(new ErrorResponse("unauthorized")).build();
    }

    private static boolean isBlank(String value) {
        return value == null || value.trim().isEmpty();
    }
}