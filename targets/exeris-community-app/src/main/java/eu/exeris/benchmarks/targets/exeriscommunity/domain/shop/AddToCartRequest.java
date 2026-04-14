package eu.exeris.benchmarks.targets.exeriscommunity.domain.shop;

import com.fasterxml.jackson.annotation.JsonAlias;

public record AddToCartRequest(@JsonAlias("product_id") long productId, int quantity) {}
