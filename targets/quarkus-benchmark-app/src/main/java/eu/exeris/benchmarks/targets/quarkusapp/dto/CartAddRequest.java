package eu.exeris.benchmarks.targets.quarkusapp.dto;

import com.fasterxml.jackson.annotation.JsonAlias;

public record CartAddRequest(
        @JsonAlias("product_id") String productId,
        int quantity
) {
}