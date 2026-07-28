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

    private final AtomicLong orderSequence = new AtomicLong(1);

    private Registration commandSubscription;

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
    public Optional<OrderAcceptedView> createOrder(String userId, String clientOrderId, String cartId, String paymentMethod) {
        if (!shopSagaStateService.cartBelongsToUser(userId, cartId)) {
            return Optional.empty();
        }

        String orderId = (clientOrderId == null || clientOrderId.isBlank())
                ? Long.toString(orderSequence.getAndIncrement())
                : clientOrderId.trim();
        String sagaId = "saga-" + orderId;
        CreateOrderCommand command = new CreateOrderCommand(orderId, sagaId, userId, cartId, paymentMethod);
        OrderAcceptedView accepted = (OrderAcceptedView) commandGateway.sendAndWait(command);
        return Optional.ofNullable(accepted);
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