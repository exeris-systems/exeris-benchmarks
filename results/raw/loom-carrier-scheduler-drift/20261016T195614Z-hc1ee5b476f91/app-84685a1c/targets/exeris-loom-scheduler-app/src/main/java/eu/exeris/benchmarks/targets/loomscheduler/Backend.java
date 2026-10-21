/*
 * Copyright (C) 2025-2026 Exeris Systems.
 * SPDX-License-Identifier: Apache-2.0
 */
package eu.exeris.benchmarks.targets.loomscheduler;

/**
 * One blocking call to the mock backend, made from the calling virtual thread.
 */
interface Backend extends AutoCloseable {

    /**
     * Sends {@code GET /mock}, reads the complete response and returns its body length.
     *
     * @return the number of body bytes the backend sent
     * @throws Exception when no 200 response could be read
     */
    int fetch() throws Exception;

    /** A short label for the startup banner. */
    String describe();

    @Override
    void close();
}
