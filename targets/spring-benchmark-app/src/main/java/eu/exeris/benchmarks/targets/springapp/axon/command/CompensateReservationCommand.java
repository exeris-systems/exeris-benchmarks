package eu.exeris.benchmarks.targets.springapp.application.axon.command;

public record CompensateReservationCommand(String sagaId, String orderId, String userId, long dbOrderId) {}
