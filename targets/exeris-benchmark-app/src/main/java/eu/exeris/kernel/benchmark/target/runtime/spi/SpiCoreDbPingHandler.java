package eu.exeris.kernel.benchmark.target.runtime.spi;

import eu.exeris.kernel.benchmark.target.http.BenchmarkHttpHandler;
import eu.exeris.kernel.benchmark.target.http.BenchmarkRequestContext;
import eu.exeris.kernel.benchmark.target.http.BenchmarkResponse;

record SpiCoreDbPingHandler(SpiCoreBenchmarkLifecycle lifecycle) implements BenchmarkHttpHandler {

    @Override
    public BenchmarkResponse handle(BenchmarkRequestContext request) {
        boolean persistenceBound = lifecycle.isPersistenceBound();
        int statusCode = persistenceBound ? 200 : 503;
        String body = "{"
                + "\"endpoint\":\"db-ping\"," 
                + "\"persistenceBound\":" + persistenceBound + ","
                + "\"status\":\"" + (persistenceBound ? "bound" : "unbound") + "\"," 
                + "\"notes\":\"Reflects KernelProviders persistence binding state only; no datastore ping is performed.\""
                + "}";
        return SpiCoreJsonResponseSupport.jsonResponse(statusCode, body);
    }
}