package eu.exeris.benchmarks.targets.springapp.api;

import com.fasterxml.jackson.annotation.JsonProperty;

public record OrderAcceptedView(
        @JsonProperty("order_id") String orderId,
        String status,
        @JsonProperty("saga_id") String sagaId
) {
}
