package eu.exeris.benchmarks.targets.springapp.application.axon;

import org.axonframework.eventhandling.tokenstore.jdbc.TokenSchema;
import org.axonframework.eventsourcing.eventstore.jdbc.EventSchema;
import org.axonframework.modelling.saga.repository.jdbc.SagaSchema;

/**
 * Axon's JDBC schemas, named to match {@code runtime/db/seed/v3_outbox_axon.sql}.
 *
 * <p>Axon's defaults are entity-style identifiers — {@code TokenEntry}, {@code processorName},
 * {@code DomainEventEntry}, {@code metaData} — emitted unquoted, so PostgreSQL folds them to
 * {@code tokenentry} and {@code processorname}. The seed declares the snake_case names Axon's
 * JPA mapping produces. Left at their defaults the stores come up and then die on first use
 * with <em>relation "tokenentry" does not exist</em>.
 *
 * <p>Shared by both Axon arms so their physical schema is identical: the only difference
 * between the arms is where EVENTS live, and a schema divergence would add a second variable
 * to that comparison.
 */
final class AxonSeedSchemas {

    private AxonSeedSchemas() {
    }

    static EventSchema events() {
        return EventSchema.builder()
                .eventTable("domain_event_entry")
                .snapshotTable("snapshot_event_entry")
                .globalIndexColumn("global_index")
                .timestampColumn("time_stamp")
                .eventIdentifierColumn("event_identifier")
                .aggregateIdentifierColumn("aggregate_identifier")
                .sequenceNumberColumn("sequence_number")
                .typeColumn("type")
                .payloadTypeColumn("payload_type")
                .payloadRevisionColumn("payload_revision")
                .payloadColumn("payload")
                .metaDataColumn("meta_data")
                .build();
    }

    static TokenSchema tokens() {
        return TokenSchema.builder()
                .setTokenTable("token_entry")
                .setProcessorNameColumn("processor_name")
                .setSegmentColumn("segment")
                .setTokenColumn("token")
                .setTokenTypeColumn("token_type")
                .setTimestampColumn("timestamp")
                .setOwnerColumn("owner")
                .build();
    }

    static SagaSchema sagas() {
        return SagaSchema.builder()
                .sagaEntryTable("saga_entry")
                .sagaIdColumn("saga_id")
                .sagaTypeColumn("saga_type")
                .revisionColumn("revision")
                .serializedSagaColumn("serialized_saga")
                .associationValueEntryTable("association_value_entry")
                .associationKeyColumn("association_key")
                .associationValueColumn("association_value")
                .build();
    }
}
