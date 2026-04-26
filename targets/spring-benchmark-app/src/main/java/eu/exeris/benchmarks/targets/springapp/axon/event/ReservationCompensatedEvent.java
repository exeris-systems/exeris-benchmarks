package eu.exeris.benchmarks.targets.springapp.application.axon.event;

public record ReservationCompensatedEvent(String sagaId, String orderId, String userId, long dbOrderId) {}
