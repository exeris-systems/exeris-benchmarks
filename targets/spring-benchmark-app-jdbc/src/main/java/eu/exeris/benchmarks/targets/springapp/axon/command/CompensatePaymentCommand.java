package eu.exeris.benchmarks.targets.springapp.application.axon.command;

public record CompensatePaymentCommand(String sagaId, String orderId, String userId, long dbOrderId) {}
