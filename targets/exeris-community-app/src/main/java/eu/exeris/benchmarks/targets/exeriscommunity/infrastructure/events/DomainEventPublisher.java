package eu.exeris.benchmarks.targets.exeriscommunity.infrastructure.events;

import eu.exeris.kernel.spi.events.EventDescriptor;
import eu.exeris.kernel.spi.events.EventEngine;
import eu.exeris.kernel.spi.events.EventPayload;
import eu.exeris.kernel.spi.events.EventTypeSpec;
import java.nio.charset.StandardCharsets;
import java.util.UUID;

public final class DomainEventPublisher {

    private static final EventTypeSpec PAYMENT_REQUESTED =
        EventTypeSpec.ofPersistent("PAYMENT_REQUESTED", 1001);
    private static final EventTypeSpec ORDER_CONFIRMED =
        EventTypeSpec.ofPersistent("ORDER_CONFIRMED", 1002);
    private static final EventTypeSpec ORDER_COMPENSATED =
        EventTypeSpec.ofPersistent("ORDER_COMPENSATED", 1003);

    private final EventEngine eventEngine;

    public DomainEventPublisher(EventEngine eventEngine) {
        this.eventEngine = eventEngine;
        registerEventTypes();
    }

    public void publishPaymentRequested(long orderId) {
        publish(orderId, PAYMENT_REQUESTED);
    }

    public void publishOrderConfirmed(long orderId) {
        publish(orderId, ORDER_CONFIRMED);
    }

    public void publishOrderCompensated(long orderId) {
        publish(orderId, ORDER_COMPENSATED);
    }

    private void registerEventTypes() {
        register(PAYMENT_REQUESTED);
        register(ORDER_CONFIRMED);
        register(ORDER_COMPENSATED);
    }

    private void register(EventTypeSpec spec) {
        try {
            eventEngine.registry().register(spec);
        } catch (RuntimeException _) {
            // In case of multiple concurrent publishers, 
            // the same event type might be registered multiple times.
            // This is not a problem, so we can ignore exceptions here.
        }
    }

    private void publish(long orderId, EventTypeSpec spec) {
        UUID eventUuid = UUID.randomUUID();
        UUID streamUuid = orderStreamUuid(orderId);
        EventDescriptor descriptor = EventDescriptor.of(
            eventUuid.getMostSignificantBits(),
            eventUuid.getLeastSignificantBits(),
            streamUuid.getMostSignificantBits(),
            streamUuid.getLeastSignificantBits(),
            spec.ordinal(),
            spec.toDescriptorFlags(),
            System.currentTimeMillis()
        );
        eventEngine.bus().publish(descriptor, EventPayload.empty());
    }

    private static UUID orderStreamUuid(long orderId) {
        return UUID.nameUUIDFromBytes(("order-" + orderId).getBytes(StandardCharsets.UTF_8));
    }
}
