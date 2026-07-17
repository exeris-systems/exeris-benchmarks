package eu.exeris.benchmarks.targets.quarkusapp.axon;

import jakarta.enterprise.context.ApplicationScoped;
import jakarta.enterprise.inject.Produces;
import jakarta.inject.Singleton;

import org.axonframework.axonserver.connector.AxonServerConfiguration;
import org.axonframework.axonserver.connector.AxonServerConnectionManager;
import org.axonframework.axonserver.connector.command.AxonServerCommandBus;
import org.axonframework.commandhandling.CommandBus;
import org.axonframework.commandhandling.SimpleCommandBus;
import org.axonframework.commandhandling.gateway.CommandGateway;
import org.axonframework.commandhandling.gateway.DefaultCommandGateway;
import org.axonframework.serialization.Serializer;
import org.axonframework.serialization.json.JacksonSerializer;

@ApplicationScoped
public class AxonBusConfig {

    @Produces
    @Singleton
    public AxonServerConfiguration axonServerConfiguration() {
        String host = System.getenv().getOrDefault("EXERIS_AXONSERVER_HOST", "localhost");
        String port = System.getenv().getOrDefault("EXERIS_AXONSERVER_PORT", "8124");
        return AxonServerConfiguration.builder()
                .servers(host + ":" + port)
                .componentName("quarkus-benchmark-app")
                .build();
    }

    @Produces
    @Singleton
    public AxonServerConnectionManager axonServerConnectionManager(AxonServerConfiguration config) {
        return AxonServerConnectionManager.builder()
                .axonServerConfiguration(config)
                .build();
    }

    @Produces
    @Singleton
    public Serializer serializer() {
        return JacksonSerializer.defaultSerializer();
    }

    @Produces
    @Singleton
    public CommandBus commandBus(AxonServerConnectionManager connectionManager,
                                  AxonServerConfiguration config,
                                  Serializer serializer) {
        SimpleCommandBus localSegment = SimpleCommandBus.builder().build();
        return AxonServerCommandBus.builder()
                .axonServerConnectionManager(connectionManager)
                .configuration(config)
                .localSegment(localSegment)
                .serializer(serializer)
                .routingStrategy(msg -> "default")
                .build();
    }

    // Deliberately NO EventBus producer: this target's saga wiring is command-dispatch
    // only. An earlier revision produced a subscriber-less SimpleEventBus whose published
    // lifecycle events were silently dropped — dead wiring that looked load-bearing.

    @Produces
    @Singleton
    public CommandGateway commandGateway(CommandBus commandBus) {
        // CONTRACT-v2 §5: deliberately NO RetryScheduler. The gateway dispatches the whole
        // saga, so gateway-level retry would re-run completed forward steps (duplicate
        // effects, oracle O1) and could re-attempt a §4.1 business-terminal decline.
        // Transient-fault retry is configured explicitly per step in OrderSagaRetryPolicy
        // (3 attempts total / 50 ms initial backoff / factor 2 / no jitter).
        return DefaultCommandGateway.builder().commandBus(commandBus).build();
    }
}