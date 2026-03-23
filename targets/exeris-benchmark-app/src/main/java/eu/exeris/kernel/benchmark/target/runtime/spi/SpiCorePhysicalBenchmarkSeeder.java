package eu.exeris.kernel.benchmark.target.runtime.spi;

import eu.exeris.kernel.benchmark.target.api.BenchmarkSeedFingerprint;
import eu.exeris.kernel.benchmark.target.seed.BenchmarkSeedPlan;
import eu.exeris.kernel.benchmark.target.seed.BenchmarkSeedResult;
import eu.exeris.kernel.spi.context.KernelProviders;
import eu.exeris.kernel.spi.persistence.PersistenceConnection;
import eu.exeris.kernel.spi.persistence.PersistenceStatement;

import java.time.Instant;
import java.util.List;

public final class SpiCorePhysicalBenchmarkSeeder {

    private static final String TABLE_NAME = "benchmark_seed_manifest";

    public BenchmarkSeedResult seed(
            BenchmarkSeedPlan plan,
            BenchmarkSeedResult priorResult,
            boolean persistenceSelected,
            boolean persistenceBound) {
        if (!persistenceSelected || !persistenceBound) {
            return new BenchmarkSeedResult(
                    priorResult.datasetId(),
                    priorResult.fingerprint(),
                    false,
                    List.of(
                            "Phase 5 physical persistence seed skipped because persistence subsystem is not selected or not bound.",
                            "Logical fingerprint remains authoritative for this run."));
        }

        String canonicalPlan = SpiCoreLogicalBenchmarkSeeder.canonicalSeedInput(plan);
        String checksum = SpiCoreLogicalBenchmarkSeeder.sha256(canonicalPlan);
        BenchmarkSeedFingerprint fingerprint = new BenchmarkSeedFingerprint(
                plan.datasetId(),
                "spi-core-phase-5-physical-seed-v1",
                checksum,
                Instant.now());

        try (PersistenceConnection connection = KernelProviders.persistenceEngine().openConnection()) {
            connection.beginTransaction();
            try {
                connection.executeUpdate(createManifestTableSql());
                try (PersistenceStatement delete = connection.prepare(
                        "DELETE FROM " + TABLE_NAME + " WHERE dataset_id = $1")) {
                    delete.bindString(0, plan.datasetId());
                    delete.executeUpdate();
                }
                try (PersistenceStatement insert = connection.prepare(insertManifestSql())) {
                    insert.bindString(0, plan.datasetId());
                    insert.bindString(1, fingerprint.revision());
                    insert.bindString(2, fingerprint.checksum());
                    insert.bindString(3, fingerprint.capturedAt().toString());
                    insert.bindString(4, plan.resetPolicy().name());
                    insert.bindString(5, canonicalPlan);
                    insert.executeUpdate();
                }
                connection.commit();
            } catch (RuntimeException failure) {
                rollbackQuietly(connection);
                throw failure;
            }
        }

        return new BenchmarkSeedResult(
                plan.datasetId(),
                fingerprint,
                true,
                List.of(
                        "Phase 5 physical persistence seed manifest row persisted transactionally.",
                        "Seed checksum derived from canonical BenchmarkSeedPlan representation."));
    }

    private static String createManifestTableSql() {
        return "CREATE TABLE IF NOT EXISTS " + TABLE_NAME + " ("
                + "dataset_id VARCHAR(255) PRIMARY KEY,"
                + "fingerprint_revision VARCHAR(128) NOT NULL,"
                + "fingerprint_checksum VARCHAR(128) NOT NULL,"
                + "applied_at_utc VARCHAR(64) NOT NULL,"
                + "reset_policy VARCHAR(64) NOT NULL,"
                + "canonical_plan TEXT NOT NULL"
                + ")";
    }

    private static String insertManifestSql() {
        return "INSERT INTO " + TABLE_NAME
                + " (dataset_id, fingerprint_revision, fingerprint_checksum, applied_at_utc, reset_policy, canonical_plan)"
                + " VALUES ($1, $2, $3, $4, $5, $6)";
    }

    private static void rollbackQuietly(PersistenceConnection connection) {
        if (!connection.inTransaction()) {
            return;
        }
        try {
            connection.rollback();
        } catch (RuntimeException ignored) {
            // Ignore rollback failure and preserve the original exception.
        }
    }
}