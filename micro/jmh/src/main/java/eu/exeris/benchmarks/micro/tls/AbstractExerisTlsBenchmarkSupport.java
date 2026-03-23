package eu.exeris.benchmarks.micro.tls;

import eu.exeris.kernel.spi.crypto.CryptoProviderConfig;
import eu.exeris.kernel.spi.memory.LoanedBuffer;
import eu.exeris.kernel.spi.memory.MemoryAllocator;
import eu.exeris.kernel.spi.crypto.TlsStatus;

import java.lang.foreign.MemorySegment;
import java.lang.foreign.ValueLayout;
import java.lang.reflect.InvocationTargetException;
import java.lang.reflect.Method;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.List;

public abstract class AbstractExerisTlsBenchmarkSupport {

    protected record ResolvedProviderConfig(
            String cryptoProviderClass,
            String memoryProviderClass,
            Path certPem,
            Path keyPem
    ) {
    }

    protected static ResolvedProviderConfig resolveProviderConfig(String tier) {
        String tierPrefix = "exeris.tls." + tier + ".";
        String globalPrefix = "exeris.tls.";

        String cryptoProviderClass = firstNonNull(
                resolveProperty(tierPrefix, globalPrefix, "cryptoProviderClass"),
                resolveProperty(tierPrefix, globalPrefix, "providerClass"),
                resolveProperty(tierPrefix, globalPrefix, "provider")
        );
        if (cryptoProviderClass == null) {
            throw new IllegalStateException("Missing KernelCryptoProvider class for tier '" + tier + "'. "
                    + "Set -D" + tierPrefix + "cryptoProviderClass=<fqcn> or -D" + globalPrefix + "cryptoProviderClass=<fqcn>.");
        }

        String memoryProviderClass = firstNonNull(
                resolveProperty(tierPrefix, globalPrefix, "memoryProviderClass"),
                resolveProperty(tierPrefix, globalPrefix, "memoryProvider")
        );
        if (memoryProviderClass == null) {
            throw new IllegalStateException("Missing MemoryProvider class for tier '" + tier + "'. "
                    + "Set -D" + tierPrefix + "memoryProviderClass=<fqcn> or -D" + globalPrefix + "memoryProviderClass=<fqcn>.");
        }

        String certPemValue = resolveProperty(tierPrefix, globalPrefix, "certPem");
        String keyPemValue = resolveProperty(tierPrefix, globalPrefix, "keyPem");
        if (certPemValue == null || keyPemValue == null) {
            throw new IllegalStateException("Missing TLS server credentials for tier '" + tier + "'. "
                    + "Set -D" + tierPrefix + "certPem / keyPem (or global exeris.tls.certPem / keyPem).");
        }

        Path certPemPath = Path.of(certPemValue);
        Path keyPemPath = Path.of(keyPemValue);

        if (!Files.exists(certPemPath) || !Files.isReadable(certPemPath)) {
            throw new IllegalStateException("Invalid TLS certificate path for tier '" + tier + "': "
                + certPemPath.toAbsolutePath() + " (file must exist and be readable)");
        }
        if (!Files.exists(keyPemPath) || !Files.isReadable(keyPemPath)) {
            throw new IllegalStateException("Invalid TLS private key path for tier '" + tier + "': "
                + keyPemPath.toAbsolutePath() + " (file must exist and be readable)");
        }

        return new ResolvedProviderConfig(
            cryptoProviderClass,
            memoryProviderClass,
            certPemPath,
            keyPemPath
        );
    }

    private static String resolveProperty(String tierPrefix, String globalPrefix, String suffix) {
        String tierValue = normalize(System.getProperty(tierPrefix + suffix));
        if (tierValue != null) {
            return tierValue;
        }
        return normalize(System.getProperty(globalPrefix + suffix));
    }

    protected static <T> T instantiate(String className, Class<T> expectedType, String propertyName) {
        Class<?> type;
        try {
            type = Class.forName(className);
        } catch (ClassNotFoundException e) {
            throw new IllegalStateException("Configured class not found for property '" + propertyName + "': " + className, e);
        }
        if (!expectedType.isAssignableFrom(type)) {
            throw new IllegalStateException("Configured class '" + className + "' from property '" + propertyName
                    + "' does not implement " + expectedType.getName());
        }
        try {
            return expectedType.cast(type.getDeclaredConstructor().newInstance());
        } catch (ReflectiveOperationException e) {
            throw new IllegalStateException("Configured class '" + className + "' from property '" + propertyName
                    + "' is not instantiable via accessible no-arg constructor", e);
        }
    }

    protected static <T> T instantiateWithAllocator(
            String className,
            Class<T> expectedType,
            String propertyName,
            MemoryAllocator allocator) {
        Class<?> type;
        try {
            type = Class.forName(className);
        } catch (ClassNotFoundException e) {
            throw new IllegalStateException("Configured class not found for property '" + propertyName + "': " + className, e);
        }
        if (!expectedType.isAssignableFrom(type)) {
            throw new IllegalStateException("Configured class '" + className + "' from property '" + propertyName
                    + "' does not implement " + expectedType.getName());
        }
        if (allocator != null) {
            try {
                return expectedType.cast(type.getDeclaredConstructor(MemoryAllocator.class).newInstance(allocator));
            } catch (NoSuchMethodException ignored) {
                // Fall back to the no-arg constructor when allocator-aware construction is not supported.
            } catch (ReflectiveOperationException e) {
                throw new IllegalStateException("Configured class '" + className + "' from property '" + propertyName
                        + "' is not instantiable via MemoryAllocator constructor", e);
            }
        }
        try {
            return expectedType.cast(type.getDeclaredConstructor().newInstance());
        } catch (ReflectiveOperationException e) {
            throw new IllegalStateException("Configured class '" + className + "' from property '" + propertyName
                    + "' is not instantiable via accessible no-arg constructor", e);
        }
    }

    protected static void warmUpProviderIfSupported(
            Object provider,
            CryptoProviderConfig serverConfig,
            CryptoProviderConfig clientConfig) {
        Method warmUp = findMethod(provider.getClass(), "warmUp", CryptoProviderConfig.class, CryptoProviderConfig.class);
        if (warmUp == null) {
            return;
        }
        try {
            warmUp.invoke(provider, serverConfig, clientConfig);
        } catch (InvocationTargetException e) {
            Throwable target = e.getCause();
            String causeType = target == null ? "<unknown>" : target.getClass().getName();
            String causeMessage = target == null || target.getMessage() == null ? "<no message>" : target.getMessage();
            throw new IllegalStateException("Failed to warm up TLS provider " + provider.getClass().getName()
                    + "; provider warmUp threw " + causeType + ": " + causeMessage, e);
        } catch (ReflectiveOperationException e) {
            throw new IllegalStateException("Failed to warm up TLS provider " + provider.getClass().getName(), e);
        }
    }

    protected static void fillPayload(LoanedBuffer buffer, int len) {
        MemorySegment segment = buffer.segment();
        for (int i = 0; i < len; i++) {
            segment.set(ValueLayout.JAVA_BYTE, i, (byte) (i & 0xFF));
        }
        buffer.setSize(len);
    }

    protected static boolean indicatesProgress(TlsStatus status) {
        return status == TlsStatus.OK || status == TlsStatus.FINISHED;
    }

    protected static void closeQuietly(AutoCloseable c, List<Exception> errors) {
        if (c == null) {
            return;
        }
        try {
            c.close();
        } catch (Exception e) {
            errors.add(e);
        }
    }

    protected static Method findMethod(Class<?> type, String name, Class<?>... parameterTypes) {
        Class<?> cursor = type;
        while (cursor != null) {
            try {
                Method method = cursor.getDeclaredMethod(name, parameterTypes);
                method.setAccessible(true);
                return method;
            } catch (NoSuchMethodException ignored) {
                cursor = cursor.getSuperclass();
            }
        }
        return null;
    }

    @SafeVarargs
    protected static <T> T firstNonNull(T... values) {
        for (T value : values) {
            if (value != null) {
                return value;
            }
        }
        return null;
    }

    protected static String normalize(String value) {
        if (value == null) {
            return null;
        }
        String trimmed = value.trim();
        return trimmed.isEmpty() ? null : trimmed;
    }
}
