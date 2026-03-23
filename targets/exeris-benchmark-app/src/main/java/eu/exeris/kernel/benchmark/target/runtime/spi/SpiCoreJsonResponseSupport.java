package eu.exeris.kernel.benchmark.target.runtime.spi;

import eu.exeris.kernel.benchmark.target.http.BenchmarkResponse;

import java.nio.charset.StandardCharsets;
import java.util.List;
import java.util.Map;

final class SpiCoreJsonResponseSupport {

    private SpiCoreJsonResponseSupport() {
    }

    static BenchmarkResponse jsonResponse(int statusCode, String jsonBody) {
        return new BenchmarkResponse(
                statusCode,
                Map.of("content-type", List.of("application/json; charset=utf-8")),
                "application/json",
                jsonBody.getBytes(StandardCharsets.UTF_8));
    }
}