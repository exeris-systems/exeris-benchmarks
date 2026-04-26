package eu.exeris.benchmarks.targets.springapp.application.axon.event;

public record PaymentCompensatedEvent(String sagaId, String orderId, String userId, long dbOrderId) {}
