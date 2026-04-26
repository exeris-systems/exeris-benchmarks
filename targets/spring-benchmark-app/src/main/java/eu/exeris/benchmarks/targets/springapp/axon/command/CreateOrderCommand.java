package eu.exeris.benchmarks.targets.springapp.application.axon.command;

import org.axonframework.modelling.command.TargetAggregateIdentifier;

public record CreateOrderCommand(
        @TargetAggregateIdentifier
        String orderId,
        String userId,
        String cartId,
        String paymentMethod,
        String sagaId
) {
}