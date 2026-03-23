package eu.exeris.kernel.benchmark.target.runtime.spi;

import eu.exeris.kernel.benchmark.target.http.BenchmarkHttpHandler;
import eu.exeris.kernel.benchmark.target.http.BenchmarkRequestContext;
import eu.exeris.kernel.benchmark.target.http.BenchmarkResponse;

record SpiCoreHealthReadyHandler(SpiCoreBenchmarkLifecycle lifecycle) implements BenchmarkHttpHandler {

    @Override
    public BenchmarkResponse handle(BenchmarkRequestContext request) {
        boolean ready = lifecycle.isReady();
        int statusCode = ready ? 200 : 503;
        String body = "{"
                + "\"endpoint\":\"health-ready\"," 
                + "\"ready\":" + ready + ","
                + "\"httpBound\":" + lifecycle.isHttpBound() + ","
                + "\"persistenceBound\":" + lifecycle.isPersistenceBound()
                + "}";
        return SpiCoreJsonResponseSupport.jsonResponse(statusCode, body);
    }
}