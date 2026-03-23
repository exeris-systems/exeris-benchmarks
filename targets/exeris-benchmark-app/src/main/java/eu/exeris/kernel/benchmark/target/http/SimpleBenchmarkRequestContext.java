package eu.exeris.kernel.benchmark.target.http;

import java.io.ByteArrayInputStream;
import java.io.InputStream;
import java.util.List;
import java.util.Map;
import java.util.Objects;

public record SimpleBenchmarkRequestContext(
        String method,
        String path,
        Map<String, List<String>> headers,
        Map<String, List<String>> queryParameters,
        byte[] bodyBytes) implements BenchmarkRequestContext {

    public SimpleBenchmarkRequestContext {
        method = Objects.requireNonNull(method, "method");
        path = Objects.requireNonNull(path, "path");
        headers = Map.copyOf(Objects.requireNonNull(headers, "headers"));
        queryParameters = Map.copyOf(Objects.requireNonNull(queryParameters, "queryParameters"));
        bodyBytes = Objects.requireNonNull(bodyBytes, "bodyBytes").clone();
    }

    @Override
    public InputStream body() {
        return new ByteArrayInputStream(bodyBytes.clone());
    }
}