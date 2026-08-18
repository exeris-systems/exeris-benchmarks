package eu.exeris.benchmarks.targets.springapp.application.axon.event;

public record OrderConfirmedEvent(String sagaId, String orderId, String userId, long dbOrderId) {}
