package eu.exeris.benchmarks.targets.exeriscommunity.infrastructure.persistence;

import eu.exeris.kernel.spi.persistence.EventStore;
import eu.exeris.kernel.spi.persistence.PersistenceConnection;
import eu.exeris.kernel.spi.persistence.PersistenceStatement;
import eu.exeris.kernel.spi.persistence.QueryResult;
import eu.exeris.kernel.spi.persistence.RowCursor;

import java.util.ArrayList;
import java.util.List;
import java.util.UUID;

/**
 * App-owned transactional outbox {@link EventStore} implemented purely against the persistence SPI
 * ({@code eu.exeris.kernel.spi.persistence}).
 *
 * <p>This replaces the former direct use of
 * {@code eu.exeris.kernel.community.persistence.jdbc.CommunityJdbcEventStore} so the benchmark target
 * compiles against SPI + CORE only and the kernel edition (community / enterprise) stays a pure
 * runtime driver on the classpath. The SQL is byte-for-byte the kernel-native outbox contract
 * (table {@code exeris_outbox}); see the e2e-shop-order-saga seed migration
 * {@code V3_E2E_SAGA_KERNEL_OUTBOX}. It is edition-agnostic — nothing here is community-specific.
 */
public final class JdbcOutboxEventStore implements EventStore {

    private static final String SQL_APPEND =
        "INSERT INTO exeris_outbox (id, aggregate_id, aggregate_type, event_type, payload, occurred_at) "
        + "VALUES ($1, $2, $3, $4, $5, $6)";

    private static final String SQL_POLL_PENDING =
        "SELECT id, aggregate_id, aggregate_type, event_type, payload, occurred_at FROM exeris_outbox "
        + "WHERE published_at IS NULL ORDER BY outbox_seq ASC LIMIT $1 FOR UPDATE SKIP LOCKED";

    private static final String SQL_MARK_PUBLISHED =
        "UPDATE exeris_outbox SET published_at = $1 WHERE id = $2";

    private final PersistenceConnection connection;

    public JdbcOutboxEventStore(PersistenceConnection connection) {
        if (connection == null) {
            throw new IllegalArgumentException("connection must not be null");
        }
        this.connection = connection;
    }

    @Override
    public void append(OutboxEvent event) {
        if (event == null) {
            throw new IllegalArgumentException("event must not be null");
        }
        requireActiveTransaction();
        try (PersistenceStatement stmt = connection.prepare(SQL_APPEND)) {
            stmt.bindUuid(0, event.eventId())
                .bindString(1, event.aggregateId())
                .bindString(2, event.aggregateType())
                .bindString(3, event.eventType())
                .bindBytes(4, event.payload())
                .bindLong(5, event.occurredAt())
                .executeUpdate();
        }
    }

    @Override
    public List<OutboxEvent> pollPending(int limit) {
        requireActiveTransaction();
        List<OutboxEvent> pending = new ArrayList<>();
        try (PersistenceStatement stmt = connection.prepare(SQL_POLL_PENDING)) {
            stmt.bindLong(0, limit);
            try (QueryResult result = stmt.executeQuery()) {
                while (result.next()) {
                    RowCursor row = result.row();
                    pending.add(new OutboxEvent(
                        row.getUuid(0),
                        row.getString(1),
                        row.getString(2),
                        row.getString(3),
                        row.getBytes(4),
                        row.getLong(5)
                    ));
                }
            }
        }
        return pending;
    }

    @Override
    public void markPublished(UUID eventId) {
        if (eventId == null) {
            throw new IllegalArgumentException("eventId must not be null");
        }
        requireActiveTransaction();
        try (PersistenceStatement stmt = connection.prepare(SQL_MARK_PUBLISHED)) {
            stmt.bindLong(0, System.currentTimeMillis())
                .bindUuid(1, eventId)
                .executeUpdate();
        }
    }

    private void requireActiveTransaction() {
        if (!connection.inTransaction()) {
            throw new IllegalStateException("EventStore operation requires an active transaction");
        }
    }
}
