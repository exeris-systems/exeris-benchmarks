package eu.exeris.benchmarks.targets.quarkusapp.transport;

import io.netty.handler.ssl.OpenSsl;
import io.quarkus.vertx.http.HttpServerOptionsCustomizer;
import io.vertx.core.http.HttpServerOptions;
import io.vertx.core.net.OpenSSLEngineOptions;

import jakarta.enterprise.context.ApplicationScoped;

import org.eclipse.microprofile.config.inject.ConfigProperty;
import org.jboss.logging.Logger;

/**
 * Selects the HTTPS server's TLS engine — JSSE (JDK SSLEngine, pure Java) or the
 * native BoringSSL engine — for the {@code quarkus-benchmark-app-tuned} target.
 *
 * <p>This is the TLS-engine half of the Netty transport/TLS axis pair (the other
 * half — JDK NIO vs native epoll — is pure config: {@code quarkus.vertx.prefer-native-transport}).
 * Quarkus exposes no built-in knob to pick the HTTP server's SSL engine:
 * {@code HttpServerOptionsUtils} only ever installs {@link io.vertx.core.net.JdkSSLEngineOptions}.
 * The supported extension point is an {@link HttpServerOptionsCustomizer} CDI bean,
 * which is what this class is.</p>
 *
 * <ul>
 *   <li>{@code exeris.transport.tls.native=true} (default) — installs
 *       {@link OpenSSLEngineOptions} so the HTTPS listener terminates TLS with the
 *       native BoringSSL engine. {@code netty-tcnative-boringssl-static} is always
 *       on the classpath (declared in the main {@code <dependencies>}).</li>
 *   <li>{@code exeris.transport.tls.native=false} — no-op; Vert.x keeps the JDK
 *       SSLEngine (JSSE). The runtime opt-out for a pure-Java TLS comparison.</li>
 * </ul>
 *
 * <p>When native TLS is explicitly requested but the native provider is not loadable,
 * this fails fast rather than silently falling back to JSSE — a benchmark run labelled
 * "native TLS" that quietly ran on the JDK engine would corrupt the comparison, which
 * the fairness/honesty rules of this lab forbid.</p>
 */
@ApplicationScoped
public class NativeTlsEngineCustomizer implements HttpServerOptionsCustomizer {

    private static final Logger LOG = Logger.getLogger(NativeTlsEngineCustomizer.class);

    @ConfigProperty(name = "exeris.transport.tls.native", defaultValue = "false")
    boolean nativeTls;

    @Override
    public void customizeHttpsServer(HttpServerOptions options) {
        if (!nativeTls) {
            LOG.debug("TLS engine: JSSE (JDK SSLEngine) — exeris.transport.tls.native=false");
            return;
        }
        if (!OpenSSLEngineOptions.isAvailable()) {
            throw new IllegalStateException(
                    "exeris.transport.tls.native=true but the native BoringSSL provider is not available. "
                            + "Build with -Pnetty-tcnative-boringssl so netty-tcnative-boringssl-static is on the "
                            + "classpath, or set EXERIS_TLS_NATIVE=false to use the JDK SSLEngine (JSSE). "
                            + "Refusing to silently fall back to JSSE for a run labelled native TLS.",
                    OpenSsl.unavailabilityCause());
        }
        options.setSslEngineOptions(new OpenSSLEngineOptions());
        LOG.info("TLS engine: native BoringSSL (OpenSSLEngineOptions) — exeris.transport.tls.native=true");
    }
}
