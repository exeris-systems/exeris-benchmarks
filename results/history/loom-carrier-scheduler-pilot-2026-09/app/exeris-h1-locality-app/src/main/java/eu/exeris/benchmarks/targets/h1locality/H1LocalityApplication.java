package eu.exeris.benchmarks.targets.h1locality;

import eu.exeris.kernel.core.bootstrap.KernelBootstrap;
import eu.exeris.kernel.spi.bootstrap.BootstrapSelector;
import eu.exeris.kernel.spi.http.HttpHandler;
import eu.exeris.kernel.spi.http.HttpKernelProviders;
import eu.exeris.kernel.spi.http.HttpStatus;

import java.util.concurrent.CountDownLatch;
import java.util.concurrent.atomic.AtomicReference;

/**
 * Pure H1 benchmark application for measuring continuation locality and scheduler geometry.
 * Binds a lightweight HTTP/1.1 endpoint with zero database or ORM overhead.
 */
public final class H1LocalityApplication {

    private static final String BASE_SUBSYSTEMS = "memory,transport,http";

    private H1LocalityApplication() {}

    public static void main(String[] args) throws Exception {
        int port = Integer.getInteger("exeris.http.port", 8080);
        String host = System.getProperty("exeris.http.bindHost", "0.0.0.0");

        System.setProperty("exeris.launcher.subsystems", BASE_SUBSYSTEMS);
        System.setProperty("exeris.http.bindHost", host);
        System.setProperty("exeris.http.port", Integer.toString(port));
        System.setProperty("exeris.http.mode", "SERVER");
        System.setProperty("exeris.http.maxVersion", "HTTP_1_1");
        System.setProperty("exeris.http.h2cUpgradeEnabled", "false");

        System.out.println("=================================================================");
        System.out.println(" Starting H1 Locality Target Application");
        System.out.println("   Host: " + host + ":" + port);
        System.out.println("   Subsystems: " + BASE_SUBSYSTEMS);
        System.out.println("   Poller Mode: " + System.getProperty("jdk.pollerMode", "default"));
        System.out.println("   Custom Scheduler: " + System.getProperty("jdk.virtualThreadScheduler.implClass", "default"));
        System.out.println("=================================================================");

        CountDownLatch bootLatch = new CountDownLatch(1);
        AtomicReference<HttpHandler> handlerSlot = new AtomicReference<>();

        int defaultDelayMs = Integer.getInteger("exeris.simulated.delay.ms", 20);
        int defaultStateKb = Integer.getInteger("exeris.simulated.state.kb", 8);

        HttpHandler rootHandler = exchange -> {
            String path = exchange.request().path();
            if ("/plaintext".equals(path) || "/health".equals(path)) {
                exchange.respond(HttpStatus.OK);
            } else if ("/delayed".equals(path) || path.startsWith("/delayed")) {
                int stateBytes = defaultStateKb * 1024;
                byte[] state = new byte[stateBytes];
                for (int i = 0; i < state.length; i += 64) {
                    state[i] = (byte) (i & 0xFF);
                }
                if (defaultDelayMs > 0) {
                    try {
                        Thread.sleep(defaultDelayMs);
                    } catch (InterruptedException e) {
                        Thread.currentThread().interrupt();
                    }
                }
                int sum = 0;
                for (int i = 0; i < state.length; i += 64) {
                    sum += state[i];
                }
                if (sum == 123456789) {
                    System.out.print("");
                }
                exchange.respond(HttpStatus.OK);
            } else {
                exchange.respond(HttpStatus.NOT_FOUND);
            }
        };
        handlerSlot.set(rootHandler);

        HttpHandler forwardingHandler = exchange -> {
            HttpHandler h = handlerSlot.get();
            if (h != null) {
                h.handle(exchange);
            }
        };

        CountDownLatch stopLatch = new CountDownLatch(1);
        Runtime.getRuntime().addShutdownHook(new Thread(stopLatch::countDown));

        ScopedValue.where(HttpKernelProviders.HTTP_SERVER_HANDLER, forwardingHandler)
            .call(() -> {
                KernelBootstrap.builder()
                    .selector(BootstrapSelector.forNames(BASE_SUBSYSTEMS.split(",")))
                    .build()
                    .boot(() -> {
                        System.out.println(">>> H1 Locality Application Boot Complete and Listening <<<");
                        bootLatch.countDown();
                        try {
                            stopLatch.await();
                        } catch (InterruptedException _) {
                            Thread.currentThread().interrupt();
                        }
                    });
                return null;
            });
    }
}
