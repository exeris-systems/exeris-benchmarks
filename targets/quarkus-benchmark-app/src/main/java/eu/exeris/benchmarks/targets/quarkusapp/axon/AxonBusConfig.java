package eu.exeris.benchmarks.targets.quarkusapp.axon;

import jakarta.enterprise.context.ApplicationScoped;
import jakarta.enterprise.inject.Instance;
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

import org.eclipse.microprofile.config.inject.ConfigProperty;

@ApplicationScoped
public class AxonBusConfig {

    /**
     * Runtime gate for ALL Axon Server connection wiring — the Quarkus-native counterpart of the
     * Spring target's {@code @ConditionalOnProperty(name = "exeris.axon.enabled", havingValue = "true")}
     * (AxonModuleConfiguration), driven by the same env var {@code EXERIS_AXON_ENABLED} (SmallRye maps
     * {@code EXERIS_AXON_ENABLED} to {@code exeris.axon.enabled} — the same env-to-property auto-mapping
     * the neo4j config already relies on).
     *
     * <p>Only the e2e-shop-order-saga scenario sets it {@code true}; entity-read-by-id leaves it unset
     * (defaults to {@code false}). When {@code false}, {@link #commandBus} returns a purely in-JVM
     * {@link SimpleCommandBus} and NEVER calls {@code connectionManager.get()}, so the
     * {@link #axonServerConnectionManager} producer never runs, no {@link AxonServerCommandBus} is
     * constructed, and therefore no Axon Server gRPC channel — and none of its reconnect scheduler —
     * is created at boot. That matches the Spring target's zero-connection behavior for pure-read runs.
     * When {@code true}, the wiring below is byte-for-byte identical to prior revisions, so the
     * {@code @Startup} eager CreateOrderCommand registration still reaches Axon Server during boot.
     */
    @ConfigProperty(name = "exeris.axon.enabled", defaultValue = "false")
    boolean axonEnabled;

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
    public CommandBus commandBus(Instance<AxonServerConnectionManager> connectionManager,
                                  AxonServerConfiguration config,
                                  Serializer serializer) {
        if (!axonEnabled) {
            // exeris.axon.enabled unset/false (entity-read-by-id): a purely in-JVM command bus.
            // connectionManager.get() is deliberately NOT called, so the AxonServerConnectionManager
            // producer never executes, no AxonServerCommandBus is built, and no Axon Server gRPC
            // channel (hence no reconnect loop) exists at boot. The @Startup AxonOrderSagaService
            // still subscribes CreateOrderCommand, but to THIS local bus — an in-memory handler
            // registration with zero network I/O. The bean graph stays valid so the entity
            // endpoints serve normally with Axon Server absent.
            return SimpleCommandBus.builder().build();
        }
        // exeris.axon.enabled=true (e2e-shop-order-saga): unchanged wiring. The connection manager is
        // resolved here (and only here), so the @Startup eager CreateOrderCommand registration reaches
        // Axon Server at boot exactly as in prior revisions — the saga @Startup fix is preserved.
        SimpleCommandBus localSegment = SimpleCommandBus.builder().build();
        return AxonServerCommandBus.builder()
                .axonServerConnectionManager(connectionManager.get())
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
