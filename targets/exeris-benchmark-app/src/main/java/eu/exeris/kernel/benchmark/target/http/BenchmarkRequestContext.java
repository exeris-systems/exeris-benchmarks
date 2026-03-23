package eu.exeris.kernel.benchmark.target.http;

import java.io.InputStream;
import java.util.List;
import java.util.Map;

public interface BenchmarkRequestContext {

    String method();

    String path();

    Map<String, List<String>> headers();

    Map<String, List<String>> queryParameters();

    InputStream body();
}