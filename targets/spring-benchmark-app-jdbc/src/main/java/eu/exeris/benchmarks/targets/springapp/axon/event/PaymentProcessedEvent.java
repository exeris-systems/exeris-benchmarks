package eu.exeris.benchmarks.targets.springapp.application.axon.event;

public record PaymentProcessedEvent(String sagaId, String orderId, String userId, long dbOrderId) {}
