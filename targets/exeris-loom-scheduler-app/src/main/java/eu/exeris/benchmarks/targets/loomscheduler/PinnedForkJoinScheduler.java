/*
 * Copyright (C) 2025-2026 Exeris Systems.
 * SPDX-License-Identifier: Apache-2.0
 */
package eu.exeris.benchmarks.targets.loomscheduler;

import java.util.Arrays;
import java.util.concurrent.ForkJoinPool;
import java.util.concurrent.ForkJoinTask;
import java.util.concurrent.Future;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicInteger;

import eu.exeris.kernel.core.transport.scheduler.locality.ExerisCarrierThread;
import jdk.internal.access.JavaLangAccess;
import jdk.internal.access.SharedSecrets;
import jdk.internal.misc.CarrierThread;

/**
 * The stock virtual-thread scheduler with each worker bound to one CPU: the arm that separates
 * pinning from the change of scheduling algorithm.
 *
 * <p>Loaded with {@code -Djdk.virtualThreadScheduler.implClass=} this class. Everything except the
 * binding and one submit path is the JDK's built-in scheduler, reproduced rather than approximated:
 * <ul>
 *   <li>the pool is constructed with the built-in's arguments — async mode, no core pool,
 *       parallelism, maxPoolSize and minRunnable read from the same
 *       {@code jdk.virtualThreadScheduler.*} properties with the same defaults, saturation always
 *       allowed, 30 s keep-alive — so work stealing, spinning and worker retirement are the stock
 *       pool's;</li>
 *   <li>its workers are {@link CarrierThread}s, so the JDK's carrier-only paths (lazy submit
 *       after a park, external submit on yield, compensation around blocking calls) apply to them
 *       as they do to the built-in workers;</li>
 *   <li>the submit path the JDK reserves for the built-in scheduler by identity in
 *       {@code start()} — a thread started from a virtual thread goes to the submission queue — is
 *       taken here under the same condition;</li>
 *   <li>one path differs: an unpark issued from a virtual thread on one of these workers is
 *       lazy-submitted to that worker's queue without a signal, where the built-in scheduler's
 *       {@code onContinue} calls {@code execute()}, which may signal an idle worker. With
 *       {@code -Dloom.bench.pinned.continue=execute} every continuation is executed as the
 *       built-in does, so the difference can be measured on its own;</li>
 *   <li>timed waits are scheduled on the pool's own delay scheduler, as the built-in's are.</li>
 * </ul>
 *
 * <p>The binding is done by each worker on itself in {@link PinnedCarrier#onStart()}, to a CPU of
 * {@code exeris.carrier.affinity} that no live worker holds, and released in
 * {@link PinnedCarrier#onTermination(Throwable)}. The pool retires idle workers after the
 * keep-alive and creates new ones later; a binding applied from outside to the threads that exist
 * at one moment would not reach their replacements. maxPoolSize may not exceed the number of CPUs,
 * so a starting worker always finds one free.
 *
 * <p>With {@code -Dloom.bench.pinned.bind=false} the workers bind nothing and the class is the
 * built-in scheduler reproduced through the SPI, with the one submit path above: the arm that
 * checks the reproduction against the built-in itself, so that a difference between the pinned
 * arm and the built-in can be attributed to the binding.
 *
 * <p>Needs {@code --add-exports java.base/jdk.internal.misc=ALL-UNNAMED} and
 * {@code --add-exports java.base/jdk.internal.access=ALL-UNNAMED} at compile time and run time.
 */
public final class PinnedForkJoinScheduler implements Thread.VirtualThreadScheduler {

    private static final JavaLangAccess JLA = SharedSecrets.getJavaLangAccess();

    private final ForkJoinPool pool;
    private final boolean bind;
    private final boolean lazyContinue;
    private final int[] cpus;
    private final boolean[] held;
    private final AtomicInteger workerSeq = new AtomicInteger();

    public PinnedForkJoinScheduler(Thread.VirtualThreadScheduler builtin) {
        this.bind = Boolean.parseBoolean(System.getProperty("loom.bench.pinned.bind", "true"));
        String continueMode = System.getProperty("loom.bench.pinned.continue", "lazy");
        if (!continueMode.equals("lazy") && !continueMode.equals("execute")) {
            throw new IllegalArgumentException("loom.bench.pinned.continue must be lazy or execute, was " + continueMode);
        }
        this.lazyContinue = continueMode.equals("lazy");
        this.cpus = bind ? parseCpus(System.getProperty("exeris.carrier.affinity")) : new int[0];
        this.held = new boolean[cpus.length];
        String parallelismValue = System.getProperty("jdk.virtualThreadScheduler.parallelism");
        String maxPoolSizeValue = System.getProperty("jdk.virtualThreadScheduler.maxPoolSize");
        String minRunnableValue = System.getProperty("jdk.virtualThreadScheduler.minRunnable");
        int parallelism = parallelismValue != null
                ? Integer.parseInt(parallelismValue)
                : Runtime.getRuntime().availableProcessors();
        int maxPoolSize;
        if (maxPoolSizeValue != null) {
            maxPoolSize = Integer.parseInt(maxPoolSizeValue);
            parallelism = Integer.min(parallelism, maxPoolSize);
        } else {
            maxPoolSize = Integer.max(parallelism, 256);
        }
        int minRunnable = minRunnableValue != null
                ? Integer.parseInt(minRunnableValue)
                : Integer.max(parallelism / 2, 1);
        if (bind && maxPoolSize > cpus.length) {
            throw new IllegalStateException("jdk.virtualThreadScheduler.maxPoolSize " + maxPoolSize
                    + " exceeds the " + cpus.length + " CPUs of exeris.carrier.affinity; every worker needs its own");
        }
        this.pool = new ForkJoinPool(parallelism, PinnedCarrier::new, (t, e) -> { }, true,
                0, maxPoolSize, minRunnable, p -> true, 30, TimeUnit.SECONDS);
        System.out.println("[PinnedForkJoinScheduler] parallelism=" + parallelism + " maxPoolSize=" + maxPoolSize
                + " minRunnable=" + minRunnable + (bind ? " cpus=" + Arrays.toString(cpus) : " binding off")
                + " continue=" + continueMode);
    }

    @Override
    public void onStart(Thread.VirtualThreadTask task) {
        if (Thread.currentThread().isVirtual() && JLA.currentCarrierThread() instanceof PinnedCarrier carrier
                && carrier.getPool() == pool) {
            pool.externalSubmit(ForkJoinTask.adapt(task));
        } else {
            pool.execute(ForkJoinTask.adapt(task));
        }
    }

    @Override
    public void onContinue(Thread.VirtualThreadTask task) {
        // On a virtual thread this is an unpark: every other continuation is submitted from the
        // carrier itself, after the continuation has unmounted.
        if (lazyContinue && Thread.currentThread().isVirtual()
                && JLA.currentCarrierThread() instanceof PinnedCarrier carrier && carrier.getPool() == pool) {
            pool.lazySubmit(ForkJoinTask.adapt(task));
        } else {
            pool.execute(ForkJoinTask.adapt(task));
        }
    }

    @Override
    public Future<?> schedule(Runnable task, long delay, TimeUnit unit) {
        return pool.schedule(task, delay, unit);
    }

    private synchronized int acquireCpu() {
        for (int i = 0; i < held.length; i++) {
            if (!held[i]) {
                held[i] = true;
                return i;
            }
        }
        return -1;
    }

    private synchronized void releaseCpu(int slot) {
        if (slot >= 0) {
            held[slot] = false;
        }
    }

    private static int[] parseCpus(String value) {
        if (value == null || value.isBlank()) {
            throw new IllegalStateException("exeris.carrier.affinity is required: the CPUs the workers are bound to");
        }
        return Arrays.stream(value.split(",")).map(String::trim).mapToInt(Integer::parseInt).toArray();
    }

    private final class PinnedCarrier extends CarrierThread {
        private int slot = -1;

        PinnedCarrier(ForkJoinPool pool) {
            super(pool);
        }

        @Override
        protected void onStart() {
            super.onStart();
            setName("spi-fjp-worker-" + workerSeq.incrementAndGet());
            if (!bind) {
                System.out.println("[PinnedForkJoinScheduler] " + getName() + " started, binding off");
                return;
            }
            slot = acquireCpu();
            // A worker without a CPU keeps the mask it inherited; the harness's isolation gate
            // rejects the trial rather than this scheduler hiding it.
            boolean bound = slot >= 0 && ExerisCarrierThread.bindToCore(cpus[slot]);
            System.out.println("[PinnedForkJoinScheduler] " + getName() + " started, "
                    + (bound ? "bound to CPU " + cpus[slot] : "NOT BOUND"));
        }

        @Override
        protected void onTermination(Throwable exception) {
            releaseCpu(slot);
            System.out.println("[PinnedForkJoinScheduler] " + getName() + " terminated, released CPU "
                    + (slot >= 0 ? cpus[slot] : "none"));
            slot = -1;
            super.onTermination(exception);
        }
    }
}
