/*
 * Copyright (C) 2025-2026 Exeris Systems.
 * SPDX-License-Identifier: Apache-2.0
 */
package eu.exeris.benchmarks.targets.loomscheduler;

import eu.exeris.kernel.spi.http.HttpHandler;
import eu.exeris.kernel.spi.http.HttpHeader;
import eu.exeris.kernel.spi.http.HttpMode;
import eu.exeris.kernel.spi.http.HttpStatus;
import eu.exeris.kernel.spi.memory.MemoryAllocator;

import java.nio.charset.StandardCharsets;
import java.time.Duration;
import java.util.List;

/**
 * The backend the server under test calls: {@code GET /mock} answers a fixed JSON document after
 * a think time.
 *
 * <p>Runs in its own JVM on the stock virtual-thread scheduler, so whatever scheduler the server
 * under test uses, the backend's latency is not a function of it. The think time is a sleep on
 * the request's virtual thread: it holds no carrier, so the backend's capacity is bounded by its
 * request rate, not by the think time times its carrier count.
 *
 * <p>System properties: {@code exeris.http.port} (default 9090), {@code exeris.http.bindHost}
 * (default {@code 0.0.0.0}), {@code loom.bench.mock.thinkMs} (default 1, fractional allowed,
 * 0 answers at once). Its carrier count is the stock scheduler's,
 * {@code -Djdk.virtualThreadScheduler.parallelism}.
 */
public final class MockBackend {

    static final int DEFAULT_PORT = 9090;

    static final byte[] BODY = """
            {"fruits":[{"name":"Apple","color":"Red","price":1.20},\
            {"name":"Banana","color":"Yellow","price":0.50}]}""".getBytes(StandardCharsets.US_ASCII);

    private static final List<HttpHeader> JSON_HEADERS =
            List.of(new HttpHeader("content-type", "application/json"));

    private MockBackend() {
    }

    public static void main(String[] args) throws Exception {
        int port = KernelHttp.port(DEFAULT_PORT);
        double thinkMs = Double.parseDouble(System.getProperty("loom.bench.mock.thinkMs", "1"));
        if (!(thinkMs >= 0)) {
            throw new IllegalArgumentException("loom.bench.mock.thinkMs must be >= 0, was " + thinkMs);
        }
        Duration think = Duration.ofNanos(Math.round(thinkMs * 1_000_000d));

        System.out.println("LOOM-MOCK pid=" + ProcessHandle.current().pid()
                + " thinkMs=" + thinkMs
                + " bodyBytes=" + BODY.length
                + " scheduler.implClass=" + System.getProperty("jdk.virtualThreadScheduler.implClass", "<stock>")
                + " scheduler.parallelism="
                + System.getProperty("jdk.virtualThreadScheduler.parallelism", "<default>"));

        KernelHttp.serve(HttpMode.SERVER, allocator -> handler(allocator, think),
                "LOOM-MOCK READY port=" + port, null);
    }

    private static HttpHandler handler(MemoryAllocator allocator, Duration think) {
        boolean sleeps = !think.isZero();
        return exchange -> {
            if (!"/mock".equals(exchange.request().path())) {
                exchange.respond(HttpStatus.NOT_FOUND);
                return;
            }
            if (sleeps) {
                try {
                    Thread.sleep(think);
                } catch (InterruptedException _) {
                    Thread.currentThread().interrupt();
                    exchange.respond(HttpStatus.SERVICE_UNAVAILABLE);
                    return;
                }
            }
            KernelHttp.respondBytes(exchange, allocator, JSON_HEADERS, BODY);
        };
    }
}
