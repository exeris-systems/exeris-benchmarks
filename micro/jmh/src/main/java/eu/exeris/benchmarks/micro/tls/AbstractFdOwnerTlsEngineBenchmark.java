package eu.exeris.benchmarks.micro.tls;

import eu.exeris.kernel.spi.crypto.CryptoProviderConfig;
import eu.exeris.kernel.spi.crypto.KernelCryptoProvider;
import eu.exeris.kernel.spi.crypto.TlsEngine;
import eu.exeris.kernel.spi.crypto.TlsStatus;
import eu.exeris.kernel.spi.memory.LoanedBuffer;
import eu.exeris.kernel.spi.memory.MemoryAllocator;
import eu.exeris.kernel.spi.memory.MemoryProvider;
import eu.exeris.kernel.spi.memory.MemoryProviderConfig;
import org.openjdk.jmh.annotations.*;
import org.openjdk.jmh.infra.Blackhole;

import java.lang.reflect.Method;
import java.net.InetAddress;
import java.net.InetSocketAddress;
import java.net.StandardSocketOptions;
import java.nio.channels.ServerSocketChannel;
import java.nio.channels.SocketChannel;
import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.ExecutionException;
import java.util.concurrent.Executors;
import java.util.concurrent.Future;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.TimeoutException;
import java.util.concurrent.atomic.AtomicLong;

/**
 * Abstract JMH harness for the FD-owner TLS engine ownership model.
 *
 * <p><b>Ownership model:</b> the {@link TlsEngine} owns a real socket file descriptor.
 * Encrypt path includes a {@code write(2)} kernel crossing per record via the bound FD;
 * decrypt path includes a {@code read(2)} crossing. This is the {@code fd-owner} harness
 * model row in the TLS matrix and is the structural counterpart to
 * {@link AbstractMemoryBioTlsEngineBenchmark} (no socket, no syscall).
 *
 * <p><b>Comparison caveat:</b> NOT directly comparable to Memory-BIO measurements without
 * explicit transport-model labels — FD-owner numbers include kernel crossings that
 * Memory-BIO numbers exclude.
 *
 * <p><b>JDK constraint:</b> FD extraction uses {@code sun.nio.ch.SocketChannelImpl} internal APIs,
 * verified on JDK 21+. May break on future JDK versions if the internal field is renamed or removed.
 *
 * <p><b>Default config:</b> Publication-safe defaults are set in annotations.
 * CLI/manifest options may intentionally override for smoke/profile runs.
 */
@State(Scope.Thread)
@BenchmarkMode({Mode.Throughput, Mode.SampleTime})
@OutputTimeUnit(TimeUnit.MICROSECONDS)
@Warmup(iterations = 5, time = 3, timeUnit = TimeUnit.SECONDS)
@Measurement(iterations = 10, time = 5, timeUnit = TimeUnit.SECONDS)
// Publication-safe default; CLI/manifest may override for smoke/profile runs.
@Fork(value = 3, jvmArgsAppend = {
        // All baseline JVM flags (--add-opens, --enable-native-access, ZGC, heap) are
        // provided by the manifest harness (common_jvm_args). JMH inherits them from the
        // runner process and appends jvmArgsAppend on top — repeating them here causes
        // the duplication seen in '# VM options:'. Keep only the annotation-specific hint.
        "-XX:+PreserveFramePointer"
    })
public abstract class AbstractFdOwnerTlsEngineBenchmark extends AbstractExerisTlsBenchmarkSupport {

    @Param({"128", "1024", "4096", "16384"})
    public int payloadBytes;

    private KernelCryptoProvider cryptoProvider;
    private MemoryProvider memoryProvider;
    private MemoryAllocator allocator;

    private TlsEngine clientEngine;
    private TlsEngine serverEngine;

    private LoanedBuffer clientPlain;
    private LoanedBuffer clientCipher;
    private LoanedBuffer serverPlain;
    private LoanedBuffer clientHsOut;
    private LoanedBuffer serverHsOut;
    private LoanedBuffer handshakeScratch;
    private LoanedBuffer emptyBuffer;

    private ServerSocketChannel listenChannel;
    private SocketChannel clientChannel;
    private SocketChannel serverChannel;

    private java.nio.ByteBuffer drainDiscardBuffer;
    private volatile boolean drainRunning;
    private Thread drainThread;
    private int clientFd;
    private int serverFd;
    private final AtomicLong drainBytesTotal = new AtomicLong();
    private final AtomicLong drainReadOpsTotal = new AtomicLong();

    private static final int NET_BUFFER_SIZE = 16_384 + 2048;
    private static final int MAX_HANDSHAKE_STEPS = 512;
    private static final int MAX_WRAP_ATTEMPTS = 8;
    private static final int MAX_UNWRAP_ATTEMPTS = 16;

    protected abstract String tier();

    /**
     * Returns the provider-lookup tier key used to resolve system properties
     * (e.g. {@code exeris.tls.<providerTier()>.cryptoProviderClass}).
     *
     * <p>Override when the benchmark identity ({@link #tier()}) differs from
     * the provider configuration tier. Default: delegates to {@link #tier()}.
     */
    protected String providerTier() {
        return tier();
    }

    @Setup(Level.Trial)
    public void setUp() throws Exception {
        ResolvedProviderConfig config = resolveProviderConfig(providerTier());
        memoryProvider = instantiate(config.memoryProviderClass(), MemoryProvider.class, "memoryProviderClass");
        allocator = memoryProvider.createAllocator(MemoryProviderConfig.defaults());
        cryptoProvider = instantiateWithAllocator(
            config.cryptoProviderClass(),
            KernelCryptoProvider.class,
            "cryptoProviderClass",
            allocator);

        CryptoProviderConfig clientConfig = CryptoProviderConfig.tcpClient();
        CryptoProviderConfig serverConfig = CryptoProviderConfig.httpsServer(config.certPem(), config.keyPem());
        warmUpProviderIfSupported(cryptoProvider, serverConfig, clientConfig);

        clientEngine = cryptoProvider.createTlsEngine(clientConfig);
        serverEngine = cryptoProvider.createTlsEngine(serverConfig);

        listenChannel = ServerSocketChannel.open();
        listenChannel.setOption(StandardSocketOptions.SO_RCVBUF, 4 * 1024 * 1024);
        listenChannel.bind(new InetSocketAddress(InetAddress.getLoopbackAddress(), 0));
        clientChannel = SocketChannel.open();
        clientChannel.configureBlocking(true);
        tuneSocketBuffers(clientChannel);
        clientChannel.connect((InetSocketAddress) listenChannel.getLocalAddress());
        serverChannel = listenChannel.accept();
        serverChannel.configureBlocking(true);
        tuneSocketBuffers(serverChannel);

        clientFd = extractFd(clientChannel);
        serverFd = extractFd(serverChannel);

        bindFdOwnerEndpoint(clientEngine, clientFd, clientChannel);
        bindFdOwnerEndpoint(serverEngine, serverFd, serverChannel);

        clientEngine.notifyBound();
        serverEngine.notifyBound();

        clientPlain = allocator.allocateNetwork(NET_BUFFER_SIZE);
        clientCipher = allocator.allocateNetwork(NET_BUFFER_SIZE);
        serverPlain = allocator.allocateNetwork(NET_BUFFER_SIZE);
        clientHsOut = allocator.allocateNetwork(NET_BUFFER_SIZE);
        serverHsOut = allocator.allocateNetwork(NET_BUFFER_SIZE);
        handshakeScratch = allocator.allocateNetwork(NET_BUFFER_SIZE);
        emptyBuffer = allocator.allocateNetwork(NET_BUFFER_SIZE);
        emptyBuffer.setSize(0);

        fillPayload(clientPlain, payloadBytes);
        drainDiscardBuffer = java.nio.ByteBuffer.allocate(NET_BUFFER_SIZE);
        performHandshakeConcurrently();
        afterHandshakeSetUp();
    }

    @TearDown(Level.Trial)
    public void tearDown() throws Exception {
        beforeTearDownHook();

        List<Exception> errors = new ArrayList<>();
        closeQuietly(serverEngine, errors);
        closeQuietly(clientEngine, errors);
        closeQuietly(emptyBuffer, errors);
        closeQuietly(handshakeScratch, errors);
        closeQuietly(serverHsOut, errors);
        closeQuietly(clientHsOut, errors);
        closeQuietly(serverPlain, errors);
        closeQuietly(clientCipher, errors);
        closeQuietly(clientPlain, errors);
        closeQuietly(serverChannel, errors);
        closeQuietly(clientChannel, errors);
        closeQuietly(listenChannel, errors);
        closeQuietly(allocator, errors);
        closeQuietly(memoryProvider instanceof AutoCloseable ? (AutoCloseable) memoryProvider : null, errors);
        closeQuietly(cryptoProvider instanceof AutoCloseable ? (AutoCloseable) cryptoProvider : null, errors);

        listenChannel = null;
        clientChannel = null;
        serverChannel = null;
        cryptoProvider = null;
        memoryProvider = null;
        allocator = null;
        clientEngine = null;
        serverEngine = null;
        clientPlain = null;
        clientCipher = null;
        serverPlain = null;
        clientHsOut = null;
        serverHsOut = null;
        handshakeScratch = null;
        emptyBuffer = null;
        drainDiscardBuffer = null;
        drainThread = null;

        if (!errors.isEmpty()) {
            Exception first = errors.get(0);
            for (int i = 1; i < errors.size(); i++) {
                first.addSuppressed(errors.get(i));
            }
            throw first;
        }
    }

    protected void wrapThroughput(Blackhole bh, TransportAuxCounters counters) {
        long beforeDrainBytes = drainBytesTotal.get();
        long beforeDrainOps = drainReadOpsTotal.get();

        clientPlain.setSize(payloadBytes);
        clientCipher.setSize(0);
        TlsStatus status = clientEngine.wrap(clientPlain, clientCipher);
        long produced = clientCipher.size();
        long drainBytesDelta = Math.max(0L, drainBytesTotal.get() - beforeDrainBytes);
        long drainReadOpsDelta = Math.max(0L, drainReadOpsTotal.get() - beforeDrainOps);

        counters.wrapCalls++;
        counters.submittedPayloadBytes += payloadBytes;
        counters.wrapCipherBytes += produced;
        counters.socketWriteBytes += (produced > 0 ? produced : drainBytesDelta);
        counters.drainBytes += drainBytesDelta;
        counters.drainReadOps += drainReadOpsDelta;
        bh.consume(status);
        bh.consume(produced);
    }

    public void wrapThroughputEngineOnly(Blackhole bh) {
        clientPlain.setSize(payloadBytes);
        clientCipher.setSize(0);
        TlsStatus status = clientEngine.wrap(clientPlain, clientCipher);
        bh.consume(status);
        bh.consume(clientCipher.size());
    }

    @State(Scope.Thread)
    @AuxCounters(AuxCounters.Type.EVENTS)
    public static class TransportAuxCounters {
        public long wrapCalls;
        public long submittedPayloadBytes;
        public long socketWriteBytes;
        public long wrapCipherBytes;
        public long drainReadOps;
        public long drainBytes;

        @Setup(Level.Iteration)
        public void reset() {
            wrapCalls = 0;
            submittedPayloadBytes = 0;
            socketWriteBytes = 0;
            wrapCipherBytes = 0;
            drainReadOps = 0;
            drainBytes = 0;
        }
    }

    protected void wrapUnwrapRoundTrip(Blackhole bh) {
        try {
            clientPlain.setSize(payloadBytes);
            clientCipher.setSize(0);
            TlsStatus wrapStatus = null;
            long wrapProduced = 0;
            int wrapAttempt = 0;

            for (; wrapAttempt < MAX_WRAP_ATTEMPTS; wrapAttempt++) {
                clientCipher.setSize(0);
                wrapStatus = clientEngine.wrap(clientPlain, clientCipher);
                wrapProduced = clientCipher.size();
                if (wrapStatus == TlsStatus.OK || wrapStatus == TlsStatus.FINISHED) {
                    break;
                }
                if (wrapStatus == TlsStatus.NEED_WRAP) {
                    continue;
                }
                throw new IllegalStateException("FdOwner wrapUnwrapRoundTrip wrap failed"
                        + " tier=" + tier()
                        + " payload=" + payloadBytes
                        + " attempt=" + (wrapAttempt + 1)
                        + " status=" + wrapStatus
                        + " produced=" + wrapProduced);
            }

            if (wrapStatus != TlsStatus.OK && wrapStatus != TlsStatus.FINISHED) {
                throw new IllegalStateException("FdOwner wrapUnwrapRoundTrip wrap exhausted "
                        + MAX_WRAP_ATTEMPTS + " attempts"
                        + " tier=" + tier()
                        + " payload=" + payloadBytes
                        + " lastStatus=" + wrapStatus
                        + " produced=" + wrapProduced);
            }
            bh.consume(wrapStatus);
            bh.consume(wrapProduced);

            serverPlain.setSize(0);
            TlsStatus unwrapStatus = null;
            for (int unwrapAttempt = 0; unwrapAttempt < MAX_UNWRAP_ATTEMPTS; unwrapAttempt++) {
                LoanedBuffer unwrapInput = clientCipher.size() > 0 ? clientCipher : emptyBuffer;
                long beforeProduced = serverPlain.size();
                long beforeCipher = unwrapInput == clientCipher ? clientCipher.size() : 0;

                unwrapStatus = serverEngine.unwrap(unwrapInput, serverPlain);
                long unwrapProduced = serverPlain.size();
                long remainingCipher = clientCipher.size();

                boolean producedProgress = unwrapProduced > beforeProduced;
                boolean consumedCipherProgress = unwrapInput == clientCipher && remainingCipher < beforeCipher;

                if ((unwrapStatus == TlsStatus.OK || unwrapStatus == TlsStatus.FINISHED) && unwrapProduced > 0) {
                    bh.consume(unwrapStatus);
                    bh.consume(unwrapProduced);
                    return;
                }

                if (unwrapStatus == TlsStatus.NEED_UNWRAP || unwrapStatus == TlsStatus.NEED_WRAP) {
                    if (producedProgress || consumedCipherProgress) {
                        continue;
                    }
                    throw new IllegalStateException("FdOwner wrapUnwrapRoundTrip unwrap stalled"
                            + " tier=" + tier()
                            + " payload=" + payloadBytes
                            + " wrapStatus=" + wrapStatus
                            + " wrapProduced=" + wrapProduced
                            + " wrapAttempts=" + (wrapAttempt + 1)
                            + " unwrapAttempt=" + (unwrapAttempt + 1)
                            + " status=" + unwrapStatus
                            + " produced=" + unwrapProduced
                            + " cipherRemaining=" + remainingCipher
                            + " input=" + (unwrapInput == clientCipher ? "clientCipher" : "emptyBuffer"));
                }

                throw new IllegalStateException("FdOwner wrapUnwrapRoundTrip unwrap failed"
                        + " tier=" + tier()
                        + " payload=" + payloadBytes
                        + " wrapStatus=" + wrapStatus
                        + " wrapProduced=" + wrapProduced
                        + " wrapAttempts=" + (wrapAttempt + 1)
                        + " unwrapAttempt=" + (unwrapAttempt + 1)
                        + " status=" + unwrapStatus
                        + " produced=" + unwrapProduced
                        + " cipherRemaining=" + remainingCipher);
            }

            throw new IllegalStateException("FdOwner wrapUnwrapRoundTrip unwrap exhausted "
                    + MAX_UNWRAP_ATTEMPTS + " attempts"
                    + " tier=" + tier()
                    + " payload=" + payloadBytes
                    + " wrapStatus=" + wrapStatus
                    + " wrapProduced=" + wrapProduced
                    + " wrapAttempts=" + (wrapAttempt + 1)
                    + " lastStatus=" + unwrapStatus
                    + " produced=" + serverPlain.size()
                    + " cipherRemaining=" + clientCipher.size());

        } catch (RuntimeException e) {
            throw new IllegalStateException("FdOwner wrapUnwrapRoundTrip failed: " + e.getMessage(), e);
        }
    }

    /**
     * Lifecycle hook invoked at the end of {@link #setUp()} after the TLS handshake completes.
     * Default: starts the drain thread required for {@code wrapThroughput}.
     * Override and leave empty to suppress drain for roundtrip scenarios.
     */
    protected void afterHandshakeSetUp() throws Exception {
        startDrainThread();
    }

    /**
     * Lifecycle hook invoked at the start of {@link #tearDown()} before resource cleanup.
     * Override symmetrically with {@link #afterHandshakeSetUp()}.
     */
    protected void beforeTearDownHook() throws Exception {
        stopDrainThread();
    }

    private void startDrainThread() {
        drainRunning = true;
        drainThread = new Thread(() -> {
            while (drainRunning && !Thread.currentThread().isInterrupted()) {
                try {
                    drainDiscardBuffer.clear();
                    int read = serverChannel.read(drainDiscardBuffer);
                    if (read < 0) {
                        break;
                    }
                    if (read > 0) {
                        drainBytesTotal.addAndGet(read);
                        drainReadOpsTotal.incrementAndGet();
                    }
                } catch (java.io.IOException e) {
                    break;
                }
            }
        }, "fd-owner-tls-drain");
        drainThread.setDaemon(true);
        drainThread.start();
    }

    private void stopDrainThread() throws InterruptedException {
        drainRunning = false;
        if (drainThread != null) {
            drainThread.interrupt();
            drainThread.join(2000);
            drainThread = null;
        }
    }

    private void performHandshakeConcurrently() throws Exception {
        try (var executor = Executors.newFixedThreadPool(2)) {
            Future<?> clientHandshake = executor.submit(
                () -> driveSingleHandshakeEngine(clientEngine, clientHsOut, "client"));
            Future<?> serverHandshake = executor.submit(
                () -> driveSingleHandshakeEngine(serverEngine, serverHsOut, "server"));

            try {
                clientHandshake.get(10, TimeUnit.SECONDS);
                serverHandshake.get(10, TimeUnit.SECONDS);
            } catch (TimeoutException e) {
                clientHandshake.cancel(true);
                serverHandshake.cancel(true);
                throw new IllegalStateException("FdOwner TLS handshake timed out after 10 seconds", e);
            } catch (ExecutionException e) {
                clientHandshake.cancel(true);
                serverHandshake.cancel(true);
                Throwable failureCause = e.getCause();
                if (failureCause == null) {
                    failureCause = e;
                }
                throw new IllegalStateException("FdOwner TLS handshake failed", failureCause);
            }
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
            throw new IllegalStateException("FdOwner TLS handshake interrupted", e);
        }
    }

    private void tuneSocketBuffers(SocketChannel channel) throws java.io.IOException {
        channel.setOption(StandardSocketOptions.SO_SNDBUF, 4 * 1024 * 1024);
        channel.setOption(StandardSocketOptions.SO_RCVBUF, 4 * 1024 * 1024);
    }

    private void driveSingleHandshakeEngine(TlsEngine tlsEngine, LoanedBuffer outbound, String sideLabel) {
        for (int step = 0; step < MAX_HANDSHAKE_STEPS; step++) {
            if (tlsEngine.isHandshakeComplete()) {
                return;
            }
            outbound.setSize(0);
            tlsEngine.beginHandshake(outbound);
        }
        throw new IllegalStateException("FdOwner " + sideLabel + " handshake exceeded "
                + MAX_HANDSHAKE_STEPS + " steps for tier=" + tier());
    }

    private void bindFdOwnerEndpoint(TlsEngine engine, int fd, SocketChannel channel) {
        Method bindFd = findMethod(engine.getClass(), "bindFileDescriptor", int.class);
        if (bindFd != null) {
            try {
                bindFd.invoke(engine, fd);
                return;
            } catch (ReflectiveOperationException e) {
                throw new IllegalStateException("Failed to bind FD to " + engine.getClass().getName(), e);
            }
        }

        Method bindSocket = findMethod(engine.getClass(), "bindSocketChannel", SocketChannel.class);
        if (bindSocket != null) {
            try {
                bindSocket.invoke(engine, channel);
                return;
            } catch (ReflectiveOperationException e) {
                throw new IllegalStateException("Failed to bind SocketChannel to " + engine.getClass().getName(), e);
            }
        }

        throw new IllegalStateException("FD-owner TlsEngine does not expose bindFileDescriptor or bindSocketChannel");
    }

    private static int extractFd(SocketChannel sc) {
        try {
            java.lang.reflect.Field fdField = findFieldInHierarchy(sc.getClass(), "fd");
            fdField.setAccessible(true);
            java.io.FileDescriptor fd = (java.io.FileDescriptor) fdField.get(sc);
            java.lang.reflect.Field fdValueField = java.io.FileDescriptor.class.getDeclaredField("fd");
            fdValueField.setAccessible(true);
            return (int) fdValueField.get(fd);
        } catch (ReflectiveOperationException e) {
            throw new IllegalStateException("Failed to extract native FD from SocketChannel: " + sc.getClass(), e);
        }
    }

    private static java.lang.reflect.Field findFieldInHierarchy(Class<?> type, String name) throws NoSuchFieldException {
        Class<?> cursor = type;
        while (cursor != null) {
            try {
                return cursor.getDeclaredField(name);
            } catch (NoSuchFieldException ignored) {
                cursor = cursor.getSuperclass();
            }
        }
        throw new NoSuchFieldException("Field '" + name + "' not found in hierarchy of " + type);
    }

    protected void emitPhaseMarker() {
        PhaseMarkerEvent event = new PhaseMarkerEvent();
        event.phase = "measurement";
        event.iteration = 0;
        event.benchmarkClass = getClass().getSimpleName();
        event.commit();
    }
}
