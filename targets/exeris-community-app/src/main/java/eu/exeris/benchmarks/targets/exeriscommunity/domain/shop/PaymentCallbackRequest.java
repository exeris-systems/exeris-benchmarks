package eu.exeris.benchmarks.targets.exeriscommunity.domain.shop;

import com.fasterxml.jackson.annotation.JsonAlias;
import com.fasterxml.jackson.annotation.JsonIgnoreProperties;

/**
 * CONTRACT-v2 section 4 (parking workload): the external payment gateway's
 * asynchronous callback body.
 *
 * <p>{@code outcome} is {@code AUTHORIZED} or {@code DECLINED}, decided by the
 * gateway using the same bit-identical FNV-1a 64 rule the targets previously
 * evaluated in-process, so the section 4.1 exact-compensation oracle is
 * unaffected by moving the decision out of the target.
 *
 * <p>Unknown fields are ignored: the gateway also sends {@code decline_rule} for
 * traceability, and a strict binding would reject the callback and strand the
 * saga.
 */
@JsonIgnoreProperties(ignoreUnknown = true)
public record PaymentCallbackRequest(
    @JsonAlias("order_id") String orderId,
    @JsonAlias("saga_id") String sagaId,
    String outcome
) {
}
