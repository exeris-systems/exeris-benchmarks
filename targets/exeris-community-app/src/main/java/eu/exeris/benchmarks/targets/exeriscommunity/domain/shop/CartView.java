package eu.exeris.benchmarks.targets.exeriscommunity.domain.shop;



import java.util.List;

public record CartView(long cartId, List<CartItemView> items, double total) {}
