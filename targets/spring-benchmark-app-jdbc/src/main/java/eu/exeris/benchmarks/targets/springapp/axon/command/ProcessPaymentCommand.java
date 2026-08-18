package eu.exeris.benchmarks.targets.springapp.application.axon.command;

public record ProcessPaymentCommand(String sagaId, String orderId, String userId, long dbOrderId, String paymentMethod) {}
