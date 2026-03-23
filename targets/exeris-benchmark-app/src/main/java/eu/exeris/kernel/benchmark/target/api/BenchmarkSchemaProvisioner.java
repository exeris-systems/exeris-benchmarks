package eu.exeris.kernel.benchmark.target.api;

import java.util.Map;
import java.util.Set;

public interface BenchmarkSchemaProvisioner {

    Set<String> provisionedSchemaIds();

    void ensureProvisioned(Map<String, String> configuration);
}