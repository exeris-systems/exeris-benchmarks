package eu.exeris.kernel.benchmark.target.bootstrap.spi;

public final class SpiCoreConfigKeys {

    public static final String PROP_SUBSYSTEMS = "exeris.launcher.subsystems";
    public static final String PROP_HTTP_BIND_HOST = "exeris.http.bindHost";
    public static final String PROP_HTTP_PORT = "exeris.http.port";
    public static final String PROP_HTTP_MODE = "exeris.http.mode";
    public static final String PROP_PERSISTENCE_JDBC_URL = "exeris.persistence.jdbcUrl";
    public static final String ENV_PERSISTENCE_JDBC_URL = "EXERIS_PERSISTENCE_JDBCURL";

    public static final String PROP_BENCHMARK_MODE = "benchmark.target.benchmarkMode";
    public static final String PROP_TIER = "benchmark.target.tier";
    public static final String PROP_RUNTIME_FAMILY = "benchmark.target.runtimeFamily";
    public static final String PROP_PROTOCOL_MODE_SELECTED = "benchmark.target.protocolModeSelected";
    public static final String PROP_IMPLEMENTATION_VARIANT = "benchmark.target.implementationVariant";
    public static final String PROP_EXECUTION_MODE = "benchmark.target.executionMode";
    public static final String PROP_EXECUTION_CLASS = "benchmark.target.executionClass";
    public static final String PROP_SEED_DATASET_ID = "benchmark.target.seedDatasetId";
    public static final String PROP_BENCHMARK_BASE_PATH = "benchmark.target.basePath";
    public static final String PROP_SUPPORTED_PROTOCOL_MODES = "benchmark.target.supportedProtocolModes";
    public static final String PROP_SUPPORTED_BENCHMARK_MODES = "benchmark.target.supportedBenchmarkModes";

    public static final String ENV_SUBSYSTEMS = "EXERIS_LAUNCHER_SUBSYSTEMS";
    public static final String ENV_HTTP_BIND_HOST = "EXERIS_HTTP_BINDHOST";
    public static final String ENV_HTTP_PORT = "EXERIS_HTTP_PORT";
    public static final String ENV_HTTP_MODE = "EXERIS_HTTP_MODE";
    public static final String ENV_BENCHMARK_MODE = "BENCHMARK_TARGET_BENCHMARK_MODE";
    public static final String ENV_TIER = "BENCHMARK_TARGET_TIER";
    public static final String ENV_RUNTIME_FAMILY = "BENCHMARK_TARGET_RUNTIME_FAMILY";
    public static final String ENV_PROTOCOL_MODE_SELECTED = "BENCHMARK_TARGET_PROTOCOL_MODE_SELECTED";
    public static final String ENV_IMPLEMENTATION_VARIANT = "BENCHMARK_TARGET_IMPLEMENTATION_VARIANT";
    public static final String ENV_EXECUTION_MODE = "BENCHMARK_TARGET_EXECUTION_MODE";
    public static final String ENV_EXECUTION_CLASS = "BENCHMARK_TARGET_EXECUTION_CLASS";
    public static final String ENV_SEED_DATASET_ID = "BENCHMARK_TARGET_SEED_DATASET_ID";
    public static final String ENV_BENCHMARK_BASE_PATH = "BENCHMARK_TARGET_BASE_PATH";
    public static final String ENV_SUPPORTED_PROTOCOL_MODES = "BENCHMARK_TARGET_SUPPORTED_PROTOCOL_MODES";
    public static final String ENV_SUPPORTED_BENCHMARK_MODES = "BENCHMARK_TARGET_SUPPORTED_BENCHMARK_MODES";

    public static final String CONFIG_BENCHMARK_MODE = "requestedBenchmarkMode";
    public static final String CONFIG_TIER = "tier";
    public static final String CONFIG_RUNTIME_FAMILY = "runtimeFamily";
    public static final String CONFIG_PROTOCOL_MODE_SELECTED = "protocolModeSelected";
    public static final String CONFIG_IMPLEMENTATION_VARIANT = "implementationVariant";
    public static final String CONFIG_EXECUTION_MODE = "executionMode";
    public static final String CONFIG_EXECUTION_CLASS = "executionClass";
    public static final String CONFIG_SEED_DATASET_ID = "seedDatasetId";
    public static final String CONFIG_BENCHMARK_BASE_PATH = "benchmarkBasePath";
    public static final String CONFIG_SUPPORTED_PROTOCOL_MODES = "supportedProtocolModes";
    public static final String CONFIG_SUPPORTED_BENCHMARK_MODES = "supportedBenchmarkModes";

    public static final String DEFAULT_HTTP_BIND_HOST = "127.0.0.1";
    public static final String DEFAULT_HTTP_PORT = "8080";
    public static final String DEFAULT_HTTP_MODE = "SERVER";
    public static final String DEFAULT_BENCHMARK_MODE = "PURE";
    public static final String DEFAULT_TIER = "community";
    public static final String DEFAULT_RUNTIME_FAMILY = "kernel";
    public static final String DEFAULT_PROTOCOL_MODE_SELECTED = "H1";
    public static final String DEFAULT_IMPLEMENTATION_VARIANT = "spi-core-bootstrap";
    public static final String DEFAULT_EXECUTION_MODE = "jar";
    public static final String DEFAULT_EXECUTION_CLASS = "jar";
    public static final String DEFAULT_SEED_DATASET_ID = "unseeded";
    public static final String DEFAULT_BENCHMARK_BASE_PATH = "/benchmark";
    public static final String DEFAULT_SUPPORTED_PROTOCOL_MODES = "H1,H2";

    private SpiCoreConfigKeys() {
    }
}