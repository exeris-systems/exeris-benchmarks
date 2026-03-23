package eu.exeris.kernel.benchmark.target.http;

import java.util.List;
import java.util.Map;
import java.util.Objects;

public record BenchmarkResponse(
        int statusCode,
        Map<String, List<String>> headers,
        String contentType,
        byte[] body) {

    public BenchmarkResponse {
        headers = Map.copyOf(Objects.requireNonNull(headers, "headers"));
        contentType = Objects.requireNonNull(contentType, "contentType");
        body = Objects.requireNonNull(body, "body").clone();
    }

    @Override
    public byte[] body() {
        return body.clone();
    }
}