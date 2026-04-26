package eu.exeris.benchmarks.micro.tls;

import io.netty.buffer.ByteBuf;
import io.netty.buffer.ByteBufAllocator;
import io.netty.buffer.ByteBufHolder;
import io.netty.buffer.PooledByteBufAllocator;
import io.netty.channel.embedded.EmbeddedChannel;
import io.netty.handler.ssl.OpenSsl;
import io.netty.handler.ssl.SslContext;
import io.netty.handler.ssl.SslContextBuilder;
import io.netty.handler.ssl.SslHandler;
import io.netty.handler.ssl.SslProvider;
import io.netty.handler.ssl.util.InsecureTrustManagerFactory;
import io.netty.util.ReferenceCounted;
import io.netty.util.concurrent.Future;
import org.openjdk.jmh.annotations.Benchmark;
import org.openjdk.jmh.annotations.BenchmarkMode;
import org.openjdk.jmh.annotations.Fork;
import org.openjdk.jmh.annotations.Measurement;
import org.openjdk.jmh.annotations.Mode;
import org.openjdk.jmh.annotations.OperationsPerInvocation;
import org.openjdk.jmh.annotations.OutputTimeUnit;
import org.openjdk.jmh.annotations.Param;
import org.openjdk.jmh.annotations.Scope;
import org.openjdk.jmh.annotations.Level;
import org.openjdk.jmh.annotations.Setup;
import org.openjdk.jmh.annotations.State;
import org.openjdk.jmh.annotations.TearDown;
import org.openjdk.jmh.annotations.Warmup;
import org.openjdk.jmh.infra.Blackhole;

import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.IOException;
import java.io.InputStream;
import java.nio.file.Files;
import java.nio.file.Path;
import java.security.KeyStore;
import java.security.PrivateKey;
import java.security.cert.Certificate;
import java.util.ArrayList;
import java.util.Base64;
import java.util.List;
import java.util.Locale;
import java.util.concurrent.TimeUnit;

/**
 * B4 — Netty TLS pipeline comparative benchmark via netty-tcnative.
 *
 * <h2>Matrix position</h2>
 * <pre>
 * matrix_id : B4
 * tier       : community  (netty-tcnative + Netty pipeline)
 * protocol   : tcp-tls-1.3
 * family     : B (steady-state record path)
 * axis       : implementation-variant
 * scenario_classification : tls-record-path-netty-tcnative-wiring-model-embedded-channel-pipeline
 * </pre>
 *
 * <h2>What is measured</h2>
 * <p>Steady-state Netty usage with {@link SslHandler} on {@link EmbeddedChannel}, backed by
 * netty-tcnative/BoringSSL. The benchmark measures an outbound encrypt path and an in-memory
 * client-to-server round trip after handshake has already completed in setup.
 *
 * <p>This intentionally differs from B3's direct {@code SSLEngine} harness: B4 includes Netty
 * pipeline glue, pooled {@link ByteBuf} handling, and handler/channel dispatch. Keep that wiring
 * difference explicit in any comparison or report.
 *
 * <h2>Dependency</h2>
 * <p>Requires Netty OpenSSL support from {@code io.netty:netty-tcnative-boringssl-static}.
 * Setup fails fast with diagnostics when OpenSSL is unavailable or TLS 1.3 is unsupported.
 */
@State(Scope.Thread)
@BenchmarkMode({Mode.Throughput, Mode.SampleTime})
@OutputTimeUnit(TimeUnit.MICROSECONDS)
@Warmup(iterations = 5, time = 3, timeUnit = TimeUnit.SECONDS)
@Measurement(iterations = 10, time = 5, timeUnit = TimeUnit.SECONDS)
// Publication-safe default; CLI/manifest may override for smoke/profile runs.
@Fork(value = 3, jvmArgsAppend = {
        // ZGC, heap, and module-open/native-access flags are provided by the manifest
        // harness (common_jvm_args). Listing them here duplicates the runner-level args
        // JMH propagates to forks. Keep only the annotation-specific profiling hint.
        "-XX:+PreserveFramePointer"
    })
public class NettyTcNativeTlsBenchmark {

    private static final String TLS_V13 = "TLSv1.3";
    private static final SslProvider SSL_PROVIDER = SslProvider.OPENSSL;
    private static final int MAX_HANDSHAKE_STEPS = 512;
    private static final int MAX_TRAFFIC_STEPS = 64;

    @Param({"128", "1024", "4096", "16384"})
    public int payloadBytes;

    @Param({"TLS_AES_256_GCM_SHA384"})
    public String cipherSuite;

    private ByteBufAllocator allocator;

    private File certFile;
    private File keyFile;
    private SslContext clientContext;
    private SslContext serverContext;

    private EmbeddedChannel clientChannel;
    private EmbeddedChannel serverChannel;
    private SslHandler clientHandler;
    private SslHandler serverHandler;

    private ByteBuf payloadTemplate;

    @Setup
    public void setUp() throws Exception {
        verifyNativeSupport();

        allocator = PooledByteBufAllocator.DEFAULT;

        File[] certAndKey = generateEphemeralCertAndKey();
        certFile = certAndKey[0];
        keyFile = certAndKey[1];

        serverContext = SslContextBuilder.forServer(certFile, keyFile)
                .sslProvider(SSL_PROVIDER)
                .protocols(TLS_V13)
            .ciphers(List.of(cipherSuite))
                .build();
        clientContext = SslContextBuilder.forClient()
                .sslProvider(SSL_PROVIDER)
                .trustManager(InsecureTrustManagerFactory.INSTANCE)
                .protocols(TLS_V13)
            .ciphers(List.of(cipherSuite))
                .build();

        clientHandler = clientContext.newHandler(allocator);
        serverHandler = serverContext.newHandler(allocator);
        enforceTls13AndCipherConfigured(clientHandler, "client", cipherSuite);
        enforceTls13AndCipherConfigured(serverHandler, "server", cipherSuite);

        clientChannel = new EmbeddedChannel(clientHandler);
        serverChannel = new EmbeddedChannel(serverHandler);
        clientChannel.pipeline().fireChannelActive();
        serverChannel.pipeline().fireChannelActive();
        completeHandshake();

        payloadTemplate = allocator.directBuffer(payloadBytes, payloadBytes);
        fillPayload(payloadTemplate, payloadBytes);
        releaseAllInbound(clientChannel);
        releaseAllInbound(serverChannel);
    }

    @TearDown
    public void tearDown() throws Exception {
        List<Exception> errors = new ArrayList<>();

        releaseObject(payloadTemplate);
        payloadTemplate = null;

        closeChannel(clientChannel, errors);
        closeChannel(serverChannel, errors);
        clientChannel = null;
        serverChannel = null;
        clientHandler = null;
        serverHandler = null;

        releaseReferenceCounted(clientContext, errors);
        releaseReferenceCounted(serverContext, errors);
        clientContext = null;
        serverContext = null;

        deleteQuietly(certFile, errors);
        deleteQuietly(keyFile, errors);
        certFile = null;
        keyFile = null;

        if (!errors.isEmpty()) {
            Exception first = errors.get(0);
            for (int index = 1; index < errors.size(); index++) {
                first.addSuppressed(errors.get(index));
            }
            throw first;
        }
    }

    @Setup(Level.Iteration)
    public void markMeasurementStart() {
        PhaseMarkerEvent event = new PhaseMarkerEvent();
        event.phase = "measurement";
        event.iteration = 0;
        event.benchmarkClass = getClass().getSimpleName();
        event.commit();
    }

    @Benchmark
    @BenchmarkMode(Mode.Throughput)
    @OutputTimeUnit(TimeUnit.SECONDS)
    public void wrapThroughput(Blackhole bh) {
        ByteBuf payload = payloadTemplate.retainedDuplicate();
        try {
            clientChannel.writeOutbound(payload);
            clientChannel.checkException();
            bh.consume(drainOutboundBytes(clientChannel));
        } finally {
            releaseAllInbound(clientChannel);
        }
    }

    @Benchmark
    @BenchmarkMode(Mode.SampleTime)
    @OutputTimeUnit(TimeUnit.MICROSECONDS)
    @OperationsPerInvocation(2)
    public void wrapUnwrapRoundTrip(Blackhole bh) {
        ByteBuf payload = payloadTemplate.retainedDuplicate();
        try {
            clientChannel.writeOutbound(payload);
            pumpTraffic("round-trip");

            int serverBytes = drainInboundBytes(serverChannel);
            int clientBytes = drainInboundBytes(clientChannel);
            bh.consume(serverBytes);
            bh.consume(clientBytes);
        } finally {
            releaseAllInbound(clientChannel);
            releaseAllInbound(serverChannel);
        }
    }

    private static void verifyNativeSupport() {
        if (!OpenSsl.isAvailable()) {
            Throwable cause = OpenSsl.unavailabilityCause();
            StringBuilder message = new StringBuilder(
                    "B4 requires Netty OpenSSL support from netty-tcnative-boringssl-static. "
                            + "OpenSsl.isAvailable() returned false.");
            if (cause != null) {
                message.append(' ').append("Cause: ").append(cause.getMessage());
            }
            throw new IllegalStateException(message.toString(), cause);
        }
        if (!SslProvider.isTlsv13Supported(SSL_PROVIDER)) {
            throw new IllegalStateException(
                    "B4 requires TLS 1.3 support from Netty OpenSSL provider " + SSL_PROVIDER
                            + ". Reported OpenSSL version: " + OpenSsl.versionString());
        }
    }

    private static void enforceTls13AndCipherConfigured(SslHandler handler, String role, String expectedCipherSuite) {
        handler.engine().setEnabledProtocols(new String[]{TLS_V13});
        handler.engine().setEnabledCipherSuites(new String[]{expectedCipherSuite});

        String[] protocols = handler.engine().getEnabledProtocols();
        boolean tls13Enabled = false;
        for (String protocol : protocols) {
            if (TLS_V13.equals(protocol)) {
                tls13Enabled = true;
                continue;
            }
            if (!"SSLv2Hello".equals(protocol)) {
                throw new IllegalStateException(
                        "Expected TLS 1.3 only on " + role + " handler, but got " + String.join(",", protocols));
            }
        }
        if (!tls13Enabled) {
            throw new IllegalStateException(
                    "Expected TLS 1.3 only on " + role + " handler, but got " + String.join(",", protocols));
        }

        String[] suites = handler.engine().getEnabledCipherSuites();
        boolean expectedSuiteEnabled = false;
        for (String suite : suites) {
            if (expectedCipherSuite.equals(suite)) {
                expectedSuiteEnabled = true;
                break;
            }
        }
        if (!expectedSuiteEnabled) {
            throw new IllegalStateException(
                    "expected enabled cipher suite " + expectedCipherSuite + " on " + role
                            + " handler, but got " + String.join(",", suites));
        }
    }

    private void completeHandshake() {
        Future<?> clientHandshake = clientHandler.handshakeFuture();
        Future<?> serverHandshake = serverHandler.handshakeFuture();

        for (int step = 0; step < MAX_HANDSHAKE_STEPS; step++) {
            boolean progress = pumpOnce();

            if (clientHandshake.isDone() && serverHandshake.isDone()) {
                if (!clientHandshake.isSuccess() || !serverHandshake.isSuccess()) {
                    throw new IllegalStateException(
                            "Netty TLS handshake failed: client=" + futureFailure(clientHandshake)
                                    + ", server=" + futureFailure(serverHandshake));
                }
                if (!hasPendingWork()) {
                    assertNegotiatedTls13(clientHandler, "client");
                    assertNegotiatedTls13(serverHandler, "server");
                    assertNegotiatedCipherSupported(clientHandler, "client");
                    assertNegotiatedCipherSupported(serverHandler, "server");
                    releaseAllInbound(clientChannel);
                    releaseAllInbound(serverChannel);
                    return;
                }
            } else if (!progress) {
                throw new IllegalStateException(
                        "Netty TLS handshake stalled before completion. clientDone="
                                + clientHandshake.isDone() + ", serverDone=" + serverHandshake.isDone());
            }
        }

        throw new IllegalStateException(
                "Netty TLS handshake did not complete within " + MAX_HANDSHAKE_STEPS + " steps.");
    }

    private void pumpTraffic(String phase) {
        for (int step = 0; step < MAX_TRAFFIC_STEPS; step++) {
            boolean progress = pumpOnce();
            if (!progress) {
                return;
            }
        }

        throw new IllegalStateException(
                "Netty TLS traffic did not quiesce during " + phase + " within " + MAX_TRAFFIC_STEPS + " steps.");
    }

    private boolean pumpOnce() {
        boolean hadPendingTasks = clientChannel.hasPendingTasks() || serverChannel.hasPendingTasks();

        clientChannel.runPendingTasks();
        serverChannel.runPendingTasks();
        clientChannel.runScheduledPendingTasks();
        serverChannel.runScheduledPendingTasks();

        boolean moved = transferOutboundWithFlush(clientChannel, serverChannel);
        moved |= transferOutboundWithFlush(serverChannel, clientChannel);

        // Handshake state can schedule follow-up work after inbound delivery.
        clientChannel.runPendingTasks();
        serverChannel.runPendingTasks();
        clientChannel.runScheduledPendingTasks();
        serverChannel.runScheduledPendingTasks();

        clientChannel.checkException();
        serverChannel.checkException();
        return hadPendingTasks
                || moved
                || clientChannel.hasPendingTasks()
                || serverChannel.hasPendingTasks();
    }

    private static boolean transferOutbound(EmbeddedChannel source, EmbeddedChannel target) {
        boolean moved = false;
        for (;;) {
            Object message = source.readOutbound();
            if (message == null) {
                return moved;
            }

            moved = true;
            boolean handedOff = false;
            try {
                target.writeOneInbound(message);
                handedOff = true;
            } finally {
                if (!handedOff) {
                    releaseObject(message);
                }
            }
        }
    }

    private static boolean transferOutboundWithFlush(EmbeddedChannel source, EmbeddedChannel target) {
        boolean moved = transferOutbound(source, target);
        if (moved) {
            target.flushInbound();
        }
        return moved;
    }

    private boolean hasPendingWork() {
        return clientChannel.hasPendingTasks()
                || serverChannel.hasPendingTasks()
                || !clientChannel.outboundMessages().isEmpty()
                || !serverChannel.outboundMessages().isEmpty();
    }

    private static int drainOutboundBytes(EmbeddedChannel channel) {
        int bytes = 0;
        for (;;) {
            Object message = channel.readOutbound();
            if (message == null) {
                return bytes;
            }
            try {
                bytes += readableBytes(message);
            } finally {
                releaseObject(message);
            }
        }
    }

    private static int drainInboundBytes(EmbeddedChannel channel) {
        int bytes = 0;
        for (;;) {
            Object message = channel.readInbound();
            if (message == null) {
                return bytes;
            }
            try {
                bytes += readableBytes(message);
            } finally {
                releaseObject(message);
            }
        }
    }

    private static void releaseAllInbound(EmbeddedChannel channel) {
        if (channel == null) {
            return;
        }
        for (;;) {
            Object message = channel.readInbound();
            if (message == null) {
                return;
            }
            releaseObject(message);
        }
    }

    private static int readableBytes(Object message) {
        if (message instanceof ByteBuf byteBuf) {
            return byteBuf.readableBytes();
        }
        if (message instanceof ByteBufHolder holder) {
            return holder.content().readableBytes();
        }
        return 0;
    }

    private static String futureFailure(Future<?> future) {
        if (!future.isDone()) {
            return "pending";
        }
        if (future.isSuccess()) {
            return "success";
        }
        Throwable cause = future.cause();
        if (cause == null) {
            return "failed";
        }
        return cause.getClass().getSimpleName() + ": " + cause.getMessage();
    }

    private static void assertNegotiatedTls13(SslHandler handler, String role) {
        String protocol = handler.engine().getSession().getProtocol();
        if (!TLS_V13.equals(protocol)) {
            throw new IllegalStateException(
                    "Expected negotiated TLS 1.3 on " + role + " handler, but got " + protocol);
        }
    }

    private static void assertNegotiatedCipherSupported(SslHandler handler, String role) {
        String negotiated = handler.engine().getSession().getCipherSuite();
        if (negotiated == null || negotiated.isBlank()) {
            throw new IllegalStateException(
                    "Expected negotiated cipher suite on " + role + " handler, but got empty value");
        }

        String[] enabled = handler.engine().getEnabledCipherSuites();
        for (String suite : enabled) {
            if (negotiated.equals(suite)) {
                return;
            }
        }

        throw new IllegalStateException(
                "Negotiated cipher suite " + negotiated + " on " + role
                        + " handler is not present in enabled suites: " + String.join(",", enabled));
    }

    private static void fillPayload(ByteBuf buffer, int length) {
        buffer.clear();
        for (int index = 0; index < length; index++) {
            buffer.writeByte((byte) (index & 0xFF));
        }
    }

    private static void closeChannel(EmbeddedChannel channel, List<Exception> errors) {
        if (channel == null) {
            return;
        }
        try {
            channel.finishAndReleaseAll();
        } catch (Exception exception) {
            errors.add(exception);
        }
    }

    private static void releaseReferenceCounted(Object object, List<Exception> errors) {
        if (!(object instanceof ReferenceCounted referenceCounted)) {
            return;
        }
        try {
            while (referenceCounted.refCnt() > 0) {
                referenceCounted.release();
            }
        } catch (Exception exception) {
            errors.add(exception);
        }
    }

    private static void releaseObject(Object object) {
        if (!(object instanceof ReferenceCounted referenceCounted)) {
            return;
        }
        while (referenceCounted.refCnt() > 0) {
            referenceCounted.release();
        }
    }

    private static void deleteQuietly(File file, List<Exception> errors) {
        if (file == null) {
            return;
        }
        try {
            Files.deleteIfExists(file.toPath());
        } catch (IOException exception) {
            errors.add(exception);
        }
    }

    private static File[] generateEphemeralCertAndKey() throws Exception {
        char[] password = "changeit".toCharArray();

        Path ksPath = Files.createTempFile("exeris-b4-", ".p12");
        Files.delete(ksPath);

        List<String> command = new ArrayList<>();
        command.add(detectKeytoolBinary());
        command.add("-genkeypair");
        command.add("-alias");
        command.add("bench");
        command.add("-storetype");
        command.add("PKCS12");
        command.add("-keystore");
        command.add(ksPath.toString());
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
        command.add("CN=exeris-bench,O=Exeris,C=PL");
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

        KeyStore keyStore = KeyStore.getInstance("PKCS12");
        try (InputStream input = Files.newInputStream(ksPath)) {
            keyStore.load(input, password);
        }
        Files.deleteIfExists(ksPath);

        Certificate certificate = keyStore.getCertificate("bench");
        PrivateKey privateKey = (PrivateKey) keyStore.getKey("bench", password);

        Path certPath = Files.createTempFile("exeris-b4-cert-", ".pem");
        Files.writeString(certPath, toPemBlock("CERTIFICATE", certificate.getEncoded()));
        certPath.toFile().deleteOnExit();

        Path keyPath = Files.createTempFile("exeris-b4-key-", ".pem");
        Files.writeString(keyPath, toPemBlock("PRIVATE KEY", privateKey.getEncoded()));
        keyPath.toFile().deleteOnExit();

        return new File[]{certPath.toFile(), keyPath.toFile()};
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
        byte[] buffer = new byte[4096];
        int read;
        while ((read = input.read(buffer)) != -1) {
            out.write(buffer, 0, read);
        }
        return out.toString(java.nio.charset.StandardCharsets.UTF_8);
    }

    private static String toPemBlock(String label, byte[] derBytes) {
        String body = Base64.getMimeEncoder(64, new byte[]{'\n'}).encodeToString(derBytes);
        return "-----BEGIN " + label + "-----\n"
                + body
                + "\n-----END " + label + "-----\n";
    }
}
