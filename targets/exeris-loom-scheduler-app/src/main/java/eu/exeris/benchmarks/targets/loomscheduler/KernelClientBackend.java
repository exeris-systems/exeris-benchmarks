/*
 * Copyright (C) 2025-2026 Exeris Systems.
 * SPDX-License-Identifier: Apache-2.0
 */
package eu.exeris.benchmarks.targets.loomscheduler;

import eu.exeris.kernel.core.http.client.KernelWebClient;
import eu.exeris.kernel.spi.http.HttpClientEngine;
import eu.exeris.kernel.spi.http.HttpKernelProviders;
import eu.exeris.kernel.spi.http.HttpRequestBodyEncoderRegistry;
import eu.exeris.kernel.spi.http.HttpResponseBodyDecoder;
import eu.exeris.kernel.spi.http.HttpResponseBodyDecoderRegistry;
import eu.exeris.kernel.spi.http.HttpResponseDecodingContext;
import eu.exeris.kernel.spi.memory.LoanedBuffer;
import eu.exeris.kernel.spi.memory.MemoryAllocator;

import java.util.List;

/**
 * Calls the mock backend through the kernel's own HTTP client ({@link KernelWebClient} over the
 * Community client engine), so the outbound wait goes through the kernel transport rather than the
 * JDK poller.
 *
 * <p>The engine is the one the kernel binds in {@code DUAL} mode; it keeps its own keep-alive pool
 * per peer, whose size follows the kernel's HTTP configuration, not {@code loom.bench.backend.pool}.
 */
final class KernelClientBackend implements Backend {

    private final KernelWebClient client;
    private final String authority;

    /**
     * Must be called inside the booted kernel scope: the client engine and the allocator are
     * the kernel's bindings there.
     */
    KernelClientBackend(MemoryAllocator allocator, String host, int port) {
        HttpClientEngine engine = HttpKernelProviders.httpClientEngine()
                .orElseThrow(() -> new IllegalStateException(
                        "the kernel bound no HTTP client engine; exeris.http.mode must be DUAL"));
        this.authority = host + ":" + port;
        this.client = new KernelWebClient(
                engine,
                allocator,
                HttpRequestBodyEncoderRegistry.of(List.of()),
                HttpResponseBodyDecoderRegistry.of(List.of(new BodyLength())))
                .withAuthority(authority);
    }

    @Override
    public int fetch() {
        Integer length = client.get("/mock", Integer.class);
        return length == null ? 0 : length;
    }

    @Override
    public String describe() {
        return "kernel(KernelWebClient) target=" + authority;
    }

    @Override
    public void close() {
        // The engine belongs to the kernel and closes with it.
    }

    /**
     * Answers a request for {@code Integer} with the body's size, so the response is read in full
     * but not decoded: the benchmark measures the call, not a JSON parser.
     */
    private static final class BodyLength implements HttpResponseBodyDecoder {

        @Override
        public boolean supports(Class<?> targetType, String contentType) {
            return targetType == Integer.class;
        }

        @Override
        public Object decode(LoanedBuffer body, Class<?> targetType, HttpResponseDecodingContext context) {
            return Math.toIntExact(body.size());
        }
    }
}
