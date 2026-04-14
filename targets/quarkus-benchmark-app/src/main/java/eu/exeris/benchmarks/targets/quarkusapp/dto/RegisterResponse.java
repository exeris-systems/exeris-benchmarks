package eu.exeris.benchmarks.targets.quarkusapp.dto;

import com.fasterxml.jackson.annotation.JsonProperty;

public record RegisterResponse(
        String token,
        @JsonProperty("user_id") String userId
) {
}