package eu.exeris.kernel.benchmark.target.runtime.spi;

import eu.exeris.kernel.benchmark.target.api.BenchmarkLifecycle;
import eu.exeris.kernel.benchmark.target.bootstrap.spi.SpiCoreConfigKeys;
import eu.exeris.kernel.core.bootstrap.KernelBootstrap;
import eu.exeris.kernel.spi.bootstrap.BootstrapSelector;
import eu.exeris.kernel.spi.context.KernelProviders;
import eu.exeris.kernel.spi.http.HttpKernelProviders;

import java.util.Map;
import java.util.Objects;
import java.util.LinkedHashMap;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicReference;

public final class SpiCoreBenchmarkLifecycle implements BenchmarkLifecycle {

    private static final long STARTUP_TIMEOUT_SECONDS = 30;

    private final BootstrapSelector selector;
    private final Map<String, String> config;
    private final SpiCoreSeedExecutionState seedState;
    private final eu.exeris.kernel.benchmark.target.seed.BenchmarkSeedPlan seedPlan;
    private final SpiCorePhysicalBenchmarkSeeder physicalSeeder = new SpiCorePhysicalBenchmarkSeeder();
    private final CountDownLatch startupSignal = new CountDownLatch(1);
    private final CountDownLatch stopSignal = new CountDownLatch(1);
    private final AtomicBoolean initialized = new AtomicBoolean(false);
    private final AtomicBoolean shutdownRequested = new AtomicBoolean(false);
    private final AtomicBoolean ready = new AtomicBoolean(false);
    private final AtomicBoolean httpBound = new AtomicBoolean(false);
    private final AtomicBoolean persistenceBound = new AtomicBoolean(false);
    private final AtomicReference<Throwable> failure = new AtomicReference<>();
    private final Map<String, String> previousBootstrapProperties = new LinkedHashMap<>();
    private final Object propertyLock = new Object();
    private final AtomicBoolean bootstrapPropertiesApplied = new AtomicBoolean(false);
    private final AtomicBoolean bootstrapPropertiesRestored = new AtomicBoolean(false);

    private volatile Thread bootThread;

    public SpiCoreBenchmarkLifecycle(
            BootstrapSelector selector,
            Map<String, String> config,
            eu.exeris.kernel.benchmark.target.seed.BenchmarkSeedPlan seedPlan,
            SpiCoreSeedExecutionState seedState) {
        this.selector = Objects.requireNonNull(selector, "selector");
        this.config = Map.copyOf(Objects.requireNonNull(config, "config"));
        this.seedPlan = Objects.requireNonNull(seedPlan, "seedPlan");
        this.seedState = Objects.requireNonNull(seedState, "seedState");
    }

    @Override
    public void initialize() {
        if (!initialized.compareAndSet(false, true)) {
            return;
        }

        applyBootstrapProperties();
        bootThread = new Thread(this::bootKernel, "benchmark-target-spi-core");
        bootThread.start();

        try {
            if (!startupSignal.await(STARTUP_TIMEOUT_SECONDS, TimeUnit.SECONDS)) {
                shutdown();
                throw new IllegalStateException(
                        "Timed out waiting for SPI+CORE benchmark runtime startup after "
                                + STARTUP_TIMEOUT_SECONDS + "s");
            }
        } catch (InterruptedException interrupted) {
            Thread.currentThread().interrupt();
            shutdown();
            throw new IllegalStateException("Interrupted while waiting for SPI+CORE benchmark runtime startup",
                    interrupted);
        }

        Throwable startupFailure = failure.get();
        if (startupFailure != null) {
            shutdown();
            throw new IllegalStateException("Failed to initialize SPI+CORE benchmark runtime", startupFailure);
        }
    }

    @Override
    public void shutdown() {
        if (!shutdownRequested.compareAndSet(false, true)) {
            return;
        }

        try {
            stopSignal.countDown();
            Thread thread = bootThread;
            if (thread != null && Thread.currentThread() != thread) {
                try {
                    thread.join(TimeUnit.SECONDS.toMillis(STARTUP_TIMEOUT_SECONDS));
                } catch (InterruptedException interrupted) {
                    Thread.currentThread().interrupt();
                    throw new IllegalStateException("Interrupted while stopping SPI+CORE benchmark runtime",
                            interrupted);
                }
            }
        } finally {
            restoreBootstrapProperties();
        }
    }

    @Override
    public boolean isReady() {
        return ready.get();
    }

    public void awaitShutdown() {
        Thread thread = bootThread;
        if (thread == null) {
            return;
        }
        try {
            thread.join();
        } catch (InterruptedException interrupted) {
            Thread.currentThread().interrupt();
            throw new IllegalStateException("Interrupted while waiting for SPI+CORE benchmark runtime shutdown",
                    interrupted);
        }
        Throwable startupFailure = failure.get();
        if (startupFailure != null) {
            throw new IllegalStateException("SPI+CORE benchmark runtime terminated with bootstrap failure",
                    startupFailure);
        }
    }

    public boolean isHttpBound() {
        return httpBound.get();
    }

    public boolean isPersistenceBound() {
        return persistenceBound.get();
    }

    public eu.exeris.kernel.benchmark.target.seed.BenchmarkSeedResult currentSeedResult() {
        return seedState.current();
    }

    private void bootKernel() {
        try {
            KernelBootstrap.builder()
                    .selector(selector)
                    .build()
                    .boot(this::runUntilStopped);
        } catch (KernelBootstrap.BootstrapException | RuntimeException exception) {
            failure.compareAndSet(null, exception);
            startupSignal.countDown();
        } finally {
            ready.set(false);
        }
    }

    private void runUntilStopped() {
        try {
            httpBound.set(HttpKernelProviders.HTTP_SERVER_ENGINE.isBound());
            persistenceBound.set(KernelProviders.PERSISTENCE_ENGINE.isBound());

            boolean persistenceSelected = selector.includes("persistence");
            if (persistenceSelected && !persistenceBound.get()) {
                throw new IllegalStateException(
                        "Persistence subsystem is selected but no PersistenceEngine is bound for phase-5 seeding");
            }
            seedState.update(physicalSeeder.seed(
                    seedPlan,
                    seedState.current(),
                    persistenceSelected,
                    persistenceBound.get()));

            ready.set(httpBound.get() && (!persistenceSelected || persistenceBound.get()));
            startupSignal.countDown();
        } catch (RuntimeException runtimeException) {
            failure.compareAndSet(null, runtimeException);
            startupSignal.countDown();
            throw runtimeException;
        }

        try {
            stopSignal.await();
        } catch (InterruptedException interrupted) {
            Thread.currentThread().interrupt();
        } finally {
            ready.set(false);
            SpiCoreBenchmarkHttpBridgeRegistry.clear();
        }
    }

    private void applyBootstrapProperties() {
        if (!bootstrapPropertiesApplied.compareAndSet(false, true)) {
            return;
        }

        setPropertyIfPresent(SpiCoreConfigKeys.PROP_SUBSYSTEMS);
        setPropertyIfPresent(SpiCoreConfigKeys.PROP_HTTP_BIND_HOST);
        setPropertyIfPresent(SpiCoreConfigKeys.PROP_HTTP_PORT);
        setProperty(
                SpiCoreConfigKeys.PROP_HTTP_MODE,
                config.getOrDefault(SpiCoreConfigKeys.PROP_HTTP_MODE, SpiCoreConfigKeys.DEFAULT_HTTP_MODE));
        setPropertyIfPresent(SpiCoreConfigKeys.PROP_PERSISTENCE_JDBC_URL);
    }

    private void setPropertyIfPresent(String key) {
        String value = config.get(key);
        if (value != null && !value.isBlank()) {
            setProperty(key, value);
        }
    }

    private void setProperty(String key, String value) {
        synchronized (propertyLock) {
            if (!previousBootstrapProperties.containsKey(key)) {
                previousBootstrapProperties.put(key, System.getProperty(key));
            }
            System.setProperty(key, value);
        }
    }

    private void restoreBootstrapProperties() {
        if (!bootstrapPropertiesRestored.compareAndSet(false, true)) {
            return;
        }

        synchronized (propertyLock) {
            previousBootstrapProperties.forEach((key, previousValue) -> {
                if (previousValue == null) {
                    System.clearProperty(key);
                } else {
                    System.setProperty(key, previousValue);
                }
            });
        }
    }
}