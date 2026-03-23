package eu.exeris.kernel.benchmark.target.http;

import java.io.IOException;

public interface BenchmarkHttpHandler {

    BenchmarkResponse handle(BenchmarkRequestContext request) throws IOException;
}