package eu.exeris.benchmarks.targets.quarkusapp.axon;

import eu.exeris.benchmarks.targets.quarkusapp.axon.command.CreateOrderCommand;
import eu.exeris.benchmarks.targets.quarkusapp.dto.OrderAcceptedView;
import eu.exeris.benchmarks.targets.quarkusapp.dto.OrderStatusView;
import eu.exeris.benchmarks.targets.quarkusapp.service.ShopSagaStateService;

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
    private final AtomicLong sagaSequence = new AtomicLong(1);

    private Registration commandSubscription;

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

    public Optional<OrderAcceptedView> createOrder(String userId, String cartId, String paymentMethod) {
        if (!shopSagaStateService.cartBelongsToUser(userId, cartId)) {
            return Optional.empty();
        }

        String orderId = Long.toString(orderSequence.getAndIncrement());
        String sagaId = "saga-" + sagaSequence.getAndIncrement();
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