package eu.exeris.kernel.benchmark.target.runtime.spi;

import eu.exeris.kernel.spi.http.HttpHandler;

import java.util.Optional;
import java.util.concurrent.atomic.AtomicReference;

public final class SpiCoreBenchmarkHttpBridgeRegistry {

    private static final AtomicReference<HttpHandler> CURRENT = new AtomicReference<>();

    private SpiCoreBenchmarkHttpBridgeRegistry() {
    }

    public static void install(HttpHandler handler) {
        CURRENT.set(handler);
    }

    public static Optional<HttpHandler> get() {
        return Optional.ofNullable(CURRENT.get());
    }

    public static void clear() {
        CURRENT.set(null);
    }
}