package eu.exeris.benchmarks.targets.quarkusapp.axon;

import eu.exeris.benchmarks.targets.quarkusapp.axon.command.CreateOrderCommand;
import eu.exeris.benchmarks.targets.quarkusapp.dto.OrderAcceptedView;
import eu.exeris.benchmarks.targets.quarkusapp.dto.OrderStatusView;
import eu.exeris.benchmarks.targets.quarkusapp.service.ShopSagaStateService;

import io.quarkus.runtime.Startup;

import jakarta.annotation.PostConstruct;
import jakarta.annotation.PreDestroy;
import jakarta.enterprise.context.ApplicationScoped;
import jakarta.inject.Inject;

import org.axonframework.commandhandling.CommandBus;
import org.axonframework.commandhandling.CommandMessage;
import org.axonframework.commandhandling.gateway.CommandGateway;
import org.axonframework.common.Registration;

import java.util.Optional;
import java.util.OptionalLong;
import java.util.concurrent.CompletableFuture;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.ConcurrentMap;
import java.util.concurrent.ExecutionException;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.TimeoutException;
import java.util.concurrent.atomic.AtomicLong;

@Startup
@ApplicationScoped
public class AxonOrderSagaService {

    @Inject
    ShopSagaStateService shopSagaStateService;

    @Inject
    CommandBus commandBus;

    @Inject
    CommandGateway commandGateway;

    @Inject
    AxonOrderSagaCommandHandler commandHandler;

    @Inject
    AxonOrderSagaProjection projection;

    @Inject
    OrderSagaStepService stepService;

    private final AtomicLong orderSequence = new AtomicLong(1);

    private Registration commandSubscription;

    /**
     * CONTRACT-v2 §3 request-response support: one future per saga parked on payment,
     * completed by {@link #settlePayment} with the terminal outcome.
     *
     * <p>This is the ONLY in-memory state this stack keeps about an in-flight saga —
     * the response handle, which every stack needs to answer §3. The saga's own
     * continuation state lives in the {@code orders} row.
     */
    private final ConcurrentMap<String, CompletableFuture<String>> terminalOutcome =
            new ConcurrentHashMap<>();

    /**
     * CONTRACT-v2 §3 request-response budget. Matched to the client's own resolution
     * budget (k6 polls 25 × 1 s) so this stack never gives up before the client would.
     */
    private static final long SAGA_TERMINAL_AWAIT_TIMEOUT_MILLIS =
            parseEnvLong("EXERIS_SAGA_TERMINAL_AWAIT_TIMEOUT_MILLIS", 25_000L);

    private static long parseEnvLong(String name, long fallback) {
        String raw = System.getenv(name);
        if (raw == null || raw.isBlank()) {
            return fallback;
        }
        try {
            return Long.parseLong(raw.trim());
        } catch (NumberFormatException invalid) {
            return fallback;
        }
    }

    /**
     * The bean is {@code @Startup}-eager so the CreateOrderCommand registration with
     * Axon Server is initiated during boot, not on the first POST /orders: a lazy bean
     * combined with the non-awaited {@code AxonServerCommandBus.subscribe(..)} ack meant
     * the first harness requests could race the server-side registration and fail with
     * NoHandlerForCommandException.
     */
    @PostConstruct
    @SuppressWarnings("unused")
    void subscribe() {
        commandSubscription = commandBus.subscribe(
                CreateOrderCommand.class.getName(),
                this::handleCommand
        );
    }

    @PreDestroy
    @SuppressWarnings("unused")
    void unsubscribe() {
        if (commandSubscription != null) {
            commandSubscription.cancel();
        }
    }

    /**
     * {@code clientOrderId} is the CONTRACT-v2 §3 client-generated deterministic orderId.
     * When present it is adopted verbatim — it is the input to the §4.1 deterministic
     * payment-decline rule, so minting a server-side id here would break the "identical
     * declined subset in every stack and every run" invariant. Blank/absent (pre-v2
     * clients) falls back to the server-generated sequence. {@code sagaId} is derived as
     * {@code "saga-" + orderId} so the projection's {@code saga_id} lookup stays coherent
     * for both populations (the previous lockstep order/saga sequences produced the same
     * derivation for sequence-based ids).
     */
    public Optional<OrderAcceptedView> createOrder(String userId, String clientOrderId, String cartId, String paymentMethod, String lraId) {
        if (!shopSagaStateService.cartBelongsToUser(userId, cartId)) {
            return Optional.empty();
        }

        String orderId = (clientOrderId == null || clientOrderId.isBlank())
                ? Long.toString(orderSequence.getAndIncrement())
                : clientOrderId.trim();
        String sagaId = "saga-" + orderId;
        CreateOrderCommand command = new CreateOrderCommand(orderId, sagaId, userId, cartId, paymentMethod, lraId);

        // Registered BEFORE dispatch: with a ~1 ms gateway delay the callback can settle the
        // saga while sendAndWait is still returning, and a late registration would miss it.
        terminalOutcome.put(sagaId, new CompletableFuture<>());

        OrderAcceptedView accepted;
        try {
            accepted = (OrderAcceptedView) commandGateway.sendAndWait(command);
        } catch (RuntimeException dispatchFailure) {
            terminalOutcome.remove(sagaId);
            throw dispatchFailure;
        }
        if (accepted == null) {
            terminalOutcome.remove(sagaId);
            return Optional.empty();
        }
        if (!AxonOrderSagaCommandHandler.PARKED.equals(accepted.status())) {
            // The saga never reached the pivot (a forward step exhausted its §5 retry
            // budget) and already carries its terminal outcome. Nothing will call back.
            terminalOutcome.remove(sagaId);
            return Optional.of(accepted);
        }

        // CONTRACT-v2 §3: the response must carry the FINAL outcome, so wait for the
        // gateway callback to settle the park. Idiom deviation registered under §9(a) —
        // and the same one exeris-community makes, on a virtual thread in both cases
        // (@RunOnVirtualThread on the resource), so the two stacks hold the request the
        // same way. Falls back to the pre-v2 async "ACCEPTED" on timeout so a slow saga
        // degrades to client polling rather than failing the request.
        String status = awaitTerminalOutcome(sagaId, SAGA_TERMINAL_AWAIT_TIMEOUT_MILLIS)
                .orElse("ACCEPTED");
        return Optional.of(new OrderAcceptedView(orderId, status, sagaId));
    }

    /**
     * CONTRACT-v2 §4 (parking workload): settles a saga parked on payment, driven by
     * the external gateway's callback. Claims the settlement with a compare-and-set on
     * the order row, runs the continuation, then releases the waiting request.
     *
     * @return false when no saga was parked on payment under {@code sagaId} — a
     *         duplicate callback, or one for a saga this process never had
     */
    public boolean settlePayment(String orderId, String sagaId, boolean authorized) {
        OptionalLong dbOrderId = stepService.settleParkedPayment(sagaId, authorized);
        if (dbOrderId.isEmpty()) {
            return false;
        }
        // The LRA id comes off the ROW, not from the caller: the gateway callback carries
        // no LRA context, and after a restart there is no caller left to carry it either.
        String lraId = stepService.readLraId(dbOrderId.getAsLong());
        String terminal = commandHandler.settle(orderId, sagaId, dbOrderId.getAsLong(), authorized, lraId);
        CompletableFuture<String> waiting = terminalOutcome.get(sagaId);
        if (waiting != null) {
            waiting.complete(terminal);
        }
        return true;
    }

    private Optional<String> awaitTerminalOutcome(String sagaId, long timeoutMillis) {
        CompletableFuture<String> future = terminalOutcome.get(sagaId);
        if (future == null) {
            return Optional.empty();
        }
        try {
            return Optional.ofNullable(future.get(timeoutMillis, TimeUnit.MILLISECONDS));
        } catch (TimeoutException timeout) {
            return Optional.empty();
        } catch (InterruptedException interrupted) {
            Thread.currentThread().interrupt();
            return Optional.empty();
        } catch (ExecutionException failure) {
            return Optional.empty();
        } finally {
            // Drop on timeout too, or a saga that never settles leaks its future for the
            // lifetime of the process.
            terminalOutcome.remove(sagaId);
        }
    }

    public Optional<OrderStatusView> orderStatus(String userId, String orderId) {
        return projection.orderStatus(userId, orderId);
    }

    private Object handleCommand(CommandMessage<?> message) {
        Object payload = message.getPayload();
        if (payload == null) {
            throw new IllegalArgumentException("Unsupported command type: null");
        }
        if (payload instanceof CreateOrderCommand command) {
            return commandHandler.handle(command);
        }
        throw new IllegalArgumentException("Unsupported command type: " + payload.getClass().getName());
    }
}