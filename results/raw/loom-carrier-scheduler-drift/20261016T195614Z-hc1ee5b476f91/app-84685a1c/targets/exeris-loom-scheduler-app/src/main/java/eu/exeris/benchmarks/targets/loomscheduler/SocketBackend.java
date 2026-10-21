/*
 * Copyright (C) 2025-2026 Exeris Systems.
 * SPDX-License-Identifier: Apache-2.0
 */
package eu.exeris.benchmarks.targets.loomscheduler;

import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.InetSocketAddress;
import java.net.Socket;
import java.nio.charset.StandardCharsets;
import java.util.concurrent.LinkedBlockingDeque;

/**
 * Calls the mock backend over blocking {@link Socket} I/O on keep-alive connections.
 *
 * <p>Blocking socket reads and writes on a virtual thread park it through the JDK's
 * {@code sun.nio.ch.Poller}, which is the path the custom scheduler has to service. A client with
 * its own selector thread ({@code java.net.http.HttpClient}) would hand the wait to that thread
 * instead and never put the poller in the loop.
 *
 * <p>The pool holds a fixed number of connection slots. A slot opens its socket lazily, on the
 * virtual thread that first borrows it, and keeps it, with its read buffer, until an I/O error or a
 * peer close. Borrowing takes the most recently returned slot, so under light load only as many
 * sockets are open as there are concurrent calls. When every slot is in use the caller parks until
 * one is returned: the pool size bounds the backend's concurrency.
 *
 * <p>The response parser covers what the mock sends and nothing more: a status line, headers with
 * a {@code Content-Length}, and that many body bytes. Anything else is an I/O error, which closes
 * the connection.
 */
final class SocketBackend implements Backend {

    private static final int CONNECT_TIMEOUT_MS = 2_000;
    private static final int READ_TIMEOUT_MS = 10_000;
    private static final int BUFFER_BYTES = 8_192;
    private static final int HTTP_OK = 200;
    private static final byte[] CONTENT_LENGTH = "content-length:".getBytes(StandardCharsets.US_ASCII);
    private static final byte[] CONNECTION_CLOSE = "connection: close".getBytes(StandardCharsets.US_ASCII);

    private final InetSocketAddress address;
    private final byte[] request;
    private final int poolSize;
    private final LinkedBlockingDeque<Connection> idle;

    SocketBackend(String host, int port, int poolSize) {
        if (poolSize < 1) {
            throw new IllegalArgumentException("loom.bench.backend.pool must be >= 1, was " + poolSize);
        }
        this.address = new InetSocketAddress(host, port);
        this.request = ("GET /mock HTTP/1.1\r\n"
                + "Host: " + host + ":" + port + "\r\n"
                + "Connection: keep-alive\r\n"
                + "\r\n").getBytes(StandardCharsets.US_ASCII);
        this.poolSize = poolSize;
        this.idle = new LinkedBlockingDeque<>(poolSize);
        for (int i = 0; i < poolSize; i++) {
            idle.addLast(new Connection());
        }
    }

    @Override
    public int fetch() throws IOException, InterruptedException {
        Connection connection = idle.takeFirst();
        try {
            // A kept-alive socket can have been closed by the peer while idle; that failure says
            // nothing about the backend, so it earns one retry on a fresh socket.
            boolean reused = connection.isOpen();
            try {
                return connection.exchange();
            } catch (IOException e) {
                connection.close();
                if (!reused) {
                    throw e;
                }
                return connection.exchange();
            }
        } catch (IOException | RuntimeException e) {
            connection.close();
            throw e;
        } finally {
            idle.putFirst(connection);
        }
    }

    @Override
    public String describe() {
        return "jdk(java.net.Socket) pool=" + poolSize + " target=" + address.getHostString() + ":" + address.getPort();
    }

    @Override
    public void close() {
        Connection connection;
        while ((connection = idle.pollFirst()) != null) {
            connection.close();
        }
    }

    private final class Connection {

        private final byte[] buffer = new byte[BUFFER_BYTES];
        private Socket socket;
        private InputStream in;
        private OutputStream out;

        boolean isOpen() {
            return socket != null;
        }

        int exchange() throws IOException {
            if (socket == null) {
                open();
            }
            out.write(request);
            out.flush();
            return readResponse();
        }

        private void open() throws IOException {
            Socket s = new Socket();
            try {
                s.setTcpNoDelay(true);
                s.setSoTimeout(READ_TIMEOUT_MS);
                s.connect(address, CONNECT_TIMEOUT_MS);
                in = s.getInputStream();
                out = s.getOutputStream();
                socket = s;
            } catch (IOException e) {
                s.close();
                throw e;
            }
        }

        // Reads one response into the reusable buffer and returns its body length. Leaves the
        // connection open unless the peer asked to close it.
        private int readResponse() throws IOException {
            int filled = 0;
            int headerEnd = -1;
            while (headerEnd < 0) {
                if (filled == buffer.length) {
                    throw new IOException("response header exceeds " + buffer.length + " bytes");
                }
                int n = in.read(buffer, filled, buffer.length - filled);
                if (n < 0) {
                    throw new IOException("backend closed the connection before the response header");
                }
                int scanFrom = Math.max(0, filled - 3);
                filled += n;
                headerEnd = indexOfHeaderEnd(scanFrom, filled);
            }

            int status = parseStatus(headerEnd);
            int contentLength = -1;
            boolean closeAfter = false;
            int lineStart = indexOfLineEnd(0, headerEnd) + 2;
            while (lineStart < headerEnd) {
                int lineEnd = indexOfLineEnd(lineStart, headerEnd);
                if (startsWithIgnoreCase(lineStart, lineEnd, CONTENT_LENGTH)) {
                    contentLength = parseDecimal(lineStart + CONTENT_LENGTH.length, lineEnd);
                } else if (startsWithIgnoreCase(lineStart, lineEnd, CONNECTION_CLOSE)) {
                    closeAfter = true;
                }
                lineStart = lineEnd + 2;
            }
            if (contentLength < 0) {
                throw new IOException("backend response has no Content-Length");
            }

            int bodyStart = headerEnd + 4;
            int bodyRead = filled - bodyStart;
            if (bodyRead > contentLength) {
                throw new IOException("backend sent " + (bodyRead - contentLength) + " bytes past the response");
            }
            while (bodyRead < contentLength) {
                int n = in.read(buffer, 0, Math.min(buffer.length, contentLength - bodyRead));
                if (n < 0) {
                    throw new IOException("backend closed the connection inside the response body");
                }
                bodyRead += n;
            }
            if (closeAfter) {
                close();
            }
            if (status != HTTP_OK) {
                // Not an I/O failure: the exchange completed, so retrying it on a fresh socket
                // would only hide a backend that is refusing work.
                throw new IllegalStateException("backend answered " + status);
            }
            return contentLength;
        }

        private int indexOfHeaderEnd(int from, int to) {
            for (int i = from; i + 3 < to; i++) {
                if (buffer[i] == '\r' && buffer[i + 1] == '\n' && buffer[i + 2] == '\r' && buffer[i + 3] == '\n') {
                    return i;
                }
            }
            return -1;
        }

        // The last header line ends where the header block does, so reaching the limit ends it.
        private int indexOfLineEnd(int from, int limit) {
            for (int i = from; i < limit; i++) {
                if (buffer[i] == '\r' && buffer[i + 1] == '\n') {
                    return i;
                }
            }
            return limit;
        }

        // "HTTP/1.1 200 ..." — the status code is the three digits after the first space.
        private int parseStatus(int headerEnd) throws IOException {
            int space = 0;
            while (space < headerEnd && buffer[space] != ' ') {
                space++;
            }
            if (space + 4 > headerEnd) {
                throw new IOException("malformed status line");
            }
            return parseDecimal(space + 1, space + 4);
        }

        private boolean startsWithIgnoreCase(int from, int to, byte[] prefix) {
            if (to - from < prefix.length) {
                return false;
            }
            for (int i = 0; i < prefix.length; i++) {
                byte b = buffer[from + i];
                if (b >= 'A' && b <= 'Z') {
                    b = (byte) (b + ('a' - 'A'));
                }
                if (b != prefix[i]) {
                    return false;
                }
            }
            return true;
        }

        private int parseDecimal(int from, int to) throws IOException {
            int value = 0;
            boolean any = false;
            for (int i = from; i < to; i++) {
                byte b = buffer[i];
                if (b == ' ' || b == '\t') {
                    if (any) {
                        break;
                    }
                    continue;
                }
                if (b < '0' || b > '9') {
                    throw new IOException("malformed number in backend response");
                }
                value = Math.addExact(Math.multiplyExact(value, 10), b - '0');
                any = true;
            }
            if (!any) {
                throw new IOException("missing number in backend response");
            }
            return value;
        }

        void close() {
            Socket s = socket;
            socket = null;
            in = null;
            out = null;
            if (s != null) {
                try {
                    s.close();
                } catch (IOException _) {
                    // Closing a socket that failed carries no information the caller can act on.
                }
            }
        }
    }
}
