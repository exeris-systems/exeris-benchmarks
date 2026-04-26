package eu.exeris.benchmarks.targets.exeriscommunity.domain.shop;

import com.fasterxml.jackson.annotation.JsonAlias;

public record PlaceOrderRequest(@JsonAlias("cart_id") long cartId,
								@JsonAlias("payment_method") String paymentMethod) {}
