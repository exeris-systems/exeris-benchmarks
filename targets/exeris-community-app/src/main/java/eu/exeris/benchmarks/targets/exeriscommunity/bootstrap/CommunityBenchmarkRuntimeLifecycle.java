package eu.exeris.benchmarks.targets.exeriscommunity.bootstrap;

import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.atomic.AtomicReference;

import eu.exeris.benchmarks.targets.exeriscommunity.api.CommunityBenchmarkRouteHandler;
import eu.exeris.benchmarks.targets.exeriscommunity.application.BenchmarkUseCaseService;
import eu.exeris.benchmarks.targets.exeriscommunity.application.RepositoryBackedBenchmarkUseCaseService;
import eu.exeris.benchmarks.targets.exeriscommunity.infrastructure.events.DomainEventPublisher;
import eu.exeris.benchmarks.targets.exeriscommunity.infrastructure.graph.GraphFriendsOfFriendsAdapter;
import eu.exeris.benchmarks.targets.exeriscommunity.infrastructure.graph.GraphShopAdapter;
import eu.exeris.benchmarks.targets.exeriscommunity.infrastructure.persistence.CartRepository;
import eu.exeris.benchmarks.targets.exeriscommunity.infrastructure.persistence.OrderRepository;
import eu.exeris.benchmarks.targets.exeriscommunity.infrastructure.persistence.PrincipalRepository;
import eu.exeris.benchmarks.targets.exeriscommunity.infrastructure.persistence.ProductRepository;
import eu.exeris.benchmarks.targets.exeriscommunity.infrastructure.persistence.UserRepository;
import eu.exeris.benchmarks.targets.exeriscommunity.saga.OrderSagaOrchestrator;
import eu.exeris.benchmarks.targets.exeriscommunity.security.BenchmarkJwtSecurityProvider;
import eu.exeris.benchmarks.targets.exeriscommunity.security.BenchmarkTokenIssuer;
import eu.exeris.kernel.core.http.routing.HttpRouter;
import eu.exeris.kernel.core.persistence.TransactionOrchestrator;
import eu.exeris.kernel.core.security.SecurityInterceptor;
import eu.exeris.kernel.spi.context.KernelProviders;
import eu.exeris.kernel.spi.events.EventEngine;
import eu.exeris.kernel.spi.flow.FlowEngine;
import eu.exeris.kernel.spi.http.HttpExchange;
import eu.exeris.kernel.spi.http.HttpHandler;
import eu.exeris.kernel.spi.http.HttpKernelProviders;
import eu.exeris.kernel.spi.http.HttpMethod;
import eu.exeris.kernel.spi.http.HttpServerEngine;
import eu.exeris.kernel.spi.http.HttpStatus;
import eu.exeris.kernel.spi.memory.MemoryAllocator;
import eu.exeris.kernel.spi.persistence.PersistenceEngine;
import eu.exeris.kernel.spi.persistence.TransactionalExecutor;
import jdk.jfr.FlightRecorder;
import jdk.jfr.Recording;

public final class CommunityBenchmarkRuntimeLifecycle {

    private static final String JFR_VTHREAD_PINNED_ENV = "EXERIS_JFR_VTHREAD_PINNED";
    private final AtomicReference<HttpHandler> handlerSlot;

    public CommunityBenchmarkRuntimeLifecycle(AtomicReference<HttpHandler> handlerSlot) {
        this.handlerSlot = handlerSlot;
    }

    public void run() {
        patchJfrForVirtualThreadDiagnosticsIfRequested();

        PersistenceEngine persistenceEngine = KernelProviders.persistenceEngine();
        HttpServerEngine serverEngine = HttpKernelProviders.HTTP_SERVER_ENGINE.get();
        TransactionalExecutor transactionalExecutor = new TransactionOrchestrator(persistenceEngine);

        UserRepository userRepository = new UserRepository(transactionalExecutor);
        ProductRepository productRepository = new ProductRepository(transactionalExecutor);
        CartRepository cartRepository = new CartRepository(transactionalExecutor);
        OrderRepository orderRepository = new OrderRepository(transactionalExecutor);
        PrincipalRepository principalRepository = new PrincipalRepository(transactionalExecutor);
        eu.exeris.kernel.spi.graph.GraphEngine graphEngine = KernelProviders.GRAPH_ENGINE.isBound()
                ? KernelProviders.GRAPH_ENGINE.get()
                : null;
        GraphFriendsOfFriendsAdapter graphFriendsOfFriendsAdapter = new GraphFriendsOfFriendsAdapter(graphEngine);
        GraphShopAdapter graphShopAdapter = new GraphShopAdapter(graphEngine);
        if (graphEngine != null) {
            java.util.List<eu.exeris.kernel.spi.graph.model.GraphEdgeDescriptor> allEdges = new java.util.ArrayList<>();
            allEdges.addAll(graphFriendsOfFriendsAdapter.edgeDescriptors());
            allEdges.addAll(graphShopAdapter.edgeDescriptors());
            graphEngine.registerEdges(allEdges);
        }

        // Flow / Events are optional subsystems (see EXERIS_SUBSYSTEMS in ExerisCommunityApplication).
        // When the scenario did not bootstrap them, the saga wiring is left null and the order
        // endpoints reject requests — every other route works without them.
        EventEngine eventEngine = KernelProviders.EVENT_ENGINE.isBound()
                ? KernelProviders.EVENT_ENGINE.get()
                : null;
        DomainEventPublisher domainEventPublisher = eventEngine != null
                ? new DomainEventPublisher(eventEngine)
                : null;
        FlowEngine flowEngine = KernelProviders.FLOW_ENGINE.isBound()
                ? KernelProviders.FLOW_ENGINE.get()
                : null;
        OrderSagaOrchestrator orderSagaOrchestrator = flowEngine != null
                ? new OrderSagaOrchestrator(flowEngine, orderRepository, domainEventPublisher, transactionalExecutor)
                : null;
        if (orderSagaOrchestrator != null) {
            orderSagaOrchestrator.initialize();
        }

        BenchmarkTokenIssuer tokenIssuer = new BenchmarkTokenIssuer();
        BenchmarkJwtSecurityProvider securityProvider = new BenchmarkJwtSecurityProvider(
            Map.of(BenchmarkTokenIssuer.KID, tokenIssuer.publicKey()),
            BenchmarkTokenIssuer.ISSUER,
            BenchmarkTokenIssuer.AUD
        );
        SecurityInterceptor securityInterceptor = new SecurityInterceptor(securityProvider);

        BenchmarkUseCaseService useCaseService = new RepositoryBackedBenchmarkUseCaseService(
            userRepository,
            graphFriendsOfFriendsAdapter,
            graphShopAdapter,
            productRepository,
            cartRepository,
            orderRepository,
            principalRepository,
            orderSagaOrchestrator,
            tokenIssuer
        );
        MemoryAllocator allocator = KernelProviders.MEMORY_ALLOCATOR.get();
        CommunityBenchmarkRouteHandler routeHandler =
            new CommunityBenchmarkRouteHandler(useCaseService, securityInterceptor, principalRepository::findUserIdByPrincipal, allocator);
        HttpRouter router = HttpRouter.builder()
                .route(HttpMethod.GET, "/health",       routeHandler::handleHealth)
                .route(HttpMethod.GET, "/plaintext",    routeHandler::handlePlaintext)
                .route(HttpMethod.GET, "/db/ping",      routeHandler::handleDbPing)
                .route(HttpMethod.GET, "/api/v1/users", routeHandler::handleUsers)
                .route(HttpMethod.GET, "/api/v1/graph/friends-of-friends/without-interests",
                    routeHandler::handleFriendsOfFriendsWithoutInterests)
                .route(HttpMethod.POST, "/api/v1/auth/register", routeHandler::handleRegister)
                .route(HttpMethod.GET, "/api/v1/products/recommended", routeHandler::handleRecommendedProducts)
                .route(HttpMethod.POST, "/api/v1/cart/add", routeHandler::handleAddToCart)
                .route(HttpMethod.GET, "/api/v1/cart", routeHandler::handleGetCart)
                .route(HttpMethod.POST, "/api/v1/orders", routeHandler::handlePlaceOrder)
                .build();

        HttpHandler appHandler = exchange -> {
            try {
                if (shouldDispatchOrderGet(exchange)) {
                    dispatchOrderGet(exchange, routeHandler);
                    return;
                }
                router.handle(exchange);
            } catch (RuntimeException exception) {
                exception.printStackTrace(System.err);
                CommunityBenchmarkRouteHandler.respondNoBody(exchange, HttpStatus.INTERNAL_SERVER_ERROR);
            }
        };
        handlerSlot.set(appHandler);

        CountDownLatch shutdownLatch = new CountDownLatch(1);
        Runtime.getRuntime().addShutdownHook(new Thread(() -> {
            safeStop(serverEngine);
            shutdownLatch.countDown();
        }, "exeris-community-app-shutdown"));

        try {
            shutdownLatch.await();
        } catch (InterruptedException interrupted) {
            Thread.currentThread().interrupt();
        }
    }

    /**
     * When EXERIS_JFR_VTHREAD_PINNED=true, enables jdk.VirtualThreadPinned on all active JFR
     * recordings. This captures virtual-thread pinning evidence on our side without requiring a
     * SubsystemProvider SPI entry for telemetry.
     */
    private static void patchJfrForVirtualThreadDiagnosticsIfRequested() {
        if (!Boolean.parseBoolean(System.getenv(JFR_VTHREAD_PINNED_ENV))) {
            return;
        }
        try {
            List<Recording> recordings = FlightRecorder.getFlightRecorder().getRecordings();
            if (recordings.isEmpty()) {
                System.err.println("[jfr-diag] EXERIS_JFR_VTHREAD_PINNED=true but no active JFR recordings found; start with -XX:StartFlightRecording to capture events");
                return;
            }
            for (Recording recording : recordings) {
                Map<String, String> settings = new HashMap<>(recording.getSettings());
                settings.put("jdk.VirtualThreadPinned#enabled", "true");
                settings.put("jdk.VirtualThreadPinned#threshold", "0 ms");
                recording.setSettings(settings);
            }
            System.out.println("[jfr-diag] jdk.VirtualThreadPinned enabled on " + recordings.size() + " recording(s)");
        } catch (IllegalStateException ise) {
            System.err.println("[jfr-diag] FlightRecorder not available: " + ise.getMessage());
        }
    }

    private static boolean shouldDispatchOrderGet(HttpExchange exchange) {
        return exchange.request().method() == HttpMethod.GET
            && normalizedPath(exchange.request().path()).startsWith("/api/v1/orders");
    }

    private static void dispatchOrderGet(HttpExchange exchange, CommunityBenchmarkRouteHandler routeHandler) {
        String path = normalizedPath(exchange.request().path());
        if ("/api/v1/orders/status".equals(path)) {
            routeHandler.handleOrderStatusByQuery(exchange);
            return;
        }
        if (path.startsWith("/api/v1/orders/") && path.endsWith("/status")) {
            routeHandler.handleOrderStatus(exchange);
            return;
        }
        CommunityBenchmarkRouteHandler.respondNoBody(exchange, HttpStatus.NOT_FOUND);
    }

    private static String normalizedPath(String path) {
        if (path == null || path.isBlank()) {
            return "";
        }
        int queryIndex = path.indexOf('?');
        return queryIndex >= 0 ? path.substring(0, queryIndex) : path;
    }

    private static void safeStop(HttpServerEngine serverEngine) {
        try {
            serverEngine.stop();
            serverEngine.close();
        } catch (RuntimeException ignored) {
        }
    }
}
