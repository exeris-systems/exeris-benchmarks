package eu.exeris.benchmarks.targets.springapp.application.axon.event;

/**
 * Payment declined — a BUSINESS-TERMINAL outcome (CONTRACT-v2 §4.1), not an
 * infrastructure error. Explicitly modeled as an event (never an exception) so
 * it is routed to saga compensation and can never be retried by the command
 * gateway's transient-fault retry scheduler (§5: zero retries on decline).
 */
public record PaymentDeclinedEvent(String sagaId, String orderId, String userId, long dbOrderId) {}
