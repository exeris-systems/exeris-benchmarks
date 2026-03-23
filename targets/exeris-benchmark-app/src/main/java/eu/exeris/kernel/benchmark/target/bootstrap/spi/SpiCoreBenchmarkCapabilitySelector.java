package eu.exeris.kernel.benchmark.target.bootstrap.spi;

import eu.exeris.kernel.benchmark.target.api.BenchmarkCapabilities;
import eu.exeris.kernel.benchmark.target.bootstrap.BenchmarkBootstrapRequest;
import eu.exeris.kernel.benchmark.target.bootstrap.BenchmarkCapabilitySelector;

public final class SpiCoreBenchmarkCapabilitySelector implements BenchmarkCapabilitySelector {

    @Override
    public BenchmarkCapabilities select(
            BenchmarkBootstrapRequest request,
            BenchmarkCapabilities availableCapabilities) {
        String requestedProtocol = normalizeProtocolMode(request.protocolMode());
        if (!availableCapabilities.supportedProtocolModes().contains(requestedProtocol)) {
            throw new IllegalArgumentException(
                    "Requested protocol mode " + requestedProtocol
                            + " is not supported by the SPI+CORE benchmark path. Available: "
                            + availableCapabilities.supportedProtocolModes());
        }
        if (!availableCapabilities.supportedBenchmarkModes().contains(request.requestedBenchmarkMode())) {
            throw new IllegalArgumentException(
                    "Requested benchmark mode " + request.requestedBenchmarkMode()
                            + " is not supported by the SPI+CORE benchmark path. Available: "
                            + availableCapabilities.supportedBenchmarkModes());
        }
        return availableCapabilities;
    }

    static String normalizeProtocolMode(String protocolMode) {
        return protocolMode == null
                ? SpiCoreConfigKeys.DEFAULT_PROTOCOL_MODE_SELECTED
                : protocolMode.trim().toUpperCase();
    }
}