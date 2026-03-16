package eu.exeris.benchmarks.micro.tls;

import org.openjdk.jmh.annotations.*;
import org.openjdk.jmh.infra.Blackhole;

import javax.net.ssl.SSLEngine;
import javax.net.ssl.SSLEngineResult;
import javax.net.ssl.SSLException;
import java.nio.ByteBuffer;
import java.util.concurrent.TimeUnit;

/**
 * B4 — netty-tcnative-boringssl-static record-path comparative benchmark.
 *
 * <h2>Matrix position</h2>
 * <pre>
 * matrix_id : B4
 * tier       : community  (tcnative SSLEngine — no Exeris dependency)
 * protocol   : tcp-tls-1.3
 * family     : B (steady-state record path)
 * axis       : implementation-variant
 * </pre>
 *
 * <h2>What is measured</h2>
 * <p>Steady-state {@code wrap}/{@code unwrap} throughput of netty's
 * {@code ReferenceCountedOpenSslEngine} (BoringSSL via JNI), accessed through the
 * standard {@link SSLEngine} API. Same measurement axis as B3 but with a JNI-native
 * provider instead of JDK JSSE.
 *
 * <h2>Dependency</h2>
 * <p>Requires {@code io.netty:netty-tcnative-boringssl-static} on the classpath.
 * When absent this benchmark fails fast in {@code setUp()} with a clear message.
 * To enable, uncomment the dependency block in {@code micro/jmh/pom.xml} and rebuild.
 *
 * <h2>Payloads</h2>
 * <p>Same four sizes as B3: 128 B, 1 KB, 4 KB, 16 KB.
 *
 * <h2>Allocation evidence</h2>
 * <p>Run with {@code -prof gc} or {@code -prof jfr:stackDepth=64;dir=results/jfr/B4}.
 * Expected: tcnative should show lower heap allocation than JDK SSLEngine but non-zero
 * due to JNI result boxing and per-record internal state.
 *
 * <h2>Fairness</h2>
 * <ul>
 *   <li>Same {@code @Fork}, warmup, and measurement windows as B3 and
 *       {@code AbstractTlsEngineBenchmark}.</li>
 *   <li>TLS 1.3 only. Direct {@link ByteBuffer}s (tcnative performs best with direct).</li>
 *   <li>In-memory loopback pair — no real sockets.</li>
 * </ul>
 *
 * <h2>Run (after uncommenting pom.xml dep)</h2>
 * <pre>
 *   cd micro/jmh && mvn clean package -DskipTests
 *   java -jar target/benchmarks.jar NettyTcNativeTlsBenchmark -wi 5 -i 5 -f 1 \
 *        -prof gc -rf json -rff results-B4.json
 *   # With JFR alloc recording:
 *   java -jar target/benchmarks.jar NettyTcNativeTlsBenchmark -wi 5 -i 5 -f 1 \
 *        -prof "jfr:stackDepth=64;dir=results/jfr/B4" -rf json -rff results-B4-jfr.json
 * </pre>
 *
 * @since 1.0.0
 */
@State(Scope.Thread)
@BenchmarkMode({Mode.Throughput, Mode.SampleTime})
@OutputTimeUnit(TimeUnit.MICROSECONDS)
@Warmup(iterations = 5, time = 2, timeUnit = TimeUnit.SECONDS)
@Measurement(iterations = 5, time = 5, timeUnit = TimeUnit.SECONDS)
@Fork(value = 1, jvmArgsAppend = {
        "-XX:+UseZGC",
        "-XX:+UnlockExperimentalVMOptions",
        "-Xms256m", "-Xmx256m"
})
public class NettyTcNativeTlsBenchmark {

    /** Payload sizes in bytes: 128 B, 1 KB, 4 KB, 16 KB. */
    @Param({"128", "1024", "4096", "16384"})
    public int payloadBytes;

    private SSLEngine clientEngine;
    private SSLEngine serverEngine;

    private ByteBuffer clientPlaintext;
    private ByteBuffer clientCiphertext;
    private ByteBuffer serverPlaintext;
    private ByteBuffer empty;

    private static final int NET_BUFFER_SIZE = 16_384 + 2048;

    @Setup(Level.Trial)
    public void setUp() throws Exception {
        if (!probeClasspath()) {
            throw new IllegalStateException(
                    "B4 requires netty-tcnative-boringssl-static on classpath. "
                    + "Uncomment the dependency in micro/jmh/pom.xml and rebuild.");
        }

        Object[] engines = buildEngines();
        clientEngine = (SSLEngine) engines[0];
        serverEngine = (SSLEngine) engines[1];

        clientPlaintext  = ByteBuffer.allocateDirect(NET_BUFFER_SIZE);
        clientCiphertext = ByteBuffer.allocateDirect(NET_BUFFER_SIZE);
        serverPlaintext  = ByteBuffer.allocateDirect(NET_BUFFER_SIZE);
        empty            = ByteBuffer.allocateDirect(0);

        fillPayload(clientPlaintext, payloadBytes);
        performHandshake();
    }

    @TearDown(Level.Trial)
    public void tearDown() {
        if (clientEngine != null) clientEngine.closeOutbound();
        if (serverEngine != null) serverEngine.closeOutbound();
    }

    /**
     * B4-W: wrap (encrypt) throughput via tcnative BoringSSL engine.
     */
    @Benchmark
    @BenchmarkMode(Mode.Throughput)
    @OutputTimeUnit(TimeUnit.SECONDS)
    public void wrapThroughput(Blackhole bh) throws SSLException {
        clientPlaintext.clear().limit(payloadBytes);
        clientCiphertext.clear();
        SSLEngineResult result = clientEngine.wrap(clientPlaintext, clientCiphertext);
        bh.consume(result.getStatus());
        bh.consume(result.bytesProduced());
    }

    /**
     * B4-RT: wrap + unwrap round-trip via tcnative BoringSSL engines.
     */
    @Benchmark
    @BenchmarkMode(Mode.SampleTime)
    @OutputTimeUnit(TimeUnit.MICROSECONDS)
    public void wrapUnwrapRoundTrip(Blackhole bh) throws SSLException {
        clientPlaintext.clear().limit(payloadBytes);
        clientCiphertext.clear();
        SSLEngineResult wrap = clientEngine.wrap(clientPlaintext, clientCiphertext);
        bh.consume(wrap.getStatus());

        clientCiphertext.flip();
        serverPlaintext.clear();
        SSLEngineResult unwrap = serverEngine.unwrap(clientCiphertext, serverPlaintext);
        bh.consume(unwrap.getStatus());
        bh.consume(unwrap.bytesProduced());
    }

    // -------------------------------------------------------------------------
    // Helpers — all netty access via reflection to avoid hard compile-time dep
    // -------------------------------------------------------------------------

    private static boolean probeClasspath() {
        try {
            Class.forName("io.netty.handler.ssl.SslContextBuilder");
            Class.forName("io.netty.handler.ssl.SslProvider");
            return true;
        } catch (ClassNotFoundException e) {
            return false;
        }
    }

    /**
     * Builds a client/server SSLEngine pair backed by netty-tcnative BoringSSL.
     * All netty class access is via reflection so the module compiles when
     * netty is absent from the classpath.
     *
     * @return {@code Object[]{clientEngine, serverEngine}}
     */
    private static Object[] buildEngines() throws Exception {
        Class<?> sslProviderClass = Class.forName("io.netty.handler.ssl.SslProvider");
        Object openSslProvider = sslProviderClass.getField("OPENSSL").get(null);

        Class<?> builderClass = Class.forName("io.netty.handler.ssl.SslContextBuilder");

        // Self-signed cert from netty's SelfSignedCertificate helper.
        Class<?> sscClass = Class.forName("io.netty.handler.ssl.util.SelfSignedCertificate");
        Object ssc = sscClass.getDeclaredConstructor().newInstance();
        java.io.File cert = (java.io.File) sscClass.getMethod("certificate").invoke(ssc);
        java.io.File key  = (java.io.File) sscClass.getMethod("privateKey").invoke(ssc);

        // Server SslContext
        Object sb = builderClass.getMethod("forServer", java.io.File.class, java.io.File.class)
                .invoke(null, cert, key);
        sb = builderClass.getMethod("sslProvider", sslProviderClass).invoke(sb, openSslProvider);
        sb = builderClass.getMethod("protocols", String[].class)
                .invoke(sb, (Object) new String[]{"TLSv1.3"});
        Object serverCtx = builderClass.getMethod("build").invoke(sb);

        // Client SslContext — trust all (benchmark only)
        Class<?> insecureClass = Class.forName(
                "io.netty.handler.ssl.util.InsecureTrustManagerFactory");
        Object insecure = insecureClass.getField("INSTANCE").get(null);

        Object cb = builderClass.getMethod("forClient").invoke(null);
        cb = builderClass.getMethod("sslProvider", sslProviderClass).invoke(cb, openSslProvider);
        cb = builderClass.getMethod("trustManager", javax.net.ssl.TrustManagerFactory.class)
                .invoke(cb, insecure);
        cb = builderClass.getMethod("protocols", String[].class)
                .invoke(cb, (Object) new String[]{"TLSv1.3"});
        Object clientCtx = builderClass.getMethod("build").invoke(cb);

        // Extract SSLEngine from netty SslContext via newEngine(ByteBufAllocator, String, int)
        // Use the simpler newEngine() variant when available.
        Class<?> sslCtxClass = Class.forName("io.netty.handler.ssl.SslContext");
        Class<?> bbAllocClass = Class.forName("io.netty.buffer.ByteBufAllocator");
        Object defaultAlloc = bbAllocClass.getField("DEFAULT").get(null);

        SSLEngine clientEngine = (SSLEngine) sslCtxClass
                .getMethod("newEngine", bbAllocClass).invoke(clientCtx, defaultAlloc);
        SSLEngine serverEngine = (SSLEngine) sslCtxClass
                .getMethod("newEngine", bbAllocClass).invoke(serverCtx, defaultAlloc);

        clientEngine.setUseClientMode(true);
        serverEngine.setUseClientMode(false);
        serverEngine.setNeedClientAuth(false);
        clientEngine.setEnabledProtocols(new String[]{"TLSv1.3"});
        serverEngine.setEnabledProtocols(new String[]{"TLSv1.3"});

        return new Object[]{clientEngine, serverEngine};
    }

    private void performHandshake() throws SSLException {
        clientEngine.beginHandshake();
        serverEngine.beginHandshake();

        ByteBuffer cToS = ByteBuffer.allocateDirect(NET_BUFFER_SIZE);
        ByteBuffer sToC = ByteBuffer.allocateDirect(NET_BUFFER_SIZE);
        ByteBuffer scratch = ByteBuffer.allocateDirect(NET_BUFFER_SIZE);

        for (int step = 0; step < 256; step++) {
            boolean progress = false;
            progress |= runDelegatedTasks(clientEngine);
            progress |= runDelegatedTasks(serverEngine);
            progress |= handshakeWrap(clientEngine, cToS, "client");
            progress |= handshakeUnwrap(serverEngine, cToS, scratch, "server");
            progress |= handshakeWrap(serverEngine, sToC, "server");
            progress |= handshakeUnwrap(clientEngine, sToC, scratch, "client");

            if (isHandshakeComplete(clientEngine) && isHandshakeComplete(serverEngine)) {
                break;
            }
            if (!progress) {
                throw new IllegalStateException("Handshake stalled: client="
                        + clientEngine.getHandshakeStatus() + ", server="
                        + serverEngine.getHandshakeStatus());
            }
        }

        if (!isHandshakeComplete(clientEngine) || !isHandshakeComplete(serverEngine)) {
            throw new IllegalStateException("Handshake did not complete: client="
                    + clientEngine.getHandshakeStatus() + ", server="
                    + serverEngine.getHandshakeStatus());
        }
        if (!clientEngine.getSession().isValid() || !serverEngine.getSession().isValid()) {
            throw new IllegalStateException("Handshake completed with invalid session");
        }

        fillPayload(clientPlaintext, payloadBytes);
    }

    private static boolean runDelegatedTasks(SSLEngine engine) {
        boolean ranTask = false;
        while (engine.getHandshakeStatus() == SSLEngineResult.HandshakeStatus.NEED_TASK) {
            Runnable task = engine.getDelegatedTask();
            if (task == null) {
                break;
            }
            task.run();
            ranTask = true;
        }
        return ranTask;
    }

    private boolean handshakeWrap(SSLEngine engine, ByteBuffer out, String side) throws SSLException {
        if (engine.getHandshakeStatus() != SSLEngineResult.HandshakeStatus.NEED_WRAP) {
            return false;
        }
        SSLEngineResult.HandshakeStatus before = engine.getHandshakeStatus();
        int beforePos = out.position();
        SSLEngineResult result = engine.wrap(empty, out);
        if (result.getStatus() == SSLEngineResult.Status.CLOSED
                || result.getStatus() == SSLEngineResult.Status.BUFFER_OVERFLOW) {
            throw new IllegalStateException("Unexpected wrap status for " + side + ": " + result);
        }
        return result.bytesProduced() > 0
                || result.bytesConsumed() > 0
                || before != result.getHandshakeStatus()
                || out.position() != beforePos;
    }

    private static boolean handshakeUnwrap(
            SSLEngine engine,
            ByteBuffer in,
            ByteBuffer scratch,
            String side) throws SSLException {
        if (engine.getHandshakeStatus() != SSLEngineResult.HandshakeStatus.NEED_UNWRAP || in.position() == 0) {
            return false;
        }
        SSLEngineResult.HandshakeStatus before = engine.getHandshakeStatus();
        in.flip();
        scratch.clear();
        SSLEngineResult result = engine.unwrap(in, scratch);
        in.compact();
        if (result.getStatus() == SSLEngineResult.Status.CLOSED
                || result.getStatus() == SSLEngineResult.Status.BUFFER_OVERFLOW) {
            throw new IllegalStateException("Unexpected unwrap status for " + side + ": " + result);
        }
        if (result.getStatus() != SSLEngineResult.Status.OK
                && result.getStatus() != SSLEngineResult.Status.BUFFER_UNDERFLOW) {
            throw new IllegalStateException("Invalid unwrap status for " + side + ": " + result);
        }
        return result.bytesProduced() > 0
                || result.bytesConsumed() > 0
                || before != result.getHandshakeStatus();
    }

    private static boolean isHandshakeComplete(SSLEngine engine) {
        SSLEngineResult.HandshakeStatus status = engine.getHandshakeStatus();
        return status == SSLEngineResult.HandshakeStatus.FINISHED
                || status == SSLEngineResult.HandshakeStatus.NOT_HANDSHAKING;
    }

    private static void fillPayload(ByteBuffer buf, int len) {
        buf.clear();
        for (int i = 0; i < len; i++) buf.put((byte) (i & 0xFF));
        buf.flip();
    }
}
