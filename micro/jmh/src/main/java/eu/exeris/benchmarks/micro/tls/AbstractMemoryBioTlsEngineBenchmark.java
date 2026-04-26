package eu.exeris.benchmarks.micro.tls;

import eu.exeris.kernel.spi.crypto.CryptoProviderConfig;
import eu.exeris.kernel.spi.crypto.KernelCryptoProvider;
import eu.exeris.kernel.spi.crypto.TlsEngine;
import eu.exeris.kernel.spi.crypto.TlsStatus;
import eu.exeris.kernel.spi.memory.LoanedBuffer;
import eu.exeris.kernel.spi.memory.MemoryAllocator;
import eu.exeris.kernel.spi.memory.MemoryProvider;
import eu.exeris.kernel.spi.memory.MemoryProviderConfig;
import org.openjdk.jmh.annotations.AuxCounters;
import org.openjdk.jmh.annotations.Benchmark;
import org.openjdk.jmh.annotations.BenchmarkMode;
import org.openjdk.jmh.annotations.Fork;
import org.openjdk.jmh.annotations.Level;
import org.openjdk.jmh.annotations.Measurement;
import org.openjdk.jmh.annotations.Mode;
import org.openjdk.jmh.annotations.OperationsPerInvocation;
import org.openjdk.jmh.annotations.OutputTimeUnit;
import org.openjdk.jmh.annotations.Param;
import org.openjdk.jmh.annotations.Scope;
import org.openjdk.jmh.annotations.Setup;
import org.openjdk.jmh.annotations.State;
import org.openjdk.jmh.annotations.TearDown;
import org.openjdk.jmh.annotations.Warmup;
import org.openjdk.jmh.infra.Blackhole;

import java.lang.invoke.MethodHandle;
import java.lang.invoke.MethodHandles;
import java.lang.invoke.MethodType;
import java.lang.invoke.WrongMethodTypeException;
import java.lang.reflect.Method;
import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.TimeUnit;

/**
 * Abstract JMH harness for a neutral in-process Memory-BIO TLS engine lens.
 *
 * <p><b>Measurement scope:</b> {@code wrapThroughput} measures TLS encrypt + in-process
 * Memory-BIO write. There is no kernel syscall or socket FD involved. This transport-agnostic
 * engine lens is not directly equivalent to FD-owner socket paths that include a {@code write(2)}
 * kernel crossing per record.
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
        // runner process and appends jvmArgsAppend on top - repeating them here causes
        // the duplication seen in '# VM options:'. Keep only the annotation-specific hint.
        "-XX:+PreserveFramePointer"
    })
public abstract class AbstractMemoryBioTlsEngineBenchmark extends AbstractExerisTlsBenchmarkSupport {

    @Param({"128", "1024", "4096", "16384"})
    public int payloadBytes;

    private KernelCryptoProvider cryptoProvider;
    private MemoryProvider memoryProvider;
    private MemoryAllocator allocator;

    private TlsEngine clientEngine;
    private TlsEngine serverEngine;

    private Object clientConnector;
    private Object serverConnector;

    private LoanedBuffer clientPlain;
    private LoanedBuffer cipherBuffer;
    private LoanedBuffer serverPlain;
    private LoanedBuffer clientHsOut;
    private LoanedBuffer serverHsOut;
    private LoanedBuffer emptyBuffer;

    // Cached MethodHandles to avoid reflective invoke/boxing overhead on hot paths.
    private MethodHandle clientDrainHandle;
    private MethodHandle serverDrainHandle;
    private MethodHandle clientInjectHandle;
    private MethodHandle serverInjectHandle;

    private static final int NET_BUFFER_SIZE = 16_384 + 2048;
    private static final int MAX_HANDSHAKE_STEPS = 512;
    private static final int MAX_WRAP_ATTEMPTS = 8;

    protected abstract String tier();

    /**
     * Returns the provider-lookup tier key used to resolve system properties
     * (e.g. {@code exeris.tls.<providerTier()>.cryptoProviderClass}).
     *
     * <p>Override when the benchmark lens identity ({@link #tier()}) differs from
     * the provider tier. Default: delegates to {@link #tier()}.
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

        clientConnector = resolveConnector(clientEngine);
        serverConnector = resolveConnector(serverEngine);

        Method clientDrainMethod = findMethod(clientConnector.getClass(), "drain", LoanedBuffer.class);
        Method serverDrainMethod = findMethod(serverConnector.getClass(), "drain", LoanedBuffer.class);
        Method clientInjectMethod = findMethod(clientConnector.getClass(), "inject", LoanedBuffer.class);
        Method serverInjectMethod = findMethod(serverConnector.getClass(), "inject", LoanedBuffer.class);

        if (clientDrainMethod == null || serverDrainMethod == null || clientInjectMethod == null || serverInjectMethod == null) {
            throw new IllegalStateException("Failed to cache connector methods during setup");
        }

        try {
            this.clientDrainHandle = connectorMethodHandle(clientDrainMethod, "client drain");
            this.serverDrainHandle = connectorMethodHandle(serverDrainMethod, "server drain");
            this.clientInjectHandle = connectorMethodHandle(clientInjectMethod, "client inject");
            this.serverInjectHandle = connectorMethodHandle(serverInjectMethod, "server inject");
        } catch (IllegalStateException e) {
            throw new IllegalStateException("Failed to cache connector methods during setup", e);
        }

        clientEngine.notifyBound();
        serverEngine.notifyBound();

        clientPlain = allocator.allocateNetwork(NET_BUFFER_SIZE);
        cipherBuffer = allocator.allocateNetwork(NET_BUFFER_SIZE);
        serverPlain = allocator.allocateNetwork(NET_BUFFER_SIZE);
        clientHsOut = allocator.allocateNetwork(NET_BUFFER_SIZE);
        serverHsOut = allocator.allocateNetwork(NET_BUFFER_SIZE);
        emptyBuffer = allocator.allocateNetwork(NET_BUFFER_SIZE);
        emptyBuffer.setSize(0);

        fillPayload(clientPlain, payloadBytes);
        performMemoryBioHandshake();
    }

    @TearDown(Level.Trial)
    public void tearDown() throws Exception {
        List<Exception> errors = new ArrayList<>();
        closeQuietly(serverEngine, errors);
        closeQuietly(clientEngine, errors);
        closeQuietly(emptyBuffer, errors);
        closeQuietly(serverHsOut, errors);
        closeQuietly(clientHsOut, errors);
        closeQuietly(serverPlain, errors);
        closeQuietly(cipherBuffer, errors);
        closeQuietly(clientPlain, errors);
        closeQuietly(allocator, errors);
        closeQuietly(memoryProvider instanceof AutoCloseable ? (AutoCloseable) memoryProvider : null, errors);
        closeQuietly(cryptoProvider instanceof AutoCloseable ? (AutoCloseable) cryptoProvider : null, errors);

        cryptoProvider = null;
        memoryProvider = null;
        allocator = null;
        clientEngine = null;
        serverEngine = null;
        clientConnector = null;
        serverConnector = null;
        clientPlain = null;
        cipherBuffer = null;
        serverPlain = null;
        clientHsOut = null;
        serverHsOut = null;
        emptyBuffer = null;
        clientDrainHandle = null;
        serverDrainHandle = null;
        clientInjectHandle = null;
        serverInjectHandle = null;

        if (!errors.isEmpty()) {
            Exception first = errors.get(0);
            for (int i = 1; i < errors.size(); i++) {
                first.addSuppressed(errors.get(i));
            }
            throw first;
        }
    }

    @Benchmark
    @BenchmarkMode(Mode.Throughput)
    @OutputTimeUnit(TimeUnit.SECONDS)
    public void wrapThroughput(Blackhole bh) {
        clientPlain.setSize(payloadBytes);
        cipherBuffer.setSize(0);
        invokeDrain(clientConnector, cipherBuffer);
        cipherBuffer.setSize(0);

        TlsStatus status = null;
        long produced = 0;
        for (int attempt = 1; attempt <= MAX_WRAP_ATTEMPTS; attempt++) {
            status = clientEngine.wrap(clientPlain, cipherBuffer);
            produced = cipherBuffer.size();
            if ((status == TlsStatus.OK || status == TlsStatus.FINISHED) && produced > 0) {
                bh.consume(status);
                bh.consume(produced);
                return;
            }
            if (status == TlsStatus.NEED_WRAP) {
                int drained = invokeDrain(clientConnector, cipherBuffer);
                if (drained <= 0) {
                    throw new IllegalStateException("wrapThroughput NEED_WRAP drain made no progress"
                            + " tier=" + tier()
                            + " payload=" + payloadBytes
                            + " attempt=" + attempt
                            + " status=" + status
                            + " produced=" + produced
                            + " drained=" + drained);
                }
                cipherBuffer.setSize(0);
                continue;
            }
            break;
        }
        requireWrapOk(status, produced, "wrapThroughput");
        bh.consume(status);
        bh.consume(produced);
    }

    private static final int MAX_UNWRAP_ITERATIONS = 16;

    @State(Scope.Thread)
    @AuxCounters(AuxCounters.Type.OPERATIONS)
    public static class TransportAuxCounters {
        public long injectCalls;
        public long injectChunks;
        public long drainCalls;

        @Setup(Level.Invocation)
        public void reset() {
            injectCalls = 0;
            injectChunks = 0;
            drainCalls = 0;
        }
    }

    @Benchmark
    @BenchmarkMode(Mode.SampleTime)
    @OutputTimeUnit(TimeUnit.MICROSECONDS)
    @OperationsPerInvocation(2)
    public void wrapUnwrapRoundTrip(Blackhole bh, TransportAuxCounters counters) throws Exception {
        wrapUnwrapRoundTripBioPumpIncluded(bh, counters);
    }

    public void wrapUnwrapRoundTripBioPumpIncluded(Blackhole bh, TransportAuxCounters counters) throws Exception {
        clientPlain.setSize(payloadBytes);
        cipherBuffer.setSize(0);
        TlsStatus wrapStatus = clientEngine.wrap(clientPlain, cipherBuffer);
        long wrapProduced = cipherBuffer.size();
        requireWrapOk(wrapStatus, wrapProduced, "wrapUnwrapRoundTripBioPumpIncluded/wrap");
        bh.consume(wrapStatus);

        invokeInject(serverConnector, cipherBuffer, counters);
        cipherBuffer.setSize(0);

        serverPlain.setSize(0);
        TlsStatus unwrapStatus = null;
        long prevProduced;
        for (int i = 0; i < MAX_UNWRAP_ITERATIONS; i++) {
            prevProduced = serverPlain.size();
            unwrapStatus = serverEngine.unwrap(emptyBuffer, serverPlain);
            long nowProduced = serverPlain.size();
            boolean producedProgress = nowProduced > prevProduced;
            boolean pumpProgress = false;
            if ((unwrapStatus == TlsStatus.OK || unwrapStatus == TlsStatus.FINISHED) && nowProduced > 0) {
                bh.consume(unwrapStatus);
                bh.consume(nowProduced);
                return;
            }
            if (unwrapStatus == TlsStatus.NEED_UNWRAP) {
                cipherBuffer.setSize(0);
                int drained = invokeDrain(clientConnector, cipherBuffer, counters);
                if (drained > 0) {
                    invokeInject(serverConnector, cipherBuffer, counters);
                    cipherBuffer.setSize(0);
                    pumpProgress = true;
                }
                if (producedProgress || pumpProgress) {
                    continue;
                }
                throw new IllegalStateException("wrapUnwrapRoundTripBioPumpIncluded unwrap stalled (NEED_UNWRAP no progress)"
                        + " tier=" + tier()
                        + " payload=" + payloadBytes
                        + " iteration=" + i
                        + " status=" + unwrapStatus
                        + " produced=" + nowProduced
                        + " drained=" + drained);
            }
            if (unwrapStatus == TlsStatus.NEED_WRAP) {
                cipherBuffer.setSize(0);
                int serverDrained = invokeDrain(serverConnector, cipherBuffer, counters);
                if (serverDrained > 0) {
                    invokeInject(clientConnector, cipherBuffer, counters);
                    cipherBuffer.setSize(0);
                    pumpProgress = true;
                }
                int clientDrained = invokeDrain(clientConnector, cipherBuffer, counters);
                if (clientDrained > 0) {
                    invokeInject(serverConnector, cipherBuffer, counters);
                    cipherBuffer.setSize(0);
                    pumpProgress = true;
                }
                if (producedProgress || pumpProgress) {
                    continue;
                }
                throw new IllegalStateException("wrapUnwrapRoundTripBioPumpIncluded unwrap stalled (NEED_WRAP no progress)"
                        + " tier=" + tier()
                        + " payload=" + payloadBytes
                        + " iteration=" + i
                        + " status=" + unwrapStatus
                        + " produced=" + nowProduced
                        + " serverDrained=" + serverDrained
                        + " clientDrained=" + clientDrained);
            }
            throw new IllegalStateException("wrapUnwrapRoundTripBioPumpIncluded unwrap unsupported status"
                    + " tier=" + tier()
                    + " payload=" + payloadBytes
                    + " iteration=" + i
                    + " status=" + unwrapStatus
                    + " produced=" + nowProduced);
        }
        throw new IllegalStateException("wrapUnwrapRoundTripBioPumpIncluded unwrap exhausted "
                + MAX_UNWRAP_ITERATIONS + " attempts"
                + " tier=" + tier()
                + " payload=" + payloadBytes
                + " lastStatus=" + unwrapStatus
                + " produced=" + serverPlain.size());
    }

    @BenchmarkMode(Mode.SampleTime)
    @OutputTimeUnit(TimeUnit.MICROSECONDS)
    @OperationsPerInvocation(2)
    public void wrapUnwrapRoundTripEngineOnly(Blackhole bh, TransportAuxCounters counters) {
        clientPlain.setSize(payloadBytes);
        cipherBuffer.setSize(0);
        TlsStatus wrapStatus = clientEngine.wrap(clientPlain, cipherBuffer);
        long wrapProduced = cipherBuffer.size();
        requireWrapOk(wrapStatus, wrapProduced, "wrapUnwrapRoundTripEngineOnly/wrap");
        bh.consume(wrapStatus);

        serverPlain.setSize(0);
        TlsStatus unwrapStatus = null;
        long beforeProduced = serverPlain.size();
        long beforeCipher = cipherBuffer.size();
        for (int i = 0; i < MAX_UNWRAP_ITERATIONS; i++) {
            unwrapStatus = serverEngine.unwrap(cipherBuffer, serverPlain);
            long nowProduced = serverPlain.size();
            long nowCipher = cipherBuffer.size();
            boolean producedProgress = nowProduced > beforeProduced;
            boolean consumedProgress = nowCipher < beforeCipher;

            if ((unwrapStatus == TlsStatus.OK || unwrapStatus == TlsStatus.FINISHED) && nowProduced > 0) {
                bh.consume(unwrapStatus);
                bh.consume(nowProduced);
                return;
            }
            if (unwrapStatus == TlsStatus.NEED_UNWRAP || unwrapStatus == TlsStatus.NEED_WRAP) {
                if (producedProgress || consumedProgress) {
                    beforeProduced = nowProduced;
                    beforeCipher = nowCipher;
                    continue;
                }
                throw new IllegalStateException("wrapUnwrapRoundTripEngineOnly stalled without BIO pump support"
                        + " tier=" + tier()
                        + " payload=" + payloadBytes
                        + " iteration=" + i
                        + " status=" + unwrapStatus
                        + " produced=" + nowProduced
                        + " cipherRemaining=" + nowCipher
                        + " injectCalls=" + counters.injectCalls
                        + " drainCalls=" + counters.drainCalls);
            }
            throw new IllegalStateException("wrapUnwrapRoundTripEngineOnly unwrap unsupported status"
                    + " tier=" + tier()
                    + " payload=" + payloadBytes
                    + " iteration=" + i
                    + " status=" + unwrapStatus
                    + " produced=" + nowProduced
                    + " cipherRemaining=" + nowCipher);
        }
        throw new IllegalStateException("wrapUnwrapRoundTripEngineOnly unwrap exhausted "
                + MAX_UNWRAP_ITERATIONS + " attempts"
                + " tier=" + tier()
                + " payload=" + payloadBytes
                + " lastStatus=" + unwrapStatus
                + " produced=" + serverPlain.size()
                + " cipherRemaining=" + cipherBuffer.size());
    }

    private void requireWrapOk(TlsStatus status, long produced, String op) {
        if (status != TlsStatus.OK && status != TlsStatus.FINISHED) {
            throw new IllegalStateException(op + " unexpected status"
                    + " tier=" + tier()
                    + " payload=" + payloadBytes
                    + " status=" + status
                    + " produced=" + produced);
        }
        if (produced <= 0) {
            throw new IllegalStateException(op + " produced no ciphertext"
                    + " tier=" + tier()
                    + " payload=" + payloadBytes
                    + " status=" + status
                    + " produced=" + produced);
        }
    }

    private Object resolveConnector(TlsEngine engine) throws Exception {
        Method bioConnectorMethod = findMethod(engine.getClass(), "bioConnector");
        if (bioConnectorMethod == null) {
            throw new IllegalStateException("TlsEngine " + engine.getClass().getName()
                    + " does not expose bioConnector() required by the in-process Memory-BIO harness");
        }
        return bioConnectorMethod.invoke(engine);
    }

    private void performMemoryBioHandshake() throws Exception {
        for (int step = 0; step < MAX_HANDSHAKE_STEPS; step++) {
            boolean clientBefore = clientEngine.isHandshakeComplete();
            boolean serverBefore = serverEngine.isHandshakeComplete();

            boolean clientMoved = driveHandshakeSide(clientEngine, serverConnector, clientHsOut, "client");
            boolean serverMoved = driveHandshakeSide(serverEngine, clientConnector, serverHsOut, "server");

            boolean clientAfter = clientEngine.isHandshakeComplete();
            boolean serverAfter = serverEngine.isHandshakeComplete();
            if (clientAfter && serverAfter) {
                return;
            }

            boolean completionProgress = (clientAfter != clientBefore) || (serverAfter != serverBefore);
            if (!clientMoved && !serverMoved && !completionProgress) {
                throw new IllegalStateException("Memory-BIO handshake stalled at step " + step
                        + " tier=" + tier()
                        + " clientComplete=" + clientAfter
                        + " serverComplete=" + serverAfter);
            }
        }

        throw new IllegalStateException("Memory-BIO handshake did not complete within " + MAX_HANDSHAKE_STEPS
                + " steps for tier=" + tier());
    }

    private boolean driveHandshakeSide(
            TlsEngine sourceEngine,
            Object targetConnector,
            LoanedBuffer outbound,
            String sideLabel) {
        if (sourceEngine.isHandshakeComplete()) {
            return false;
        }

        outbound.setSize(0);
        TlsStatus status;
        try {
            status = sourceEngine.beginHandshake(outbound);
        } catch (RuntimeException e) {
            throw new IllegalStateException("Memory-BIO handshake failed on " + sideLabel
                    + " beginHandshake tier=" + tier(), e);
        }
        requireHandshakeStatus(status, sideLabel + " beginHandshake");
        return transferHandshakeOutbound(targetConnector, outbound, sideLabel);
    }

    private boolean transferHandshakeOutbound(Object targetConnector, LoanedBuffer outbound, String sideLabel) {
        long moved = outbound.size();
        if (moved <= 0) {
            return false;
        }
        try {
            invokeInject(targetConnector, outbound);
        } catch (RuntimeException e) {
            throw new IllegalStateException("Memory-BIO handshake failed while transferring " + sideLabel
                    + " outbound tier=" + tier(), e);
        }
        outbound.setSize(0);
        return true;
    }

    private void requireHandshakeStatus(TlsStatus status, String op) {
        if (status == null) {
            throw new IllegalStateException("Memory-BIO handshake returned null status for " + op
                    + " tier=" + tier());
        }
        if (status == TlsStatus.CLOSED) {
            throw new IllegalStateException("Memory-BIO handshake returned CLOSED status for " + op
                    + " tier=" + tier());
        }
        if (status != TlsStatus.NEED_WRAP
                && status != TlsStatus.NEED_UNWRAP
                && status != TlsStatus.FINISHED
                && status != TlsStatus.OK) {
            throw new IllegalStateException("Memory-BIO handshake returned unsupported status " + status
                    + " for " + op + " tier=" + tier());
        }
    }

    private void invokeInject(Object connector, LoanedBuffer outbound) {
        invokeInject(connector, outbound, null);
    }

    private void invokeInject(Object connector, LoanedBuffer outbound, TransportAuxCounters counters) {
        MethodHandle inject = connector == clientConnector ? clientInjectHandle : serverInjectHandle;

        long total = outbound.size();
        if (total <= 0) {
            return;
        }
        long transferred = 0;
        if (counters != null) {
            counters.injectCalls++;
        }
        try {
            // Fast-path full-buffer inject first to minimize LoanedBuffer.peek churn in the hot path.
            int firstInjected = (int) inject.invokeExact(connector, outbound);
            if (firstInjected <= 0) {
                throw new IllegalStateException("TLS BIO connector inject made no forward progress"
                        + " tier=" + tier()
                        + " payload=" + payloadBytes
                        + " transferred=" + transferred
                        + " total=" + total
                        + " remaining=" + total
                        + " injected=" + firstInjected
                        + " connector=" + connector.getClass().getName());
            }
            transferred = firstInjected;

            while (transferred < total) {
                long remaining = total - transferred;
                // VERIFIED: peek() must remain a non-allocating view per the MemoryAllocator SPI contract.
                try (LoanedBuffer chunk = outbound.peek(transferred, remaining)) {
                    if (counters != null) {
                        counters.injectChunks++;
                    }
                    int injected = (int) inject.invokeExact(connector, chunk);
                    if (injected <= 0) {
                        throw new IllegalStateException("TLS BIO connector inject made no forward progress"
                                + " tier=" + tier()
                                + " payload=" + payloadBytes
                                + " transferred=" + transferred
                                + " total=" + total
                                + " remaining=" + remaining
                                + " injected=" + injected
                                + " connector=" + connector.getClass().getName());
                    }
                    transferred += injected;
                }
            }
        } catch (Throwable e) {
            throw new IllegalStateException("Failed to inject handshake data into TLS BIO connector", e);
        }
    }

    private int invokeDrain(Object connector, LoanedBuffer outbound) {
        return invokeDrain(connector, outbound, null);
    }

    private int invokeDrain(Object connector, LoanedBuffer outbound, TransportAuxCounters counters) {
        MethodHandle drain = connector == clientConnector ? clientDrainHandle : serverDrainHandle;
        if (counters != null) {
            counters.drainCalls++;
        }
        try {
            return (int) drain.invokeExact(connector, outbound);
        } catch (Throwable e) {
            throw new IllegalStateException("Failed to drain data from TLS BIO connector"
                    + " connector=" + connector.getClass().getName(), e);
        }
    }

    private MethodHandle connectorMethodHandle(Method method, String operation) {
        MethodType targetType = MethodType.methodType(int.class, Object.class, LoanedBuffer.class);
        try {
            return MethodHandles.lookup().unreflect(method).asType(targetType);
        } catch (IllegalAccessException | WrongMethodTypeException e) {
            throw new IllegalStateException("Failed to adapt TLS BIO connector method handle for " + operation
                    + " method=" + method.getDeclaringClass().getName() + "#" + method.getName(), e);
        }
    }

    protected void emitPhaseMarker() {
        PhaseMarkerEvent event = new PhaseMarkerEvent();
        event.phase = "measurement";
        event.iteration = 0;
        event.benchmarkClass = getClass().getSimpleName();
        event.commit();
    }
}