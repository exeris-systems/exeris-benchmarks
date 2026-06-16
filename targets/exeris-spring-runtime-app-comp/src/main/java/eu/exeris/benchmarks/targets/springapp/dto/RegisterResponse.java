package eu.exeris.benchmarks.targets.springapp.api;

import com.fasterxml.jackson.annotation.JsonProperty;

public record RegisterResponse(
        String token,
        @JsonProperty("user_id") String userId
) {
}
