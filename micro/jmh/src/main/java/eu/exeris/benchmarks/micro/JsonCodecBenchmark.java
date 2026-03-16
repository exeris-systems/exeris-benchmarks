package eu.exeris.benchmarks.micro;

import eu.exeris.kernel.core.http.http1.Http1RequestParser;
import eu.exeris.kernel.core.http.http1.Http1ResponseEncoder;
import org.openjdk.jmh.annotations.*;
import org.openjdk.jmh.infra.Blackhole;

import java.lang.foreign.MemorySegment;
import java.lang.foreign.ValueLayout;
import java.nio.charset.StandardCharsets;
import java.util.concurrent.TimeUnit;

/**
 * Benchmarks JSON codec encode/decode overhead on the Exeris hot path.
 *
 * Claims under test:
 * - Encode (POJO → byte[]/ByteBuffer): allocation rate on zero-alloc claim paths
 * - Decode (byte[] → POJO): correctness + throughput
 *
 * Run with allocation profiler:
 *   java -jar target/benchmarks.jar JsonCodec -prof gc -wi 5 -i 10 -f 3
 *
 * Expected on zero-alloc encode path: gc.alloc.rate.norm = 0 B/op
 */
@BenchmarkMode({Mode.Throughput, Mode.AverageTime})
@OutputTimeUnit(TimeUnit.MICROSECONDS)
@State(Scope.Benchmark)
@Warmup(iterations = 5, time = 2, timeUnit = TimeUnit.SECONDS)
@Measurement(iterations = 10, time = 2, timeUnit = TimeUnit.SECONDS)
@Fork(value = 3, jvmArgsAppend = {
    "-XX:+UseG1GC",
    "-XX:+AlwaysPreTouch",
    "-Xms256m", "-Xmx256m"
})
public class JsonCodecBenchmark {

    // Payload sizes
    @Param({"small", "medium"})
    private String payloadSize;

    private static final String REQUEST_ID = "bench-0001";
    private static final int RESPONSE_BUFFER_SIZE = 16 * 1024;

    private byte[] smallPayload;
    private byte[] mediumPayload;
    private byte[] smallRequest;
    private byte[] mediumRequest;
    private byte[] responseBuffer;
    private MemorySegment responseSegment;

    private static final String SMALL_JSON =
        "{\"id\":\"abc123\",\"name\":\"test\",\"value\":42}";
    private static final String MEDIUM_JSON =
        "{\"id\":\"abc123\",\"name\":\"benchmark-user\",\"email\":\"bench@exeris.io\"," +
        "\"roles\":[\"admin\",\"user\"],\"metadata\":{\"created\":\"2026-01-01\"," +
        "\"region\":\"eu-west\",\"tier\":\"community\"},\"active\":true,\"score\":9.87}";

    @Setup(Level.Trial)
    public void setup() {
        smallPayload = SMALL_JSON.getBytes(StandardCharsets.UTF_8);
        mediumPayload = MEDIUM_JSON.getBytes(StandardCharsets.UTF_8);
        smallRequest = buildHttpRequest(smallPayload);
        mediumRequest = buildHttpRequest(mediumPayload);
        responseBuffer = new byte[RESPONSE_BUFFER_SIZE];
        responseSegment = MemorySegment.ofArray(responseBuffer);
    }

    private byte[] payload() {
        return "small".equals(payloadSize) ? smallPayload : mediumPayload;
    }

    private byte[] requestBytes() {
        return "small".equals(payloadSize) ? smallRequest : mediumRequest;
    }

    @Benchmark
    public void decode(Blackhole bh) {
        DecodedRequest decoded = decodeRequest(requestBytes());
        bh.consume(decoded.method());
        bh.consume(decoded.path());
        bh.consume(decoded.version());
        bh.consume(decoded.headerCount());
        bh.consume(decoded.headerChars());
        bh.consume(decoded.bodyText());
    }

    @Benchmark
    public void encode(Blackhole bh) {
        long encodedSize = encodeResponse(payload());
        bh.consume(encodedSize);
    }

    @Benchmark
    public void roundTrip(Blackhole bh) {
        DecodedRequest decoded = decodeRequest(requestBytes());
        long encodedSize = encodeResponse(decoded.bodyBytes());
        bh.consume(decoded.method());
        bh.consume(decoded.path());
        bh.consume(decoded.version());
        bh.consume(decoded.headerCount());
        bh.consume(decoded.headerChars());
        bh.consume(decoded.bodyText());
        bh.consume(encodedSize);
    }

    private byte[] buildHttpRequest(byte[] bodyBytes) {
        String headers = "POST /api/v1/benchmark HTTP/1.1\r\n"
                + "Host: localhost:8080\r\n"
                + "Content-Type: application/json\r\n"
                + "X-Request-Id: " + REQUEST_ID + "\r\n"
                + "Content-Length: " + bodyBytes.length + "\r\n"
                + "\r\n";
        byte[] headerBytes = headers.getBytes(StandardCharsets.US_ASCII);
        byte[] request = new byte[headerBytes.length + bodyBytes.length];
        System.arraycopy(headerBytes, 0, request, 0, headerBytes.length);
        System.arraycopy(bodyBytes, 0, request, headerBytes.length, bodyBytes.length);
        return request;
    }

    private DecodedRequest decodeRequest(byte[] requestBytes) {
        MemorySegment requestSegment = MemorySegment.ofArray(requestBytes);
        Http1RequestParser.RequestLine requestLine = Http1RequestParser.parseRequestLine(
                requestSegment, 0, requestSegment.byteSize());
        if (requestLine == null) {
            throw new IllegalStateException("Expected complete HTTP/1.1 request line");
        }

        long requestLineEnd = findCrlf(requestBytes, 0);
        long headerStart = requestLineEnd + 2;
        int[] headerCount = {0};
        int[] headerChars = {0};
        long headerEnd = Http1RequestParser.parseHeaders(
                requestSegment,
                headerStart,
                requestSegment.byteSize() - headerStart,
                (name, value) -> {
                    headerCount[0]++;
                    headerChars[0] += name.length() + value.length();
                });
        if (headerEnd < 0) {
            throw new IllegalStateException("Expected complete HTTP/1.1 headers");
        }

        int bodyLength = (int) (requestSegment.byteSize() - headerEnd);
        byte[] body = new byte[bodyLength];
        MemorySegment.copy(requestSegment, ValueLayout.JAVA_BYTE, headerEnd, body, 0, bodyLength);
        String bodyText = new String(body, StandardCharsets.UTF_8);

        return new DecodedRequest(
                requestLine.method(),
                requestLine.target(),
                requestLine.version(),
                headerCount[0],
                headerChars[0],
                body,
                bodyText);
    }

    private long encodeResponse(byte[] bodyBytes) {
        long position = 0;
        position = Http1ResponseEncoder.writeStatusLine(responseSegment, position, 200, "OK");
        position = Http1ResponseEncoder.writeHeader(responseSegment, position, "Content-Type", "application/json");
        position = Http1ResponseEncoder.writeHeader(responseSegment, position, "Content-Length", String.valueOf(bodyBytes.length));
        position = Http1ResponseEncoder.writeHeader(responseSegment, position, "X-Response-Id", REQUEST_ID);
        position = Http1ResponseEncoder.writeHeaderEnd(responseSegment, position);
        MemorySegment.copy(MemorySegment.ofArray(bodyBytes), 0L, responseSegment, position, bodyBytes.length);
        return position + bodyBytes.length;
    }

    private static long findCrlf(byte[] bytes, int start) {
        for (int index = start; index < bytes.length - 1; index++) {
            if (bytes[index] == '\r' && bytes[index + 1] == '\n') {
                return index;
            }
        }
        throw new IllegalStateException("Expected CRLF in HTTP/1.1 message");
    }

    private record DecodedRequest(
            String method,
            String path,
            String version,
            int headerCount,
            int headerChars,
            byte[] bodyBytes,
            String bodyText
    ) {
    }
}
