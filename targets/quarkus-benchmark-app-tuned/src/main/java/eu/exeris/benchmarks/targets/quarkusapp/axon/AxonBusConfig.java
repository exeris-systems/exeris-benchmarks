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
import org.axonframework.eventhandling.EventBus;
import org.axonframework.eventhandling.SimpleEventBus;
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

    @Produces
    @Singleton
    public EventBus eventBus() {
        return SimpleEventBus.builder().build();
    }

    @Produces
    @Singleton
    public CommandGateway commandGateway(CommandBus commandBus) {
        return DefaultCommandGateway.builder().commandBus(commandBus).build();
    }
}