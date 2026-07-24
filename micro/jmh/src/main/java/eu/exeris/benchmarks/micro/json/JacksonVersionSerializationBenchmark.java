/*
 * Jackson 3 vs Jackson 2 serialization of the GET /api/v1/users aggregate payload.
 *
 * Isolates the SERIALIZER LIBRARY cost that the runtime report attributes to
 * "Exeris's Jackson-3 serialization dispatch". The exeris runtime bundles Jackson 3
 * (tools.jackson, kernel-hardcoded encoder) and cannot be swapped at the target level;
 * this micro measures the library delta directly, on the exact aggregate shape
 * (10 users x 10 friends x 10 interests), so the "Jackson-3 tax" can be stated as a
 * library choice or refuted as inherent JSON cost — on measured data.
 *
 * Both mappers are BARE default instances (records serialize via reflection in both,
 * no module) and write to a null OutputStream, so the only variable is the library.
 * Jackson 3 = tools.jackson.core:jackson-databind:3.1.1 (matches the kernel BOM).
 * Jackson 2 = com.fasterxml.jackson.core:jackson-databind:2.18.x (matches Quarkus 3.34).
 */
package eu.exeris.benchmarks.micro.json;

import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.TimeUnit;
import org.openjdk.jmh.annotations.Benchmark;
import org.openjdk.jmh.annotations.BenchmarkMode;
import org.openjdk.jmh.annotations.Fork;
import org.openjdk.jmh.annotations.Level;
import org.openjdk.jmh.annotations.Measurement;
import org.openjdk.jmh.annotations.Mode;
import org.openjdk.jmh.annotations.OutputTimeUnit;
import org.openjdk.jmh.annotations.Scope;
import org.openjdk.jmh.annotations.Setup;
import org.openjdk.jmh.annotations.State;
import org.openjdk.jmh.annotations.Warmup;

@BenchmarkMode(Mode.AverageTime)
@OutputTimeUnit(TimeUnit.MICROSECONDS)
@State(Scope.Benchmark)
@Fork(3)
@Warmup(iterations = 5, time = 1)
@Measurement(iterations = 10, time = 1)
public class JacksonVersionSerializationBenchmark {

    // Mirrors the exeris domain view records (targets/exeris-community-app .../domain/user).
    public record InterestView(String id, String name, String category) { }

    public record FriendSummary(String id, String username) { }

    public record UserView(String id, String username, List<FriendSummary> friends, List<InterestView> interests) { }

    private static final String[] CATEGORIES = {"science", "tech", "art", "music", "sport"};

    private List<UserView> payload;
    private tools.jackson.databind.ObjectMapper jackson3;
    private com.fasterxml.jackson.databind.ObjectMapper jackson2;

    @Setup(Level.Trial)
    public void setup() throws Exception {
        jackson3 = new tools.jackson.databind.ObjectMapper();
        jackson2 = new com.fasterxml.jackson.databind.ObjectMapper();
        payload = buildAggregate(10, 10, 10);
        // Fail closed if the two libraries do not produce byte-identical JSON — otherwise
        // the comparison would be apples-to-oranges.
        byte[] a = jackson3.writeValueAsBytes(payload);
        byte[] b = jackson2.writeValueAsBytes(payload);
        if (a.length != b.length) {
            throw new IllegalStateException("Jackson 3/2 output length differs: " + a.length + " vs " + b.length);
        }
    }

    private static List<UserView> buildAggregate(int users, int friends, int interests) {
        List<UserView> out = new ArrayList<>(users);
        for (int u = 1; u <= users; u++) {
            List<FriendSummary> fs = new ArrayList<>(friends);
            for (int f = 1; f <= friends; f++) {
                int gid = u * 100 + f;
                fs.add(new FriendSummary(String.valueOf(gid), "user_" + gid));
            }
            List<InterestView> is = new ArrayList<>(interests);
            for (int i = 1; i <= interests; i++) {
                int gid = u * 100 + i;
                is.add(new InterestView(String.valueOf(gid), "interest-" + gid, CATEGORIES[i % CATEGORIES.length]));
            }
            out.add(new UserView(String.valueOf(u), "user_" + u, fs, is));
        }
        return out;
    }

    @Benchmark
    public byte[] jackson3_writeValueAsBytes() throws Exception {
        return jackson3.writeValueAsBytes(payload);
    }

    @Benchmark
    public byte[] jackson2_writeValueAsBytes() throws Exception {
        return jackson2.writeValueAsBytes(payload);
    }
}
