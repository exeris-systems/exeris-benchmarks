package eu.exeris.benchmarks.targets.springapp.application.axon;

import org.axonframework.commandhandling.CommandBus;
import org.axonframework.commandhandling.gateway.CommandGateway;
import org.axonframework.commandhandling.gateway.DefaultCommandGateway;
import org.axonframework.commandhandling.gateway.ExponentialBackOffIntervalRetryScheduler;
import org.axonframework.commandhandling.gateway.RetryScheduler;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;

import java.util.concurrent.Executors;
import java.util.concurrent.ScheduledExecutorService;

/**
 * Axon configuration for the Axon Server production simulation path.
 *
 * axon.axonserver.enabled=true — Spring Boot autoconfiguration wires:
 *   - AxonServerCommandBus as CommandBus
 *   - AxonServerEventStore as EventStore (events persisted to Axon Server)
 *
 * InMemoryEventStorageEngine and InMemoryTokenStore are NOT registered here —
 * those were only needed for the (broken) embedded fallback path.
 *
 * CONTRACT-v2 §5 pinned transient-fault retry policy — configured explicitly,
 * defaults are not trusted: max 3 attempts total (1 initial + 2 retries),
 * exponential backoff with initial interval 50 ms and factor 2, no jitter.
 * ExponentialBackOffIntervalRetryScheduler waits backoffFactor * 2^(failureCount-1)
 * ms between attempts → 50 ms, then 100 ms. Defining the CommandGateway bean here
 * makes Axon's auto-configured gateway (which has NO retry scheduler) back off.
 *
 * Business-terminal payment declines (§4.1) are modeled as PaymentDeclinedEvent,
 * never as exceptions, so they cannot reach this scheduler: zero retries on decline.
 */
@Configuration
public class AxonBusConfig {

    /** §5: initial retry interval, milliseconds. */
    private static final long RETRY_INITIAL_BACKOFF_MS = 50L;

    /** §5: 2 retries + 1 initial attempt = max 3 attempts total. */
    private static final int RETRY_MAX_RETRY_COUNT = 2;

    @Bean(destroyMethod = "shutdown")
    public ScheduledExecutorService commandRetryExecutor() {
        return Executors.newSingleThreadScheduledExecutor(runnable -> {
            Thread thread = new Thread(runnable, "axon-command-retry");
            thread.setDaemon(true);
            return thread;
        });
    }

    @Bean
    public RetryScheduler commandRetryScheduler(ScheduledExecutorService commandRetryExecutor) {
        return ExponentialBackOffIntervalRetryScheduler.builder()
                .retryExecutor(commandRetryExecutor)
                .backoffFactor(RETRY_INITIAL_BACKOFF_MS)
                .maxRetryCount(RETRY_MAX_RETRY_COUNT)
                .build();
    }

    @Bean
    public CommandGateway commandGateway(CommandBus commandBus, RetryScheduler commandRetryScheduler) {
        return DefaultCommandGateway.builder()
                .commandBus(commandBus)
                .retryScheduler(commandRetryScheduler)
                .build();
    }
}
