package eu.exeris.kernel.benchmark.target.runtime.spi;

import eu.exeris.kernel.benchmark.target.api.BenchmarkSeedFingerprint;
import eu.exeris.kernel.benchmark.target.seed.BenchmarkSeedPlan;
import eu.exeris.kernel.benchmark.target.seed.BenchmarkSeedResult;

import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.time.Instant;
import java.util.Comparator;
import java.util.HexFormat;
import java.util.List;
import java.util.Map;

public final class SpiCoreLogicalBenchmarkSeeder {

    public BenchmarkSeedResult seed(BenchmarkSeedPlan plan) {
    String checksum = checksumFor(plan);
        BenchmarkSeedFingerprint fingerprint = new BenchmarkSeedFingerprint(
                plan.datasetId(),
                "spi-core-phase-4-logical-seed-v1",
                checksum,
                Instant.now());
        return new BenchmarkSeedResult(
                plan.datasetId(),
                fingerprint,
                false,
                List.of(
                        "Logical seed plan fingerprinted from runtime descriptor, capabilities, selector, and scenario catalog metadata.",
                        "No physical persistence, schema, or graph seeding was performed by the SPI+CORE phase-4 path."));
    }

    static String canonicalSeedInput(BenchmarkSeedPlan plan) {
        StringBuilder builder = new StringBuilder();
        builder.append("datasetId=").append(plan.datasetId()).append('\n');
        builder.append("resetPolicy=").append(plan.resetPolicy().name()).append('\n');
        plan.parameters().entrySet().stream()
                .sorted(Comparator.comparing(Map.Entry::getKey))
                .forEach(entry -> builder.append(entry.getKey())
                        .append('=')
                        .append(entry.getValue())
                        .append('\n'));
        return builder.toString();
    }

    static String checksumFor(BenchmarkSeedPlan plan) {
        return sha256(canonicalSeedInput(plan));
    }

    static String sha256(String input) {
        try {
            MessageDigest digest = MessageDigest.getInstance("SHA-256");
            return HexFormat.of().formatHex(digest.digest(input.getBytes(StandardCharsets.UTF_8)));
        } catch (NoSuchAlgorithmException exception) {
            throw new IllegalStateException("SHA-256 must be available in the JDK", exception);
        }
    }
}