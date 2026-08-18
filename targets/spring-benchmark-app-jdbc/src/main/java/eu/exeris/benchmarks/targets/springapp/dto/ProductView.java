package eu.exeris.benchmarks.targets.springapp.api;

import java.math.BigDecimal;

public record ProductView(String id, String name, BigDecimal price, String category) {
}
