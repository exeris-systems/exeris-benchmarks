package eu.exeris.benchmarks.targets.springapp.application.axon;

import org.springframework.context.annotation.Configuration;

/**
 * Axon configuration for the Axon Server production simulation path.
 *
 * axon.axonserver.enabled=true — Spring Boot autoconfiguration wires:
 *   - AxonServerCommandBus as CommandBus
 *   - AxonServerEventStore as EventStore (events persisted to Axon Server)
 *   - CommandGateway backed by AxonServerCommandBus
 *
 * InMemoryEventStorageEngine and InMemoryTokenStore are NOT registered here —
 * those were only needed for the (broken) embedded fallback path.
 */
@Configuration
public class AxonBusConfig {
}
