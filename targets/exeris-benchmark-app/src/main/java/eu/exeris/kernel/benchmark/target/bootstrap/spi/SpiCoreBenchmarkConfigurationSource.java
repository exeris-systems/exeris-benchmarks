package eu.exeris.kernel.benchmark.target.bootstrap.spi;

import eu.exeris.kernel.benchmark.target.bootstrap.BenchmarkConfigurationSource;

import java.util.LinkedHashMap;
import java.util.Map;

public final class SpiCoreBenchmarkConfigurationSource implements BenchmarkConfigurationSource {

    @Override
    public Map<String, String> load() {
        Map<String, String> config = new LinkedHashMap<>();

        copySystemOrEnvironment(config, SpiCoreConfigKeys.PROP_SUBSYSTEMS,
                SpiCoreConfigKeys.PROP_SUBSYSTEMS, SpiCoreConfigKeys.ENV_SUBSYSTEMS);
        copySystemOrEnvironment(config, SpiCoreConfigKeys.PROP_HTTP_BIND_HOST,
                SpiCoreConfigKeys.PROP_HTTP_BIND_HOST, SpiCoreConfigKeys.ENV_HTTP_BIND_HOST);
        copySystemOrEnvironment(config, SpiCoreConfigKeys.PROP_HTTP_PORT,
                SpiCoreConfigKeys.PROP_HTTP_PORT, SpiCoreConfigKeys.ENV_HTTP_PORT);
        copySystemOrEnvironment(config, SpiCoreConfigKeys.PROP_HTTP_MODE,
                SpiCoreConfigKeys.PROP_HTTP_MODE, SpiCoreConfigKeys.ENV_HTTP_MODE);

        String jdbcUrl = firstNonBlank(
                System.getProperty(SpiCoreConfigKeys.PROP_PERSISTENCE_JDBC_URL),
                System.getenv(SpiCoreConfigKeys.ENV_PERSISTENCE_JDBC_URL));
        if (jdbcUrl != null) {
            config.put(SpiCoreConfigKeys.PROP_PERSISTENCE_JDBC_URL, jdbcUrl);
            config.put(SpiCoreConfigKeys.ENV_PERSISTENCE_JDBC_URL, jdbcUrl);
        }

        copySystemOrEnvironment(config, SpiCoreConfigKeys.CONFIG_BENCHMARK_MODE,
                SpiCoreConfigKeys.PROP_BENCHMARK_MODE, SpiCoreConfigKeys.ENV_BENCHMARK_MODE);
        copySystemOrEnvironment(config, SpiCoreConfigKeys.CONFIG_TIER,
                SpiCoreConfigKeys.PROP_TIER, SpiCoreConfigKeys.ENV_TIER);
        copySystemOrEnvironment(config, SpiCoreConfigKeys.CONFIG_RUNTIME_FAMILY,
                SpiCoreConfigKeys.PROP_RUNTIME_FAMILY, SpiCoreConfigKeys.ENV_RUNTIME_FAMILY);
        copySystemOrEnvironment(config, SpiCoreConfigKeys.CONFIG_PROTOCOL_MODE_SELECTED,
                SpiCoreConfigKeys.PROP_PROTOCOL_MODE_SELECTED, SpiCoreConfigKeys.ENV_PROTOCOL_MODE_SELECTED);
        copySystemOrEnvironment(config, SpiCoreConfigKeys.CONFIG_IMPLEMENTATION_VARIANT,
                SpiCoreConfigKeys.PROP_IMPLEMENTATION_VARIANT, SpiCoreConfigKeys.ENV_IMPLEMENTATION_VARIANT);
        copySystemOrEnvironment(config, SpiCoreConfigKeys.CONFIG_EXECUTION_MODE,
                SpiCoreConfigKeys.PROP_EXECUTION_MODE, SpiCoreConfigKeys.ENV_EXECUTION_MODE);
        copySystemOrEnvironment(config, SpiCoreConfigKeys.CONFIG_EXECUTION_CLASS,
                SpiCoreConfigKeys.PROP_EXECUTION_CLASS, SpiCoreConfigKeys.ENV_EXECUTION_CLASS);
        copySystemOrEnvironment(config, SpiCoreConfigKeys.CONFIG_SEED_DATASET_ID,
                SpiCoreConfigKeys.PROP_SEED_DATASET_ID, SpiCoreConfigKeys.ENV_SEED_DATASET_ID);
        copySystemOrEnvironment(config, SpiCoreConfigKeys.CONFIG_BENCHMARK_BASE_PATH,
                SpiCoreConfigKeys.PROP_BENCHMARK_BASE_PATH, SpiCoreConfigKeys.ENV_BENCHMARK_BASE_PATH);
        copySystemOrEnvironment(config, SpiCoreConfigKeys.CONFIG_SUPPORTED_PROTOCOL_MODES,
                SpiCoreConfigKeys.PROP_SUPPORTED_PROTOCOL_MODES, SpiCoreConfigKeys.ENV_SUPPORTED_PROTOCOL_MODES);
        copySystemOrEnvironment(config, SpiCoreConfigKeys.CONFIG_SUPPORTED_BENCHMARK_MODES,
                SpiCoreConfigKeys.PROP_SUPPORTED_BENCHMARK_MODES, SpiCoreConfigKeys.ENV_SUPPORTED_BENCHMARK_MODES);

        config.putIfAbsent(SpiCoreConfigKeys.PROP_HTTP_BIND_HOST, SpiCoreConfigKeys.DEFAULT_HTTP_BIND_HOST);
        config.putIfAbsent(SpiCoreConfigKeys.PROP_HTTP_PORT, SpiCoreConfigKeys.DEFAULT_HTTP_PORT);
        config.putIfAbsent(SpiCoreConfigKeys.PROP_HTTP_MODE, SpiCoreConfigKeys.DEFAULT_HTTP_MODE);
        config.putIfAbsent(SpiCoreConfigKeys.CONFIG_BENCHMARK_MODE, SpiCoreConfigKeys.DEFAULT_BENCHMARK_MODE);
        config.putIfAbsent(SpiCoreConfigKeys.CONFIG_TIER, SpiCoreConfigKeys.DEFAULT_TIER);
        config.putIfAbsent(SpiCoreConfigKeys.CONFIG_RUNTIME_FAMILY, SpiCoreConfigKeys.DEFAULT_RUNTIME_FAMILY);
        config.putIfAbsent(SpiCoreConfigKeys.CONFIG_PROTOCOL_MODE_SELECTED,
                SpiCoreConfigKeys.DEFAULT_PROTOCOL_MODE_SELECTED);
        config.putIfAbsent(SpiCoreConfigKeys.CONFIG_IMPLEMENTATION_VARIANT,
                SpiCoreConfigKeys.DEFAULT_IMPLEMENTATION_VARIANT);
        config.putIfAbsent(SpiCoreConfigKeys.CONFIG_EXECUTION_MODE, firstNonBlank(
                config.get(SpiCoreConfigKeys.CONFIG_EXECUTION_CLASS),
                SpiCoreConfigKeys.DEFAULT_EXECUTION_MODE));
        config.putIfAbsent(SpiCoreConfigKeys.CONFIG_EXECUTION_CLASS, SpiCoreConfigKeys.DEFAULT_EXECUTION_CLASS);
        config.putIfAbsent(SpiCoreConfigKeys.CONFIG_SEED_DATASET_ID, SpiCoreConfigKeys.DEFAULT_SEED_DATASET_ID);
        config.putIfAbsent(SpiCoreConfigKeys.CONFIG_BENCHMARK_BASE_PATH,
                SpiCoreConfigKeys.DEFAULT_BENCHMARK_BASE_PATH);
        config.putIfAbsent(SpiCoreConfigKeys.CONFIG_SUPPORTED_PROTOCOL_MODES,
                SpiCoreConfigKeys.DEFAULT_SUPPORTED_PROTOCOL_MODES);

        return Map.copyOf(config);
    }

    private static void copySystemOrEnvironment(
            Map<String, String> config,
            String configKey,
            String propertyName,
            String environmentName) {
        String value = firstNonBlank(System.getProperty(propertyName), System.getenv(environmentName));
        if (value != null) {
            config.put(configKey, value);
        }
    }

    private static String firstNonBlank(String first, String second) {
        if (first != null && !first.isBlank()) {
            return first;
        }
        if (second != null && !second.isBlank()) {
            return second;
        }
        return null;
    }
}