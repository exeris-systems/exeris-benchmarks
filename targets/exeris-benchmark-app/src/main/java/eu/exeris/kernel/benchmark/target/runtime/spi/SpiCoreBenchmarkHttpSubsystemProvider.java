package eu.exeris.kernel.benchmark.target.runtime.spi;

import eu.exeris.kernel.spi.bootstrap.BootstrapPhase;
import eu.exeris.kernel.spi.bootstrap.Subsystem;
import eu.exeris.kernel.spi.bootstrap.SubsystemProvider;
import eu.exeris.kernel.spi.config.ConfigProvider;
import eu.exeris.kernel.spi.http.HttpClientEngine;
import eu.exeris.kernel.spi.http.HttpConfig;
import eu.exeris.kernel.spi.http.HttpKernelProviders;
import eu.exeris.kernel.spi.http.HttpMode;
import eu.exeris.kernel.spi.http.HttpProvider;
import eu.exeris.kernel.spi.http.HttpServerEngine;
import eu.exeris.kernel.spi.http.HttpVersion;

import java.util.Comparator;
import java.util.List;
import java.util.Locale;
import java.util.Objects;
import java.util.ServiceLoader;
import java.util.function.UnaryOperator;

public final class SpiCoreBenchmarkHttpSubsystemProvider implements SubsystemProvider {

    @Override
    public List<Subsystem> getSubsystems(ConfigProvider configProvider) {
        return List.of(new BenchmarkHttpSubsystem(configProvider));
    }

    @Override
    public int priority() {
        return 300;
    }

    @Override
    public String moduleName() {
        return "exeris-benchmark-app";
    }

    private static final class BenchmarkHttpSubsystem implements Subsystem {

        private final ConfigProvider configProvider;
        private HttpProvider httpProvider;
        private HttpServerEngine serverEngine;
        private HttpClientEngine clientEngine;
        private HttpMode mode;
        private HttpConfig httpConfig;
        private boolean serverStarted;

        private BenchmarkHttpSubsystem(ConfigProvider configProvider) {
            this.configProvider = Objects.requireNonNull(configProvider, "configProvider");
        }

        @Override
        public String name() {
            return "http";
        }

        @Override
        public List<String> dependsOn() {
            return List.of("memory");
        }

        @Override
        public BootstrapPhase phase() {
            return BootstrapPhase.RUNTIME;
        }

        @Override
        public void initialize() {
            this.httpProvider = ServiceLoader.load(HttpProvider.class).stream()
                    .map(ServiceLoader.Provider::get)
                    .max(Comparator.comparingInt(HttpProvider::priority))
                    .orElseThrow(() -> new IllegalStateException("No HttpProvider available on classpath"));

            this.mode = resolveMode(configProvider);
            this.httpConfig = buildHttpConfig(configProvider, mode);
        }

        @Override
        public void start() {
            if ((mode == HttpMode.SERVER || mode == HttpMode.DUAL) && serverEngine == null) {
                serverEngine = httpProvider.createServerEngine(httpConfig);
                serverEngine.setHandler(SpiCoreBenchmarkHttpBridgeRegistry.get()
                        .orElseThrow(() -> new IllegalStateException(
                                "Benchmark HTTP bridge handler was not installed before subsystem start")));
            }
            if ((mode == HttpMode.CLIENT || mode == HttpMode.DUAL) && clientEngine == null) {
                clientEngine = httpProvider.createClientEngine(httpConfig);
            }
            if (serverEngine != null) {
                serverEngine.start();
                serverStarted = true;
            }
            if (clientEngine != null) {
                clientEngine.start();
            }
        }

        @Override
        public void stop() {
            RuntimeException firstFailure = null;

            if (clientEngine != null) {
                try {
                    clientEngine.close();
                } catch (RuntimeException failure) {
                    firstFailure = failure;
                } finally {
                    clientEngine = null;
                }
            }
            if (serverEngine != null) {
                try {
                    if (serverStarted) {
                        serverEngine.stop();
                    }
                } catch (RuntimeException failure) {
                    if (firstFailure == null) {
                        firstFailure = failure;
                    } else {
                        firstFailure.addSuppressed(failure);
                    }
                } finally {
                    try {
                        serverEngine.close();
                    } catch (RuntimeException failure) {
                        if (firstFailure == null) {
                            firstFailure = failure;
                        } else {
                            firstFailure.addSuppressed(failure);
                        }
                    } finally {
                        serverEngine = null;
                        serverStarted = false;
                    }
                }
            }
            mode = null;
            httpConfig = null;
            httpProvider = null;
            if (firstFailure != null) {
                throw firstFailure;
            }
        }

        @Override
        public UnaryOperator<ScopedValue.Carrier> providerBindings() {
            return carrier -> {
                if (httpProvider == null) {
                    return carrier;
                }

                ScopedValue.Carrier bound = carrier.where(HttpKernelProviders.HTTP_PROVIDER, httpProvider);
                if (serverEngine != null) {
                    bound = bound.where(HttpKernelProviders.HTTP_SERVER_ENGINE, serverEngine);
                }
                if (clientEngine != null) {
                    bound = bound.where(HttpKernelProviders.HTTP_CLIENT_ENGINE, clientEngine);
                }
                return bound;
            };
        }
    }

    private static HttpMode resolveMode(ConfigProvider configProvider) {
        String modeValue = configProvider.getStringOrDefault("http.mode", "SERVER")
                .trim()
                .toUpperCase(Locale.ROOT);
        return HttpMode.valueOf(modeValue);
    }

    private static HttpConfig buildHttpConfig(ConfigProvider configProvider, HttpMode mode) {
        return new HttpConfig(
                mode,
                configProvider.getStringOrDefault("http.bindHost", HttpConfig.DEFAULT_BIND_HOST),
                configProvider.getIntOrDefault("http.port", HttpConfig.DEFAULT_PORT),
                getIntWithAliases(configProvider, HttpConfig.DEFAULT_MAX_CONNECTIONS,
                        "http.maxConnections", "http.max.connections"),
                getLongWithAliases(configProvider, HttpConfig.DEFAULT_IDLE_TIMEOUT_MS,
                        "http.idleTimeoutMillis", "http.idle.timeout.ms"),
                getIntWithAliases(configProvider, HttpConfig.DEFAULT_MAX_HEADER_COUNT,
                        "http.maxRequestHeaderCount", "http.maxHeaders", "http.max.header.count"),
                getIntWithAliases(configProvider, HttpConfig.DEFAULT_MAX_HEADER_SIZE,
                        "http.maxRequestHeaderSize", "http.maxHeaderSize", "http.max.header.size"),
                getLongWithAliases(configProvider, HttpConfig.DEFAULT_MAX_REQUEST_BODY_BYTES,
                        "http.maxRequestBodyBytes", "http.maxBodyBytes", "http.max.body.bytes"),
                configProvider.getBooleanOrDefault("http.h2cUpgradeEnabled", false),
                parseMaxVersion(configProvider.getStringOrDefault("http.maxVersion", "HTTP_2")));
    }

    private static int getIntWithAliases(ConfigProvider configProvider, int fallback, String... keys) {
        for (String key : keys) {
            if (configProvider.getInt(key).isPresent()) {
                return configProvider.getIntOrDefault(key, fallback);
            }
        }
        return fallback;
    }

    private static long getLongWithAliases(ConfigProvider configProvider, long fallback, String... keys) {
        for (String key : keys) {
            if (configProvider.getLong(key).isPresent()) {
                return configProvider.getLongOrDefault(key, fallback);
            }
        }
        return fallback;
    }

    private static HttpVersion parseMaxVersion(String rawValue) {
        String value = rawValue.trim().toUpperCase(Locale.ROOT);
        return switch (value) {
            case "H1", "HTTP/1.0", "HTTP/1.1" -> HttpVersion.HTTP_1_1;
            case "H2", "HTTP/2", "HTTP_2" -> HttpVersion.HTTP_2;
            case "H3", "HTTP/3", "HTTP_3" -> HttpVersion.HTTP_3;
            default -> HttpVersion.valueOf(value.replace('/', '_').replace('.', '_'));
        };
    }
}