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
import eu.exeris.benchmarks.targets.quarkusapp.axon.OrderSagaLraParticipant;
import jakarta.ws.rs.PUT;
import org.eclipse.microprofile.lra.annotation.Compensate;
import org.eclipse.microprofile.lra.annotation.Complete;
import org.eclipse.microprofile.lra.annotation.Status;
import org.eclipse.microprofile.lra.annotation.ws.rs.LRA;
import java.net.URI;

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

    @Inject
    OrderSagaLraParticipant lraParticipant;

    // CONTRACT-v2 §9(a): the LRA participant callbacks MUST live on the same class as
    // the @LRA method — Quarkus fails the build otherwise. They delegate immediately;
    // the unwind logic stays in OrderSagaLraParticipant where it can be found by name.
    // @Consumes(WILDCARD) is load-bearing, not tidying. The class carries
    // @Consumes(APPLICATION_JSON), these callbacks inherit it, and the coordinator's
    // compensate PUT carries no JSON body — so JAX-RS rejected it with 415 before the
    // method ever ran. Measured 2026-08-21 against a local coordinator with io.narayana
    // at DEBUG:  LRAParticipantRecord.doEnd put .../order-saga/compensate failed with
    // status: 415.  The visible effect: this arm reported COMPENSATED to the client (the
    // app only checks that cancel() was ACCEPTED) while the domain store held 0
    // compensated rows against 121 expected declines, in every run, under load and on a
    // single request alike.
    @PUT
    @Path("/lra/order-saga/compensate")
    @Consumes(MediaType.WILDCARD)
    @Compensate
    public Response lraCompensate(@HeaderParam(LRA.LRA_HTTP_CONTEXT_HEADER) URI lraId) {
        return lraParticipant.compensate(lraId);
    }

    @PUT
    @Path("/lra/order-saga/complete")
    @Consumes(MediaType.WILDCARD)
    @Complete
    public Response lraComplete(@HeaderParam(LRA.LRA_HTTP_CONTEXT_HEADER) URI lraId) {
        return lraParticipant.complete(lraId);
    }

    @PUT
    @Path("/lra/order-saga/status")
    @Consumes(MediaType.WILDCARD)
    @Status
    public Response lraStatus(@HeaderParam(LRA.LRA_HTTP_CONTEXT_HEADER) URI lraId) {
        return lraParticipant.status(lraId);
    }

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

    // CONTRACT-v2 §4/§9(a): REQUIRES_NEW starts the LRA here and end=false keeps it
    // open across the park — the coordinator holds it while the external gateway takes
    // its time, which is what makes this arm's park durable rather than a heap entry.
    // It is ended from the gateway callback (LraClient), because that callback carries
    // no LRA context header: the gateway is identical for every stack and knows nothing
    // about LRA.
    @POST
    @Path("/orders")
    @LRA(value = LRA.Type.REQUIRES_NEW, end = false)
    public Response createOrder(@HeaderParam("Authorization") String authorization,
                                @HeaderParam(LRA.LRA_HTTP_CONTEXT_HEADER) String lraId,
                                CreateOrderRequest request) {
        Optional<String> userId = authTokenService.authenticate(authorization);
        if (userId.isEmpty()) {
            return unauthorized();
        }
        if (request == null || isBlank(request.cartId()) || isBlank(request.paymentMethod())) {
            return Response.status(Response.Status.BAD_REQUEST).entity(new ErrorResponse("invalid_order_request")).build();
        }
        Optional<OrderAcceptedView> accepted = axonOrderSagaService.createOrder(
                userId.get(),
                request.orderId(),
                request.cartId(),
                request.paymentMethod(),
                lraId
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