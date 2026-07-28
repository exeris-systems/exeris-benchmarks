package eu.exeris.benchmarks.targets.exeriscommunity.domain.shop;

import com.fasterxml.jackson.annotation.JsonAlias;

public record PlaceOrderRequest(@JsonAlias("cart_id") long cartId,
								@JsonAlias("payment_method") String paymentMethod,
								// CONTRACT-v2 section 3: optional client-generated orderId
								// (deterministic seeded population) adopted verbatim as the
								// API-level order identity when present.
								@JsonAlias("order_id") String orderId) {}
