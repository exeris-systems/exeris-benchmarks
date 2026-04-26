package eu.exeris.benchmarks.targets.exeriscommunity.domain.shop;



public record OrderStatusResponse(long orderId, String sagaId, String status) {}
