package eu.exeris.benchmarks.targets.springapp.application.axon.command;

public record ConfirmOrderCommand(String sagaId, String orderId, String userId, long dbOrderId) {}
