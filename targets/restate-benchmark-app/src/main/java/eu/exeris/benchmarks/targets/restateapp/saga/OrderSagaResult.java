package eu.exeris.benchmarks.targets.restateapp.saga;

/**
 * Terminal saga outcome returned by the OrderSaga handler. Status uses the
 * CONTRACT-v2 §3 final-outcome vocabulary:
 * COMPLETED | COMPENSATED | FAILED_UNRECOVERED.
 */
public record OrderSagaResult(
        String orderId,
        String status,
        String sagaId
) {
    public static final String COMPLETED = "COMPLETED";
    public static final String COMPENSATED = "COMPENSATED";
    public static final String FAILED_UNRECOVERED = "FAILED_UNRECOVERED";
}
