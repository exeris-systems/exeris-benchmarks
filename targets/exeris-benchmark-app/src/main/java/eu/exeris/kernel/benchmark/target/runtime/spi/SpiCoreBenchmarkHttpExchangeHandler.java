package eu.exeris.kernel.benchmark.target.runtime.spi;

import eu.exeris.kernel.benchmark.target.api.BenchmarkHttpServer;
import eu.exeris.kernel.benchmark.target.http.BenchmarkResponse;
import eu.exeris.kernel.benchmark.target.http.SimpleBenchmarkRequestContext;
import eu.exeris.kernel.spi.http.HttpExchange;
import eu.exeris.kernel.spi.http.HttpHandler;
import eu.exeris.kernel.spi.http.HttpHeader;
import eu.exeris.kernel.spi.http.HttpRequest;
import eu.exeris.kernel.spi.http.HttpResponse;
import eu.exeris.kernel.spi.http.HttpStatus;
import eu.exeris.kernel.spi.http.HttpVersion;
import eu.exeris.kernel.spi.memory.LoanedBuffer;

import java.io.IOException;
import java.lang.foreign.MemorySegment;
import java.lang.foreign.ValueLayout;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Objects;
import java.util.Optional;
import java.util.logging.Logger;

public final class SpiCoreBenchmarkHttpExchangeHandler implements HttpHandler {

    private static final Logger LOG = Logger.getLogger(SpiCoreBenchmarkHttpExchangeHandler.class.getName());

    private final BenchmarkHttpServer benchmarkHttpServer;

    public SpiCoreBenchmarkHttpExchangeHandler(BenchmarkHttpServer benchmarkHttpServer) {
        this.benchmarkHttpServer = Objects.requireNonNull(benchmarkHttpServer, "benchmarkHttpServer");
    }

    @Override
    public void handle(HttpExchange exchange) {
        HttpRequest request = exchange.request();
        SimpleBenchmarkRequestContext context = toBenchmarkRequestContext(request);
        try {
            Optional<BenchmarkResponse> dispatched = benchmarkHttpServer.dispatch(context);
            if (dispatched.isEmpty()) {
                exchange.respond(HttpResponse.noBody(HttpStatus.NOT_FOUND, responseVersionFor(request)));
                return;
            }
            exchange.respond(toHttpResponse(dispatched.get(), responseVersionFor(request)));
        } catch (IOException | RuntimeException dispatchFailure) {
            LOG.warning("SPI HTTP bridge dispatch/response conversion failed: " + dispatchFailure);
            exchange.respond(HttpResponse.noBody(HttpStatus.INTERNAL_SERVER_ERROR, responseVersionFor(request)));
        }
    }

    private static SimpleBenchmarkRequestContext toBenchmarkRequestContext(HttpRequest request) {
        String fullPath = request.path();
        int queryIndex = fullPath.indexOf('?');
        String path = queryIndex >= 0 ? fullPath.substring(0, queryIndex) : fullPath;
        String query = queryIndex >= 0 && queryIndex + 1 < fullPath.length() ? fullPath.substring(queryIndex + 1) : "";

        Map<String, List<String>> headers = new LinkedHashMap<>();
        for (HttpHeader header : request.headers()) {
            String key = header.name().toLowerCase(Locale.ROOT);
            headers.computeIfAbsent(key, ignored -> new ArrayList<>()).add(header.value());
        }

        return new SimpleBenchmarkRequestContext(
                request.method().name(),
                path,
                headers,
                parseQueryParameters(query),
                readBodyBytes(request.body()));
    }

    private static Map<String, List<String>> parseQueryParameters(String query) {
        if (query == null || query.isBlank()) {
            return Map.of();
        }

        LinkedHashMap<String, List<String>> parsed = new LinkedHashMap<>();
        for (String token : query.split("&")) {
            if (token.isEmpty()) {
                continue;
            }
            int separator = token.indexOf('=');
            String key = separator >= 0 ? token.substring(0, separator) : token;
            String value = separator >= 0 ? token.substring(separator + 1) : "";
            parsed.computeIfAbsent(key, ignored -> new ArrayList<>()).add(value);
        }
        return Map.copyOf(parsed);
    }

    private static byte[] readBodyBytes(LoanedBuffer body) {
        if (body == null || body.size() == 0) {
            return new byte[0];
        }
        MemorySegment slice = body.segment().asSlice(0, body.size());
        return slice.toArray(ValueLayout.JAVA_BYTE);
    }

    private static HttpResponse toHttpResponse(BenchmarkResponse benchmarkResponse, HttpVersion version) {
        HttpStatus status = statusOf(benchmarkResponse.statusCode());
        List<HttpHeader> headers = toHttpHeaders(benchmarkResponse.headers(), benchmarkResponse.contentType());
        byte[] body = benchmarkResponse.body();
        if (status.code() == 204 || status.code() == 304 || body.length == 0) {
            return HttpResponse.noBody(status, version, headers);
        }
        return new HttpResponse(status, version, headers, new ByteArrayLoanedBuffer(body));
    }

    private static final class ByteArrayLoanedBuffer implements LoanedBuffer {
        private final byte[] bytes;
        private long size;

        private ByteArrayLoanedBuffer(byte[] body) {
            this.bytes = Objects.requireNonNull(body, "body");
            this.size = body.length;
        }

        @Override
        public MemorySegment segment() {
            return MemorySegment.ofArray(bytes);
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
            return viewOf(segment().asSlice(offset, length));
        }

        @Override
        public LoanedBuffer view() {
            return viewOf(segment().asSlice(0, size));
        }

        @Override
        public LoanedBuffer peek(long offset, long length) {
            return viewOf(segment().asSlice(offset, length));
        }

        @Override
        public void retain() {
            // No-op for byte[] backed immutable response bodies.
        }

        @Override
        public void close() {
            // No-op for GC-managed byte[] backed responses.
        }

        @Override
        public int refCount() {
            return 1;
        }

        @Override
        public void setSize(long newSize) {
            if (newSize < 0 || newSize > bytes.length) {
                throw new IllegalArgumentException("size out of bounds: " + newSize);
            }
            size = newSize;
        }

        @Override
        public boolean isAlive() {
            return true;
        }

        @Override
        public void addCloseAction(Runnable action) {
            // No-op for unmanaged byte[] backed responses.
        }

        private static LoanedBuffer viewOf(MemorySegment segment) {
            return new LoanedBuffer() {
                @Override
                public MemorySegment segment() {
                    return segment;
                }

                @Override
                public long size() {
                    return segment.byteSize();
                }

                @Override
                public long capacity() {
                    return segment.byteSize();
                }

                @Override
                public LoanedBuffer slice(long offset, long length) {
                    return viewOf(segment.asSlice(offset, length));
                }

                @Override
                public LoanedBuffer view() {
                    return this;
                }

                @Override
                public LoanedBuffer peek(long offset, long length) {
                    return viewOf(segment.asSlice(offset, length));
                }

                @Override
                public void retain() {
                }

                @Override
                public void close() {
                }

                @Override
                public int refCount() {
                    return 1;
                }

                @Override
                public void setSize(long size) {
                    throw new UnsupportedOperationException("read-only view");
                }

                @Override
                public boolean isAlive() {
                    return true;
                }

                @Override
                public void addCloseAction(Runnable action) {
                }
            };
        }
    }

    private static List<HttpHeader> toHttpHeaders(Map<String, List<String>> source, String contentType) {
        List<HttpHeader> headers = new ArrayList<>();
        boolean hasContentType = false;

        for (Map.Entry<String, List<String>> entry : source.entrySet()) {
            String name = entry.getKey();
            if (name.equalsIgnoreCase("content-type")) {
                hasContentType = true;
            }
            for (String value : entry.getValue()) {
                headers.add(new HttpHeader(name, value));
            }
        }

        if (!hasContentType && contentType != null && !contentType.isBlank()) {
            headers.add(new HttpHeader("content-type", contentType));
        }
        return List.copyOf(headers);
    }

    private static HttpStatus statusOf(int code) {
        return switch (code) {
            case 200 -> HttpStatus.OK;
            case 201 -> HttpStatus.CREATED;
            case 202 -> HttpStatus.ACCEPTED;
            case 204 -> HttpStatus.NO_CONTENT;
            case 301 -> HttpStatus.MOVED_PERMANENTLY;
            case 302 -> HttpStatus.FOUND;
            case 304 -> HttpStatus.NOT_MODIFIED;
            case 307 -> HttpStatus.TEMPORARY_REDIRECT;
            case 308 -> HttpStatus.PERMANENT_REDIRECT;
            case 400 -> HttpStatus.BAD_REQUEST;
            case 401 -> HttpStatus.UNAUTHORIZED;
            case 403 -> HttpStatus.FORBIDDEN;
            case 404 -> HttpStatus.NOT_FOUND;
            case 405 -> HttpStatus.METHOD_NOT_ALLOWED;
            case 408 -> HttpStatus.REQUEST_TIMEOUT;
            case 409 -> HttpStatus.CONFLICT;
            case 410 -> HttpStatus.GONE;
            case 413 -> HttpStatus.CONTENT_TOO_LARGE;
            case 414 -> HttpStatus.URI_TOO_LONG;
            case 429 -> HttpStatus.TOO_MANY_REQUESTS;
            case 431 -> HttpStatus.REQUEST_HEADER_FIELDS_TOO_LARGE;
            case 500 -> HttpStatus.INTERNAL_SERVER_ERROR;
            case 501 -> HttpStatus.NOT_IMPLEMENTED;
            case 502 -> HttpStatus.BAD_GATEWAY;
            case 503 -> HttpStatus.SERVICE_UNAVAILABLE;
            case 504 -> HttpStatus.GATEWAY_TIMEOUT;
            case 505 -> HttpStatus.HTTP_VERSION_NOT_SUPPORTED;
            default -> new HttpStatus(code, "benchmark-response");
        };
    }

    private static HttpVersion responseVersionFor(HttpRequest request) {
        HttpVersion version = request.version();
        return version == null ? HttpVersion.HTTP_1_1 : version;
    }
}