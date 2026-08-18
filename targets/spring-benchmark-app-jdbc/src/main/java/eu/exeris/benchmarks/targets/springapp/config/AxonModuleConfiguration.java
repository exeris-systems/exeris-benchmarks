package eu.exeris.benchmarks.targets.springapp.config;

import org.springframework.boot.autoconfigure.condition.ConditionalOnProperty;
import org.springframework.context.annotation.ComponentScan;
import org.springframework.context.annotation.Configuration;

/**
 * Re-includes the Axon module (commands, events, aggregate, saga, services) into the
 * Spring context only when {@code exeris.axon.enabled=true} (driven by EXERIS_AXON_ENABLED).
 *
 * The base {@code @ComponentScan} on {@link eu.exeris.benchmarks.targets.springapp.SpringBenchmarkApplication}
 * always excludes {@code ...springapp.application.axon.*}; this configuration scans it back in
 * under the property gate. Combined with {@code axon.axonserver.enabled} being bound to the same
 * flag, pure-read scenarios (entity-read-by-id) run with Axon fully off — no Axon Server gRPC
 * connection, no tracking/subscribing processors — while e2e-shop-order-saga, which sets
 * EXERIS_AXON_ENABLED=true, behaves exactly as before.
 */
@Configuration(proxyBeanMethods = false)
@ConditionalOnProperty(name = "exeris.axon.enabled", havingValue = "true")
@ComponentScan("eu.exeris.benchmarks.targets.springapp.application.axon")
public class AxonModuleConfiguration {
}
