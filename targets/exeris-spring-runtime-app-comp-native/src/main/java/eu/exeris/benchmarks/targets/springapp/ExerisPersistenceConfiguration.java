package eu.exeris.benchmarks.targets.springapp;

import eu.exeris.kernel.core.persistence.TransactionOrchestrator;
import eu.exeris.kernel.spi.persistence.ConnectionInterceptor;
import eu.exeris.kernel.spi.persistence.EngineStats;
import eu.exeris.kernel.spi.persistence.PersistenceConnection;
import eu.exeris.kernel.spi.persistence.PersistenceEngine;
import eu.exeris.kernel.spi.persistence.PersistenceHealthStatus;
import eu.exeris.kernel.spi.persistence.TransactionalExecutor;
import eu.exeris.kernel.spi.security.StorageContext;
import eu.exeris.spring.runtime.tx.PersistenceEngineProvider;

import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;

import java.util.Objects;

/**
 * Wires the kernel-native persistence API into the Spring context.
 *
 * <p>This is the one piece of glue that pure-native needs and neither of the other two Exeris
 * arms does. Those arms reach the database through {@code ExerisDataSource} (the compatibility
 * bridge) and let Hibernate drive it; this arm bypasses that entirely and uses
 * {@link TransactionalExecutor} — the same API {@code targets/exeris-community-app} uses.
 *
 * <h2>Why the engine cannot simply be injected</h2>
 *
 * <p>{@code PersistenceEngineProvider#get()} resolves {@code KernelProviders.PERSISTENCE_ENGINE},
 * which is a {@link ScopedValue} bound per request by the kernel's provider binder. Calling it at
 * bean-creation time throws "ScopedValue not bound", and caching its result in a singleton would
 * pin one request's engine for the lifetime of the application.
 *
 * <p>So the singleton here is a {@link PersistenceEngine} <em>adapter</em> that re-resolves the
 * provider on every call. The {@link TransactionOrchestrator} built over it is safe to share:
 * it holds no connection state between calls, and every {@code query}/{@code execute} opens and
 * closes its connection inside the caller's scope.
 *
 * <p>This is the app-side workaround for a runtime-side gap: exeris-spring-runtime exposes
 * {@code PersistenceEngineProvider} but no {@code TransactionalExecutor} bean. If the runtime
 * ever contributes one, delete this class and inject it directly — but re-verify that the
 * measured path did not change.
 */
@Configuration(proxyBeanMethods = false)
public class ExerisPersistenceConfiguration {

    @Bean
    public TransactionalExecutor exerisTransactionalExecutor(PersistenceEngineProvider provider) {
        return new TransactionOrchestrator(new ScopedPersistenceEngine(provider));
    }

    /**
     * Forwards every call to the request-scoped engine. Deliberately stateless — resolving the
     * provider per call is what keeps the ScopedValue binding correct.
     */
    private static final class ScopedPersistenceEngine implements PersistenceEngine {

        private final PersistenceEngineProvider provider;

        private ScopedPersistenceEngine(PersistenceEngineProvider provider) {
            this.provider = Objects.requireNonNull(provider, "provider must not be null");
        }

        private PersistenceEngine delegate() {
            PersistenceEngine engine = provider.get();
            if (engine == null) {
                throw new IllegalStateException(
                        "No PersistenceEngine bound on this thread. Kernel-native persistence must be "
                                + "invoked inside the kernel provider scope (request path or a scope-aware "
                                + "worker); see KernelProviderScope.");
            }
            return engine;
        }

        @Override
        public PersistenceConnection openConnection() {
            return delegate().openConnection();
        }

        @Override
        public PersistenceConnection openConnection(StorageContext storageContext) {
            return delegate().openConnection(storageContext);
        }

        @Override
        public PersistenceHealthStatus healthCheckDetailed() {
            return delegate().healthCheckDetailed();
        }

        @Override
        public void registerInterceptor(ConnectionInterceptor interceptor) {
            delegate().registerInterceptor(interceptor);
        }

        @Override
        public EngineStats stats() {
            return delegate().stats();
        }

        @Override
        public boolean canServiceRequest() {
            return delegate().canServiceRequest();
        }

        /**
         * No-op: the kernel owns the engine's lifecycle via ExerisRuntimeLifecycle. Closing it
         * from application code would tear down the shared pool underneath the runtime.
         */
        @Override
        public void close() {
            // intentionally empty
        }
    }
}
