/*
 * Copyright (C) 2025-2026 Exeris Systems.
 * SPDX-License-Identifier: Apache-2.0
 */
package eu.exeris.benchmarks.targets.loomscheduler;

import eu.exeris.kernel.spi.http.HttpExchange;
import eu.exeris.kernel.spi.http.HttpHandler;
import eu.exeris.kernel.spi.http.HttpHeader;
import eu.exeris.kernel.spi.http.HttpMode;
import eu.exeris.kernel.spi.http.HttpStatus;
import eu.exeris.kernel.spi.memory.MemoryAllocator;

import java.nio.charset.StandardCharsets;
import java.util.List;
import java.util.Locale;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicReference;

/**
 * The server under test: an Exeris kernel HTTP/1.1 server whose {@code /backend} handler blocks
 * its virtual thread on a call to {@link MockBackend}.
 *
 * <ul>
 *   <li>{@code GET /plaintext} answers 200 with a fixed body, without leaving the handler.</li>
 *   <li>{@code GET /backend} makes one blocking {@code GET /mock} to the backend and answers 200
 *       with the backend's body length in decimal, or 502 when the call failed.</li>
 * </ul>
 *
 * <p>The virtual-thread scheduler is whatever the JVM is started with
 * ({@code -Djdk.virtualThreadScheduler.implClass}); this class does not choose it. The backend
 * client is chosen by {@code -Dloom.bench.backend}: {@code jdk} ({@link SocketBackend}) or
 * {@code kernel} ({@link KernelClientBackend}).
 */
public final class LoomSchedulerServer {

    static final int DEFAULT_PORT = 8080;
    static final int DEFAULT_POOL = 128;

    private static final byte[] PLAINTEXT = "Hello, World!".getBytes(StandardCharsets.US_ASCII);
    private static final List<HttpHeader> TEXT_HEADERS =
            List.of(new HttpHeader("content-type", "text/plain"));

    private LoomSchedulerServer() {
    }

    enum BackendKind { JDK, KERNEL }

    public static void main(String[] args) throws Exception {
        // Resolved before boot so that a misconfigured run fails without ever binding the port.
        BackendKind kind = backendKind(System.getProperty("loom.bench.backend"));
        String backendHost = System.getProperty("loom.bench.backend.host", "127.0.0.1");
        int backendPort = Integer.getInteger("loom.bench.backend.port", MockBackend.DEFAULT_PORT);
        int pool = Integer.getInteger("loom.bench.backend.pool", DEFAULT_POOL);
        int port = KernelHttp.port(DEFAULT_PORT);

        System.out.println("LOOM-BENCH pid=" + ProcessHandle.current().pid());
        System.out.println("LOOM-BENCH jdk=" + System.getProperty("java.vm.version"));
        System.out.println("LOOM-BENCH scheduler.implClass="
                + System.getProperty("jdk.virtualThreadScheduler.implClass", "<stock>")
                + " scheduler.parallelism="
                + System.getProperty("jdk.virtualThreadScheduler.parallelism", "<default>"));
        System.out.println("LOOM-BENCH jdk.pollerMode=" + System.getProperty("jdk.pollerMode", "<default>"));
        System.out.println("LOOM-BENCH exeris.carrier.count=" + System.getProperty("exeris.carrier.count", "<unset>")
                + " exeris.carrier.affinity=" + System.getProperty("exeris.carrier.affinity", "<unset>")
                + " exeris.transport.locality=" + System.getProperty("exeris.transport.locality", "<unset>")
                + " exeris.locality.allVthreads=" + System.getProperty("exeris.locality.allVthreads", "<unset>"));

        AtomicReference<Backend> backend = new AtomicReference<>();
        HttpMode mode = kind == BackendKind.KERNEL ? HttpMode.DUAL : HttpMode.SERVER;
        KernelHttp.serve(mode, allocator -> {
            Backend b = switch (kind) {
                case JDK -> new SocketBackend(backendHost, backendPort, pool);
                case KERNEL -> new KernelClientBackend(allocator, backendHost, backendPort);
            };
            backend.set(b);
            System.out.println("LOOM-BENCH backend=" + b.describe());
            return handler(allocator, b);
        }, "LOOM-BENCH READY port=" + port, () -> {
            Backend b = backend.get();
            if (b != null) {
                b.close();
            }
        });
    }

    static BackendKind backendKind(String value) {
        if (value == null || value.isBlank()) {
            throw new IllegalArgumentException("-Dloom.bench.backend is required: jdk or kernel");
        }
        return switch (value.trim().toLowerCase(Locale.ROOT)) {
            case "jdk" -> BackendKind.JDK;
            case "kernel" -> BackendKind.KERNEL;
            default -> throw new IllegalArgumentException(
                    "-Dloom.bench.backend must be jdk or kernel, was '" + value + "'");
        };
    }

    private static HttpHandler handler(MemoryAllocator allocator, Backend backend) {
        AtomicBoolean reported = new AtomicBoolean();
        AtomicBoolean failureReported = new AtomicBoolean();
        return exchange -> {
            if (!reported.get() && reported.compareAndSet(false, true)) {
                // The measurement assumes handlers run on virtual threads; say so once, from the
                // first handler that runs, rather than assume it.
                Thread t = Thread.currentThread();
                System.out.println("LOOM-BENCH handler thread virtual=" + t.isVirtual() + " name=" + t);
            }
            String path = exchange.request().path();
            switch (path) {
                case "/plaintext" -> KernelHttp.respondBytes(exchange, allocator, TEXT_HEADERS, PLAINTEXT);
                case "/backend" -> callBackend(exchange, allocator, backend, failureReported);
                default -> exchange.respond(HttpStatus.NOT_FOUND);
            }
        };
    }

    // Exceptions from the backend are mapped to 502 and counted by the load generator as non-2xx.
    // The first one is printed so that a failing run shows its cause instead of only a count.
    @SuppressWarnings("PMD.AvoidCatchingGenericException")
    private static void callBackend(HttpExchange exchange, MemoryAllocator allocator, Backend backend,
                                    AtomicBoolean failureReported) {
        int length;
        try {
            length = backend.fetch();
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
            exchange.respond(HttpStatus.BAD_GATEWAY);
            return;
        } catch (Exception e) {
            if (failureReported.compareAndSet(false, true)) {
                System.err.println("LOOM-BENCH first backend failure: " + e);
            }
            exchange.respond(HttpStatus.BAD_GATEWAY);
            return;
        }
        KernelHttp.respondDecimal(exchange, allocator, TEXT_HEADERS, length);
    }
}
