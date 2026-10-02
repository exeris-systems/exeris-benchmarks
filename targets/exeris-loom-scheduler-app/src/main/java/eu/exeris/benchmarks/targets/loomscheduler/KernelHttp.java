/*
 * Copyright (C) 2025-2026 Exeris Systems.
 * SPDX-License-Identifier: Apache-2.0
 */
package eu.exeris.benchmarks.targets.loomscheduler;

import eu.exeris.kernel.core.bootstrap.KernelBootstrap;
import eu.exeris.kernel.spi.bootstrap.BootstrapSelector;
import eu.exeris.kernel.spi.context.KernelProviders;
import eu.exeris.kernel.spi.http.HttpExchange;
import eu.exeris.kernel.spi.http.HttpHandler;
import eu.exeris.kernel.spi.http.HttpHeader;
import eu.exeris.kernel.spi.http.HttpKernelProviders;
import eu.exeris.kernel.spi.http.HttpMode;
import eu.exeris.kernel.spi.http.HttpResponse;
import eu.exeris.kernel.spi.http.HttpStatus;
import eu.exeris.kernel.spi.memory.LoanedBuffer;
import eu.exeris.kernel.spi.memory.MemoryAllocator;

import java.lang.foreign.MemorySegment;
import java.lang.foreign.ValueLayout;
import java.util.List;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.atomic.AtomicReference;
import java.util.function.Function;

/**
 * Boots an Exeris kernel HTTP/1.1 engine and writes small fixed responses from off-heap buffers.
 *
 * <p>Both processes of the benchmark boot through here so that the server under test and the mock
 * backend differ only in their handler and in the JVM flags they are started with.
 */
final class KernelHttp {

    static final String SUBSYSTEMS = "memory,transport,http";

    private static final int DECIMAL_DIGITS_MAX = 10;

    private KernelHttp() {
    }

    /**
     * Boots the kernel and serves until the JVM receives a shutdown signal.
     *
     * <p>The kernel reads its handler from a scoped value bound before boot, but the allocator and
     * client engine a real handler needs exist only inside the booted scope. A forwarding handler
     * bridges the two: it is bound before boot and delegates to the handler {@code factory} builds
     * once the kernel is up. Until then it answers 503, so a probe that arrives during boot is told
     * so rather than served by a half-built handler.
     *
     * @param mode       {@link HttpMode#SERVER}, or {@link HttpMode#DUAL} when the handler sends
     *                   outbound requests through the kernel's client engine
     * @param factory    builds the handler inside the booted scope
     * @param readyLine  printed once the handler is installed and the port is listening
     * @param onShutdown run after the kernel has stopped serving; may be {@code null}
     */
    static void serve(HttpMode mode, Function<MemoryAllocator, HttpHandler> factory,
                      String readyLine, Runnable onShutdown) throws Exception {
        System.setProperty("exeris.launcher.subsystems", SUBSYSTEMS);
        System.setProperty("exeris.http.mode", mode.name());
        System.setProperty("exeris.http.maxVersion", "HTTP_1_1");
        System.setProperty("exeris.http.h2cUpgradeEnabled", "false");
        // The transport subsystem brings the crypto subsystem with it, and with a crypto provider
        // bound the kernel's client dials TLS by default. Every hop in this benchmark is plaintext
        // HTTP/1.1, so TLS is declined for the whole kernel rather than left to the defaults.
        System.setProperty("exeris.transport.tls", "false");

        AtomicReference<HttpHandler> installed = new AtomicReference<>();
        HttpHandler forwarding = exchange -> {
            HttpHandler handler = installed.get();
            if (handler == null) {
                exchange.respond(HttpStatus.SERVICE_UNAVAILABLE);
            } else {
                handler.handle(exchange);
            }
        };

        CountDownLatch stop = new CountDownLatch(1);
        Runtime.getRuntime().addShutdownHook(new Thread(stop::countDown, "loom-bench-shutdown"));

        try {
            ScopedValue.where(HttpKernelProviders.HTTP_SERVER_HANDLER, forwarding).call(() -> {
                KernelBootstrap.builder()
                        .selector(BootstrapSelector.forNames(SUBSYSTEMS.split(",")))
                        .build()
                        .boot(() -> {
                            installed.set(factory.apply(KernelProviders.MEMORY_ALLOCATOR.get()));
                            System.out.println(readyLine);
                            System.out.flush();
                            try {
                                stop.await();
                            } catch (InterruptedException _) {
                                Thread.currentThread().interrupt();
                            }
                        });
                return null;
            });
        } finally {
            if (onShutdown != null) {
                onShutdown.run();
            }
        }
    }

    /** The port the kernel binds: {@code -Dexeris.http.port}, or {@code defaultPort}. */
    static int port(int defaultPort) {
        int port = Integer.getInteger("exeris.http.port", defaultPort);
        System.setProperty("exeris.http.port", Integer.toString(port));
        return port;
    }

    /** Responds 200 with a copy of {@code body}. */
    static void respondBytes(HttpExchange exchange, MemoryAllocator allocator,
                             List<HttpHeader> headers, byte[] body) {
        LoanedBuffer buffer = allocator.allocateNetwork(body.length);
        try {
            MemorySegment.copy(MemorySegment.ofArray(body), 0L, buffer.segment(), 0L, body.length);
            buffer.setSize(body.length);
            exchange.respond(new HttpResponse(HttpStatus.OK, exchange.request().version(), headers, buffer));
        } catch (RuntimeException e) {
            buffer.close();
            throw e;
        }
    }

    /**
     * Responds 200 with the decimal form of {@code value}, written straight into the network
     * buffer so the hot path builds no String.
     */
    static void respondDecimal(HttpExchange exchange, MemoryAllocator allocator,
                               List<HttpHeader> headers, int value) {
        if (value < 0) {
            throw new IllegalArgumentException("value must be non-negative: " + value);
        }
        LoanedBuffer buffer = allocator.allocateNetwork(DECIMAL_DIGITS_MAX);
        try {
            int digits = 1;
            for (int v = value / 10; v > 0; v /= 10) {
                digits++;
            }
            MemorySegment segment = buffer.segment();
            int v = value;
            for (int i = digits - 1; i >= 0; i--) {
                segment.set(ValueLayout.JAVA_BYTE, i, (byte) ('0' + v % 10));
                v /= 10;
            }
            buffer.setSize(digits);
            exchange.respond(new HttpResponse(HttpStatus.OK, exchange.request().version(), headers, buffer));
        } catch (RuntimeException e) {
            buffer.close();
            throw e;
        }
    }
}
