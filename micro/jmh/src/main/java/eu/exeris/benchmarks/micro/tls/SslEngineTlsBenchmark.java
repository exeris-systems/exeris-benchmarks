package eu.exeris.benchmarks.micro.tls;

import org.openjdk.jmh.annotations.*;
import org.openjdk.jmh.infra.Blackhole;

import javax.net.ssl.*;
import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.nio.ByteBuffer;
import java.nio.file.Files;
import java.nio.file.Path;
import java.security.*;
import java.security.cert.X509Certificate;
import java.util.ArrayList;
import java.util.List;
import java.util.Locale;
import java.util.concurrent.TimeUnit;

/**
 * B3 — JDK SSLEngine record-path comparative benchmark.
 *
 * <h2>Matrix position</h2>
 * <pre>
 * matrix_id : B3
 * tier       : community  (JDK SSLEngine — no Exeris dependency)
 * protocol   : tcp-tls-1.3
 * family     : B (steady-state record path)
 * axis       : implementation-variant
 * </pre>
 *
 * <h2>What is measured</h2>
 * <p>Steady-state {@code wrap} (encrypt) and {@code unwrap} (decrypt) throughput of the
 * JDK's {@link SSLEngine} using heap/direct {@link ByteBuffer}s, across four payload sizes.
 * This is the reference implementation against which Exeris OffHeapTlsEngine is compared.
 * Key contractual difference: JDK SSLEngine copies data through heap {@code byte[]} arrays;
 * Exeris OffHeapTlsEngine operates on off-heap {@code MemorySegment}s with zero heap
 * allocation in steady state.
 *
 * <h2>Payloads</h2>
 * <p>128 B, 1 KB, 4 KB, 16 KB — swept via {@link Param}.
 *
 * <h2>Allocation evidence</h2>
 * <p>Run with {@code -prof gc} to collect {@code norm.alloc} per operation.
 * Run with {@code -prof jfr:stackDepth=64;dir=results/jfr/B3} for JFR recordings.
 * Expected: JDK SSLEngine allocates non-trivially per wrap/unwrap; Exeris: 0 B/op.
 *
 * <h2>Fairness</h2>
 * <ul>
 *   <li>Same {@code @Fork}, warmup, and measurement windows as
 *       {@code AbstractTlsEngineBenchmark} in exeris-kernel-tck.</li>
 *   <li>TLS 1.3 only — no fallback to TLS 1.2.</li>
 *   <li>In-memory loopback pair — no real sockets.</li>
 * </ul>
 *
 * <h2>Run</h2>
 * <pre>
 *   cd micro/jmh && mvn clean package -DskipTests
 *   java -jar target/benchmarks.jar SslEngineTlsBenchmark -wi 5 -i 5 -f 1 \
 *        -prof gc -rf json -rff results-B3.json
 *   # With JFR alloc recording:
 *   java -jar target/benchmarks.jar SslEngineTlsBenchmark -wi 5 -i 5 -f 1 \
 *        -prof "jfr:stackDepth=64;dir=results/jfr/B3" -rf json -rff results-B3-jfr.json
 * </pre>
 *
 * @since 1.0.0
 */
@State(Scope.Thread)
@BenchmarkMode({Mode.Throughput, Mode.SampleTime})
@OutputTimeUnit(TimeUnit.MICROSECONDS)
@Warmup(iterations = 5, time = 3, timeUnit = TimeUnit.SECONDS)
@Measurement(iterations = 10, time = 5, timeUnit = TimeUnit.SECONDS)
// Publication-safe default; CLI/manifest may override for smoke/profile runs.
@Fork(value = 3, jvmArgsAppend = {
        // ZGC, heap, and module-open flags are injected by the manifest harness
        // (common_jvm_args via run-jmh-case.sh) and propagated to forks via JMH
        // runner-process inheritance. Duplicating them here causes the double-entry
        // visible in '# VM options:' JMH output. Keep only the annotation-specific flag.
        "-XX:+PreserveFramePointer"
    })
public class SslEngineTlsBenchmark {

    /** Payload sizes in bytes: 128 B, 1 KB, 4 KB, 16 KB (TLS record max). */
    @Param({"128", "1024", "4096", "16384"})
    public int payloadBytes;

    @Param({"direct"})
    public String bufferKind;

    @Param({"TLS_AES_256_GCM_SHA384"})
    public String cipherSuite;

    private SSLEngine clientEngine;
    private SSLEngine serverEngine;

    private ByteBuffer clientPlaintext;
    private ByteBuffer clientCiphertext;
    private ByteBuffer serverPlaintext;
    private ByteBuffer empty;

    /** Sized to hold TLS record max (16 384 app bytes + TLS overhead). */
    private static final int NET_BUFFER_SIZE = 16_384 + 2048;

    @Setup(Level.Trial)
    public void setUp() throws Exception {
        SSLContext ctx = buildSslContext();

        clientEngine = ctx.createSSLEngine();
        serverEngine = ctx.createSSLEngine();
        clientEngine.setUseClientMode(true);
        serverEngine.setUseClientMode(false);
        serverEngine.setNeedClientAuth(false);
        clientEngine.setEnabledProtocols(new String[]{"TLSv1.3"});
        serverEngine.setEnabledProtocols(new String[]{"TLSv1.3"});
        clientEngine.setEnabledCipherSuites(new String[]{cipherSuite});
        serverEngine.setEnabledCipherSuites(new String[]{cipherSuite});

        clientPlaintext  = allocateBuffer(NET_BUFFER_SIZE);
        clientCiphertext = allocateBuffer(NET_BUFFER_SIZE);
        serverPlaintext  = allocateBuffer(NET_BUFFER_SIZE);
        empty            = allocateBuffer(0);

        fillPayload(clientPlaintext, payloadBytes);

        performHandshake();
    }

    @TearDown(Level.Trial)
    public void tearDown() {
        if (clientEngine != null) clientEngine.closeOutbound();
        if (serverEngine != null) serverEngine.closeOutbound();
    }

    @Setup(Level.Iteration)
    public void markMeasurementStart() {
        PhaseMarkerEvent event = new PhaseMarkerEvent();
        event.phase = "measurement";
        event.iteration = 0;
        event.benchmarkClass = getClass().getSimpleName();
        event.commit();
    }

    /**
     * B3-W: wrap (encrypt) throughput.
     *
     * <p>Measures JDK SSLEngine heap allocation per encrypted record.
     * Reference: Exeris B1 (CoreOffHeapTlsEngineBenchmark) targets 0 B/op.
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
     * B3-RT: wrap + unwrap round-trip latency.
     *
     * <p>Full symmetric record path: encrypt on client, decrypt on server.
     * Comparable to AbstractTlsEngineBenchmark#wrapUnwrapRoundTrip.
     */
    @Benchmark
    @BenchmarkMode(Mode.SampleTime)
    @OutputTimeUnit(TimeUnit.MICROSECONDS)
    @OperationsPerInvocation(2)
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
    // Helpers
    // -------------------------------------------------------------------------

    private static SSLContext buildSslContext() throws Exception {
        char[] password = "changeit".toCharArray();
        KeyStore ks = loadEphemeralPkcs12KeyStore();

        TrustManager[] trustAll = new TrustManager[]{
            new X509TrustManager() {
                @Override
                public void checkClientTrusted(X509Certificate[] c, String a) {}

                @Override
                public void checkServerTrusted(X509Certificate[] c, String a) {}

                @Override
                public X509Certificate[] getAcceptedIssuers() { return new X509Certificate[0]; }
            }
        };

        KeyManagerFactory kmf = KeyManagerFactory.getInstance(
                KeyManagerFactory.getDefaultAlgorithm());
        kmf.init(ks, password);

        SSLContext ctx = SSLContext.getInstance("TLSv1.3");
        ctx.init(kmf.getKeyManagers(), trustAll, new SecureRandom());
        return ctx;
    }

    private static KeyStore loadEphemeralPkcs12KeyStore() throws Exception {
        char[] password = "changeit".toCharArray();
        Path temp = Files.createTempFile("exeris-b3-", ".p12");
        Files.delete(temp); // JDK 26 keytool rejects writing to an existing (even empty) keystore file
        try {
            List<String> command = new ArrayList<>();
            command.add(detectKeytoolBinary());
            command.add("-genkeypair");
            command.add("-alias");
            command.add("bench");
            command.add("-storetype");
            command.add("PKCS12");
            command.add("-keystore");
            command.add(temp.toString());
            command.add("-storepass");
            command.add("changeit");
            command.add("-keypass");
            command.add("changeit");
            command.add("-keyalg");
            command.add("RSA");
            command.add("-keysize");
            command.add("2048");
            command.add("-sigalg");
            command.add("SHA256withRSA");
            command.add("-validity");
            command.add("365");
            command.add("-dname");
            command.add("CN=exeris-bench, O=Exeris Systems, C=PL");
            command.add("-ext");
            command.add("SAN=dns:localhost,ip:127.0.0.1");
            command.add("-noprompt");

            Process process = new ProcessBuilder(command)
                    .redirectErrorStream(true)
                    .start();
            String output;
            try (InputStream input = process.getInputStream()) {
                output = slurp(input);
            }
            int exit = process.waitFor();
            if (exit != 0) {
                throw new IllegalStateException("keytool failed with exit code " + exit + ":\n" + output);
            }

            KeyStore ks = KeyStore.getInstance("PKCS12");
            try (InputStream in = Files.newInputStream(temp)) {
                ks.load(in, password);
            }
            return ks;
        } finally {
            Files.deleteIfExists(temp);
        }
    }

    private static String detectKeytoolBinary() {
        String javaHome = System.getProperty("java.home", "");
        Path javaHomePath = Path.of(javaHome);
        String os = System.getProperty("os.name", "").toLowerCase(Locale.ROOT);
        String binaryName = os.contains("win") ? "keytool.exe" : "keytool";
        Path candidate = javaHomePath.resolve("bin").resolve(binaryName);
        if (Files.isRegularFile(candidate) && Files.isExecutable(candidate)) {
            return candidate.toString();
        }
        return "keytool";
    }

    private static String slurp(InputStream input) throws IOException {
        ByteArrayOutputStream out = new ByteArrayOutputStream();
        byte[] buf = new byte[4096];
        int read;
        while ((read = input.read(buf)) != -1) {
            out.write(buf, 0, read);
        }
        return out.toString(java.nio.charset.StandardCharsets.UTF_8);
    }

    private void performHandshake() throws SSLException {
        clientEngine.beginHandshake();
        serverEngine.beginHandshake();

        ByteBuffer cToS = allocateBuffer(NET_BUFFER_SIZE);
        ByteBuffer sToC = allocateBuffer(NET_BUFFER_SIZE);
        ByteBuffer scratch = allocateBuffer(NET_BUFFER_SIZE);

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
        assertCipherSuitePinned(clientEngine, "client");
        assertCipherSuitePinned(serverEngine, "server");

        // Restore plaintext after handshake has consumed it.
        fillPayload(clientPlaintext, payloadBytes);
    }

    private ByteBuffer allocateBuffer(int capacity) {
        if ("heap".equals(bufferKind)) {
            return ByteBuffer.allocate(capacity);
        }
        if ("direct".equals(bufferKind)) {
            return ByteBuffer.allocateDirect(capacity);
        }
        throw new IllegalStateException("Unsupported bufferKind: " + bufferKind);
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
        for (int i = 0; i < len; i++) {
            buf.put((byte) (i & 0xFF));
        }
        buf.flip();
    }

    private void assertCipherSuitePinned(SSLEngine engine, String side) {
        String negotiated = engine.getSession().getCipherSuite();
        if (!cipherSuite.equals(negotiated)) {
            throw new IllegalStateException("Expected negotiated cipher suite " + cipherSuite
                    + " on " + side + " engine but got " + negotiated);
        }
    }
}
