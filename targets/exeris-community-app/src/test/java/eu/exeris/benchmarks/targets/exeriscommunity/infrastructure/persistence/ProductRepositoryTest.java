package eu.exeris.benchmarks.targets.exeriscommunity.infrastructure.persistence;

import eu.exeris.benchmarks.targets.exeriscommunity.domain.shop.ProductView;
import eu.exeris.kernel.spi.persistence.PersistenceConnection;
import eu.exeris.kernel.spi.persistence.TransactionalExecutor;
import eu.exeris.kernel.spi.persistence.TransactionalExecutor.TransactionalWork;
import eu.exeris.kernel.spi.persistence.TransactionIsolation;
import java.util.List;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.function.Function;
import org.junit.jupiter.api.Test;
import static org.junit.jupiter.api.Assertions.assertDoesNotThrow;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertThrows;

final class ProductRepositoryTest {

    @Test
    void findRecommendedForUserReturnsFallbackWhenPrimaryQueryThrows() {
        ProductView fallbackProduct = new ProductView(1L, "Fallback", 1.0d, "General");
        AtomicInteger callCount = new AtomicInteger(0);

        TransactionalExecutor executor = new CapturingExecutor(callCount, fallbackProduct);
        ProductRepository repo = new ProductRepository(executor);

        List<ProductView> results = assertDoesNotThrow(() -> repo.findRecommendedForUser(42L, 5));

        assertFalse(results.isEmpty());
        assertEquals(fallbackProduct.id(), results.get(0).id());
        assertEquals(2, callCount.get(), "Both primary and fallback queries must be attempted");
    }

    @Test
    void findRecommendedForUserPropagatesOriginalFailureWhenFallbackAlsoThrows() {
        RuntimeException primaryEx = new RuntimeException("primary SQL failed");
        AtomicInteger callCount = new AtomicInteger(0);

        TransactionalExecutor executor = new TransactionalExecutor() {
            @Override
            public void execute(TransactionalWork work) {
                throw new UnsupportedOperationException();
            }

            @Override
            public void executeManaged(TransactionalWork work) {
                throw new UnsupportedOperationException();
            }

            @Override
            public void executeManaged(TransactionIsolation isolation, boolean readOnly, TransactionalWork work) {
                throw new UnsupportedOperationException();
            }

            @Override
            public <T> T query(Function<PersistenceConnection, T> query) {
                int call = callCount.incrementAndGet();
                if (call == 1) {
                    throw primaryEx;
                }
                throw new RuntimeException("fallback also failed");
            }
        };
        ProductRepository repo = new ProductRepository(executor);

        RuntimeException thrown = assertThrows(RuntimeException.class,
            () -> repo.findRecommendedForUser(42L, 5));
        assertEquals(primaryEx, thrown, "Original primary failure must be propagated");
        assertEquals(2, callCount.get(), "Both primary and fallback must be attempted");
    }

    private static final class CapturingExecutor implements TransactionalExecutor {

        private final AtomicInteger callCount;
        private final ProductView fallbackProduct;

        CapturingExecutor(AtomicInteger callCount, ProductView fallbackProduct) {
            this.callCount = callCount;
            this.fallbackProduct = fallbackProduct;
        }

        @Override
        public void execute(TransactionalWork work) {
            throw new UnsupportedOperationException();
        }

        @Override
        public void executeManaged(TransactionalWork work) {
            throw new UnsupportedOperationException();
        }

        @Override
        public void executeManaged(TransactionIsolation isolation, boolean readOnly, TransactionalWork work) {
            throw new UnsupportedOperationException();
        }

        @Override
        public <T> T query(Function<PersistenceConnection, T> query) {
            int call = callCount.incrementAndGet();
            if (call == 1) {
                throw new RuntimeException("RLS denied: user_purchase_history");
            }
            @SuppressWarnings("unchecked")
            T result = (T) List.of(fallbackProduct);
            return result;
        }
    }
}
