package eu.exeris.benchmarks.targets.quarkusapp.dto;

import com.fasterxml.jackson.annotation.JsonProperty;

public record OrderAcceptedView(
        @JsonProperty("order_id") String orderId,
        String status,
        @JsonProperty("saga_id") String sagaId
) {
}