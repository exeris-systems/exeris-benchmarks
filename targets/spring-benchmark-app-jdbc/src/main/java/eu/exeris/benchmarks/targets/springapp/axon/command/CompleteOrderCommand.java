package eu.exeris.benchmarks.targets.springapp.application.axon.command;

public record CompleteOrderCommand(String sagaId, String orderId, String userId, long dbOrderId) {}
