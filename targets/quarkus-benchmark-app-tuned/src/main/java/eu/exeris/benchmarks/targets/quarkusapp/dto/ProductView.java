package eu.exeris.benchmarks.targets.quarkusapp.dto;

import java.math.BigDecimal;

public record ProductView(String id, String name, BigDecimal price, String category) {
}