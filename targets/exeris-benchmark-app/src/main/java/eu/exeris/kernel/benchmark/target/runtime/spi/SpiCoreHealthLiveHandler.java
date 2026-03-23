package eu.exeris.kernel.benchmark.target.runtime.spi;

import eu.exeris.kernel.benchmark.target.http.BenchmarkHttpHandler;
import eu.exeris.kernel.benchmark.target.http.BenchmarkRequestContext;
import eu.exeris.kernel.benchmark.target.http.BenchmarkResponse;

record SpiCoreHealthLiveHandler(SpiCoreBenchmarkLifecycle lifecycle) implements BenchmarkHttpHandler {

    @Override
    public BenchmarkResponse handle(BenchmarkRequestContext request) {
        boolean httpBound = lifecycle.isHttpBound();
        int statusCode = httpBound ? 200 : 503;
        String body = "{"
                + "\"endpoint\":\"health-live\"," 
                + "\"httpLifecycleState\":\"" + (httpBound ? "bound" : "unbound") + "\"," 
                + "\"alive\":" + httpBound + ","
                + "\"ready\":" + lifecycle.isReady()
                + "}";
        return SpiCoreJsonResponseSupport.jsonResponse(statusCode, body);
    }
}