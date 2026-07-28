package eu.exeris.benchmarks.targets.restateapp.saga;

import java.nio.charset.StandardCharsets;

/**
 * CONTRACT-v2 §4.1 deterministic business-terminal payment decline
 * (scenarios/e2e-shop-order-saga/CONTRACT-v2.md).
 *
 * Normative rule, identical in every stack — deviation is a correctness bug:
 *
 *   decline(orderId) := Long.remainderUnsigned(fnv1a64(orderId), 1000) &lt; 30
 *
 * where fnv1a64 is FNV-1a 64-bit over the UTF-8 bytes of the orderId string
 * (offset basis 0xcbf29ce484222325, prime 0x100000001b3, unsigned arithmetic).
 * Selection is per-orderId, not per-attempt: exactly 3.0% of a deterministic
 * orderId population is declined, the identical subset in every stack and every
 * run. This makes the expected compensation count an exact integer oracle
 * (CONTRACT-v2 §4.1 / §7 O2), replacing the v1 probabilistic
 * EXERIS_SAGA_PAYMENT_FAIL_RATE injection.
 */
public final class PaymentDeclineRule {

    /** FNV-1a 64-bit offset basis (CONTRACT-v2 §4.1 normative constant). */
    private static final long FNV_OFFSET_BASIS = 0xcbf29ce484222325L;

    /** FNV-1a 64-bit prime (CONTRACT-v2 §4.1 normative constant). */
    private static final long FNV_PRIME = 0x100000001b3L;

    /** Declined permille of the orderId population: 30/1000 = exactly 3.0%. */
    private static final long DECLINE_PERMILLE = 30L;

    private PaymentDeclineRule() {
    }

    public static boolean isDeclined(String orderId) {
        return Long.remainderUnsigned(fnv1a64(orderId), 1000L) < DECLINE_PERMILLE;
    }

    static long fnv1a64(String value) {
        long hash = FNV_OFFSET_BASIS;
        for (byte b : value.getBytes(StandardCharsets.UTF_8)) {
            hash ^= (b & 0xffL);
            hash *= FNV_PRIME;
        }
        return hash;
    }
}
