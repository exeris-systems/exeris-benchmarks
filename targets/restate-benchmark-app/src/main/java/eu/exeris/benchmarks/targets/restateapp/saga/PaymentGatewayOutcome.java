package eu.exeris.benchmarks.targets.restateapp.saga;

import com.fasterxml.jackson.annotation.JsonIgnoreProperties;
import com.fasterxml.jackson.annotation.JsonProperty;

/**
 * Value the external payment gateway resolves the {@code charge-payment} awakeable
 * with (CONTRACT-v2 §4). The gateway posts it verbatim to the Restate ingress'
 * awakeable-resolve endpoint, so this record must match the stub's callback body
 * (see {@code targets/payment-gateway-stub/payment_stub.py}).
 *
 * <p>{@code ignoreUnknown} on purpose: the stub also sends {@code decline_rule} for
 * traceability, and a stack that fell over on an extra documentation field would be
 * brittle for no benefit.
 */
@JsonIgnoreProperties(ignoreUnknown = true)
public record PaymentGatewayOutcome(
        @JsonProperty("order_id") String orderId,
        @JsonProperty("saga_id") String sagaId,
        @JsonProperty("outcome") String outcome
) {

    public static final String AUTHORIZED = "AUTHORIZED";

    public boolean authorized() {
        return AUTHORIZED.equalsIgnoreCase(outcome);
    }
}
