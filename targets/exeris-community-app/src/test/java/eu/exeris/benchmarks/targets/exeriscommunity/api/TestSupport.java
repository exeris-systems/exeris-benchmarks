package eu.exeris.benchmarks.targets.exeriscommunity.api;

import eu.exeris.kernel.spi.http.HttpExchange;
import eu.exeris.kernel.spi.http.HttpMethod;
import eu.exeris.kernel.spi.http.HttpHeader;
import eu.exeris.kernel.spi.http.HttpRequest;
import eu.exeris.kernel.spi.http.HttpResponse;
import eu.exeris.kernel.spi.http.HttpTypedResponse;
import eu.exeris.kernel.spi.http.HttpVersion;
import eu.exeris.kernel.spi.memory.AllocationHint;
import eu.exeris.kernel.spi.memory.LoanedBuffer;
import eu.exeris.kernel.spi.memory.MemoryAllocator;
import eu.exeris.kernel.spi.memory.MemoryStats;
import tools.jackson.core.JacksonException;
import tools.jackson.databind.ObjectMapper;

import java.lang.foreign.MemorySegment;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.concurrent.atomic.AtomicInteger;

final class TestSupport {

    private TestSupport() {
    }

    static final class FakeLoanedBuffer implements LoanedBuffer {

        private final byte[] bytes;
        private final MemorySegment segment;
        private final List<Runnable> closeActions = new ArrayList<>();
        private final AtomicInteger refCount = new AtomicInteger(1);
        private long size;
        private int closeCount;
        private boolean alive = true;

        FakeLoanedBuffer(int capacity) {
            this.bytes = new byte[capacity];
            this.segment = MemorySegment.ofArray(bytes);
            this.size = 0;
        }

        int closeCount() {
            return closeCount;
        }

        @Override
        public MemorySegment segment() {
            return segment;
        }

        @Override
        public long size() {
            return size;
        }

        @Override
        public long capacity() {
            return bytes.length;
        }

        @Override
        public LoanedBuffer slice(long offset, long length) {
            return this;
        }

        @Override
        public LoanedBuffer view() {
            return this;
        }

        @Override
        public LoanedBuffer peek(long offset, long length) {
            return this;
        }

        @Override
        public void retain() {
            if (!alive) {
                throw new IllegalStateException("Buffer already closed");
            }
            refCount.incrementAndGet();
        }

        @Override
        public void close() {
            closeCount++;
            int refs = refCount.decrementAndGet();
            if (refs <= 0 && alive) {
                alive = false;
                for (Runnable closeAction : closeActions) {
                    closeAction.run();
                }
            }
        }

        @Override
        public int refCount() {
            return refCount.get();
        }

        @Override
        public void setSize(long newSize) {
            if (newSize < 0 || newSize > bytes.length) {
                throw new IllegalArgumentException("size out of bounds");
            }
            this.size = newSize;
        }

        @Override
        public boolean isAlive() {
            return alive;
        }

        @Override
        public void addCloseAction(Runnable action) {
            closeActions.add(action);
        }
    }

    static final class CapturingAllocator implements MemoryAllocator {

        private FakeLoanedBuffer lastAllocated;

        FakeLoanedBuffer lastAllocated() {
            return lastAllocated;
        }

        @Override
        public LoanedBuffer allocate(AllocationHint hint) {
            int size = hint != null ? hint.sizeBytes() : 1024;
            lastAllocated = new FakeLoanedBuffer(size);
            return lastAllocated;
        }

        @Override
        public LoanedBuffer allocateNetwork(int sizeBytes) {
            lastAllocated = new FakeLoanedBuffer(sizeBytes);
            return lastAllocated;
        }

        @Override
        public LoanedBuffer allocateCarrierSlab(int sizeBytes) {
            lastAllocated = new FakeLoanedBuffer(sizeBytes);
            return lastAllocated;
        }

        @Override
        public LoanedBuffer allocateInfrastructure(long bytes) {
            int size = Math.toIntExact(bytes);
            lastAllocated = new FakeLoanedBuffer(size);
            return lastAllocated;
        }

        @Override
        public MemoryStats stats() {
            return MemoryStats.zero();
        }

        @Override
        public void close() {
        }
    }

    static final class CapturingExchange implements HttpExchange {

        private final HttpRequest request;
        private HttpResponse response;

        CapturingExchange(HttpRequest request) {
            this.request = request;
        }

        static CapturingExchange get(String path) {
            return new CapturingExchange(HttpRequest.noBody(
                eu.exeris.kernel.spi.http.HttpMethod.GET,
                path,
                HttpVersion.HTTP_1_1,
                List.of()
            ));
        }

        @Override
        public HttpRequest request() {
            return request;
        }

        @Override
        public void respond(HttpResponse response) {
            this.response = response;
        }

        HttpResponse response() {
            return response;
        }
    }

    static final class AsyncCapturingExchange implements HttpExchange {

        private static final ObjectMapper OBJECT_MAPPER = new ObjectMapper();

        private final HttpRequest request;
        private final MemoryAllocator allocator;
        private HttpResponse response;

        AsyncCapturingExchange(HttpRequest request, MemoryAllocator allocator) {
            this.request = request;
            this.allocator = allocator;
        }

        static AsyncCapturingExchange get(String path) {
            return new AsyncCapturingExchange(HttpRequest.noBody(
                eu.exeris.kernel.spi.http.HttpMethod.GET,
                path,
                HttpVersion.HTTP_1_1,
                List.of()
            ), null);
        }

        static AsyncCapturingExchange get(String path, MemoryAllocator allocator) {
            return new AsyncCapturingExchange(HttpRequest.noBody(
                eu.exeris.kernel.spi.http.HttpMethod.GET,
                path,
                HttpVersion.HTTP_1_1,
                List.of()
            ), allocator);
        }

        static AsyncCapturingExchange get(String path, Map<String, String> headers, MemoryAllocator allocator) {
            return new AsyncCapturingExchange(HttpRequest.noBody(
                HttpMethod.GET,
                path,
                HttpVersion.HTTP_1_1,
                toHeaders(headers)
            ), allocator);
        }

        static AsyncCapturingExchange postJson(String path,
                                               String jsonPayload,
                                               Map<String, String> headers,
                                               MemoryAllocator allocator) {
            byte[] payload = jsonPayload.getBytes(java.nio.charset.StandardCharsets.UTF_8);
            FakeLoanedBuffer body = new FakeLoanedBuffer(payload.length);
            MemorySegment.copy(MemorySegment.ofArray(payload), 0, body.segment(), 0, payload.length);
            body.setSize(payload.length);

            List<HttpHeader> allHeaders = new ArrayList<>(toHeaders(headers));
            allHeaders.add(new HttpHeader("content-type", "application/json"));

            return new AsyncCapturingExchange(new HttpRequest(
                HttpMethod.POST,
                path,
                HttpVersion.HTTP_1_1,
                List.copyOf(allHeaders),
                body
            ), allocator);
        }

        @Override
        public HttpRequest request() {
            return request;
        }

        @Override
        public void respond(HttpResponse response) {
            this.response = response;
        }

        @Override
        public void respond(HttpTypedResponse typedResponse) {
            if (allocator == null || typedResponse.payload() == null) {
                respond(HttpResponse.noBody(typedResponse.status(), request.version()));
                return;
            }
            try {
                byte[] bytes = OBJECT_MAPPER.writeValueAsBytes(typedResponse.payload());
                LoanedBuffer buf = allocator.allocateNetwork(bytes.length);
                java.lang.foreign.MemorySegment.copy(
                    java.lang.foreign.MemorySegment.ofArray(bytes), 0,
                    buf.segment(), 0, bytes.length);
                buf.setSize(bytes.length);
                respond(new HttpResponse(
                    typedResponse.status(),
                    request.version(),
                    List.of(new HttpHeader("content-type", "application/json")),
                    buf));
            } catch (JacksonException e) {
                throw new IllegalStateException("JSON serialization failed", e);
            }
        }

        HttpResponse response() {
            return response;
        }

        void consumeBody() {
            if (response != null && response.hasBody()) {
                response.body().close();
            }
        }

        private static List<HttpHeader> toHeaders(Map<String, String> headers) {
            if (headers == null || headers.isEmpty()) {
                return List.of();
            }
            List<HttpHeader> result = new ArrayList<>(headers.size());
            for (Map.Entry<String, String> entry : headers.entrySet()) {
                result.add(new HttpHeader(entry.getKey(), entry.getValue()));
            }
            return List.copyOf(result);
        }
    }
}
