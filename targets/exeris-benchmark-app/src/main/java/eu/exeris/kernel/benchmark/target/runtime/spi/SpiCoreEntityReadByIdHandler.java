package eu.exeris.kernel.benchmark.target.runtime.spi;

import eu.exeris.kernel.benchmark.target.http.BenchmarkHttpHandler;
import eu.exeris.kernel.benchmark.target.http.BenchmarkRequestContext;
import eu.exeris.kernel.benchmark.target.http.BenchmarkResponse;

import javax.sql.DataSource;
import java.lang.reflect.InvocationTargetException;
import java.lang.reflect.Method;
import java.sql.Connection;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.sql.Timestamp;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.logging.Level;
import java.util.logging.Logger;

final class SpiCoreEntityReadByIdHandler implements BenchmarkHttpHandler {

    private static final Logger LOGGER = Logger.getLogger(SpiCoreEntityReadByIdHandler.class.getName());
    private static final AtomicBoolean SQL_EXCEPTION_LOGGED = new AtomicBoolean(false);
    private static final AtomicBoolean RUNTIME_EXCEPTION_LOGGED = new AtomicBoolean(false);
    private static final AtomicBoolean DATASOURCE_FAILURE_LOGGED = new AtomicBoolean(false);

    private static final Object DATASOURCE_LOCK = new Object();
    private static volatile DataSource dataSource;

    private static final String PROP_JDBC_URL = "exeris.persistence.jdbcUrl";
    private static final String PROP_USERNAME = "exeris.persistence.username";
    private static final String PROP_PASSWORD = "exeris.persistence.password";

    private static final String SQL_SELECT_BY_ID =
            "SELECT id, name, type, payload, created_at FROM entities WHERE id = ?";

    @Override
    public BenchmarkResponse handle(BenchmarkRequestContext request) {
        Long entityId = parseEntityId(request.path());
        if (entityId == null) {
            return SpiCoreJsonResponseSupport.jsonResponse(
                    400,
                    "{" +
                            "\"endpoint\":\"entity-read-by-id\"," +
                            "\"error\":\"invalid_entity_id\"" +
                            "}");
        }

        String jdbcUrl = System.getProperty(PROP_JDBC_URL);
        String username = defaultIfBlank(System.getProperty(PROP_USERNAME), "benchmark");
        String password = defaultIfBlank(System.getProperty(PROP_PASSWORD), "benchmark");
        if (isBlank(jdbcUrl)) {
            return SpiCoreJsonResponseSupport.jsonResponse(
                    500,
                    "{" +
                            "\"endpoint\":\"entity-read-by-id\"," +
                            "\"error\":\"db_config_missing\"" +
                            "}");
        }

        try (Connection connection = getOrCreateDataSource(jdbcUrl, username, password).getConnection();
             PreparedStatement statement = connection.prepareStatement(SQL_SELECT_BY_ID)) {
            statement.setLong(1, entityId);
            try (ResultSet resultSet = statement.executeQuery()) {
                if (!resultSet.next()) {
                    return SpiCoreJsonResponseSupport.jsonResponse(
                            404,
                            "{" +
                                    "\"endpoint\":\"entity-read-by-id\"," +
                                    "\"id\":" + entityId + "," +
                                    "\"error\":\"entity_not_found\"" +
                                    "}");
                }

                long id = resultSet.getLong("id");
                String name = resultSet.getString("name");
                String type = resultSet.getString("type");
                String payload = resultSet.getString("payload");
                Timestamp createdAt = resultSet.getTimestamp("created_at");
                String createdAtValue = createdAt == null ? "" : createdAt.toInstant().toString();

                String body = "{" +
                        "\"endpoint\":\"entity-read-by-id\"," +
                        "\"id\":" + id + "," +
                        "\"name\":\"" + escapeJson(name) + "\"," +
                        "\"type\":\"" + escapeJson(type) + "\"," +
                        "\"payload\":\"" + escapeJson(payload) + "\"," +
                        "\"createdAt\":\"" + escapeJson(createdAtValue) + "\"" +
                        "}";
                return SpiCoreJsonResponseSupport.jsonResponse(200, body);
            }
        } catch (SQLException ex) {
            logDataSourceFailureOnce("acquire/query", ex);
            if (SQL_EXCEPTION_LOGGED.compareAndSet(false, true)) {
                LOGGER.log(
                        Level.WARNING,
                        "entity-read-by-id SQL failure (sqlState={0}, message={1})",
                        new Object[]{String.valueOf(ex.getSQLState()), String.valueOf(ex.getMessage())});
            }
            return SpiCoreJsonResponseSupport.jsonResponse(
                    500,
                    "{" +
                            "\"endpoint\":\"entity-read-by-id\"," +
                            "\"error\":\"db_query_failed\"" +
                            "}");
        } catch (RuntimeException | Error ex) {
            logDataSourceFailureOnce("runtime", ex);
            if (RUNTIME_EXCEPTION_LOGGED.compareAndSet(false, true)) {
                LOGGER.log(
                        Level.WARNING,
                        "entity-read-by-id runtime failure (type={0}, message={1})",
                        new Object[]{ex.getClass().getName(), String.valueOf(ex.getMessage())});
            }
            return SpiCoreJsonResponseSupport.jsonResponse(
                    500,
                    "{" +
                            "\"endpoint\":\"entity-read-by-id\"," +
                            "\"error\":\"db_runtime_failed\"" +
                            "}");
        }
    }

    private static DataSource getOrCreateDataSource(String jdbcUrl, String username, String password) {
        DataSource current = dataSource;
        if (current != null) {
            return current;
        }

        synchronized (DATASOURCE_LOCK) {
            current = dataSource;
            if (current != null) {
                return current;
            }
            try {
                current = createHikariDataSource(jdbcUrl, username, password);
                dataSource = current;
                return current;
            } catch (RuntimeException ex) {
                logDataSourceFailureOnce("init", ex);
                throw ex;
            }
        }
    }

    private static DataSource createHikariDataSource(String jdbcUrl, String username, String password) {
        try {
            Class<?> configClass = Class.forName("com.zaxxer.hikari.HikariConfig");
            Object config = configClass.getConstructor().newInstance();
            invokeConfig(configClass, config, "setJdbcUrl", String.class, jdbcUrl);
            invokeConfig(configClass, config, "setUsername", String.class, username);
            invokeConfig(configClass, config, "setPassword", String.class, password);
            invokeConfig(configClass, config, "setMaximumPoolSize", int.class, 32);
            invokeConfig(configClass, config, "setMinimumIdle", int.class, 4);
            invokeConfig(configClass, config, "setConnectionTimeout", long.class, 3000L);
            invokeConfig(configClass, config, "setValidationTimeout", long.class, 1000L);
            invokeConfig(configClass, config, "setInitializationFailTimeout", long.class, 5000L);
            invokeConfig(configClass, config, "setPoolName", String.class, "entity-read-by-id-pool");

            Class<?> dataSourceClass = Class.forName("com.zaxxer.hikari.HikariDataSource");
            Object ds = dataSourceClass.getConstructor(configClass).newInstance(config);
            if (!(ds instanceof DataSource casted)) {
                throw new IllegalStateException("HikariDataSource is not a javax.sql.DataSource");
            }
            return casted;
        } catch (ClassNotFoundException ex) {
            throw new IllegalStateException("HikariCP not available on runtime classpath", ex);
        } catch (InvocationTargetException ex) {
            Throwable cause = ex.getCause() == null ? ex : ex.getCause();
            throw new IllegalStateException("Failed to initialize HikariDataSource: " + cause.getMessage(), cause);
        } catch (ReflectiveOperationException ex) {
            throw new IllegalStateException("Failed to configure HikariDataSource", ex);
        }
    }

    private static void invokeConfig(
            Class<?> configClass,
            Object config,
            String methodName,
            Class<?> parameterType,
            Object value
    ) throws ReflectiveOperationException {
        Method method = configClass.getMethod(methodName, parameterType);
        method.invoke(config, value);
    }

    private static Long parseEntityId(String path) {
        if (path == null) {
            return null;
        }
        int lastSlash = path.lastIndexOf('/');
        if (lastSlash < 0 || lastSlash + 1 >= path.length()) {
            return null;
        }
        String idSegment = path.substring(lastSlash + 1);
        try {
            return Long.parseLong(idSegment);
        } catch (NumberFormatException ex) {
            return null;
        }
    }

    private static boolean isBlank(String value) {
        return value == null || value.trim().isEmpty();
    }

    private static String defaultIfBlank(String value, String fallback) {
        return isBlank(value) ? fallback : value;
    }

    private static void logDataSourceFailureOnce(String stage, Throwable ex) {
        if (DATASOURCE_FAILURE_LOGGED.compareAndSet(false, true)) {
            LOGGER.log(
                    Level.WARNING,
                    "entity-read-by-id datasource failure (stage={0}, type={1}, message={2})",
                    new Object[]{stage, ex.getClass().getName(), String.valueOf(ex.getMessage())});
        }
    }

    private static String escapeJson(String value) {
        if (value == null) {
            return "";
        }
        StringBuilder escaped = new StringBuilder(value.length() + 16);
        for (int i = 0; i < value.length(); i++) {
            char c = value.charAt(i);
            switch (c) {
                case '"' -> escaped.append("\\\"");
                case '\\' -> escaped.append("\\\\");
                case '\b' -> escaped.append("\\b");
                case '\f' -> escaped.append("\\f");
                case '\n' -> escaped.append("\\n");
                case '\r' -> escaped.append("\\r");
                case '\t' -> escaped.append("\\t");
                default -> {
                    if (c < 0x20) {
                        escaped.append("\\u");
                        String hex = Integer.toHexString(c);
                        for (int pad = hex.length(); pad < 4; pad++) {
                            escaped.append('0');
                        }
                        escaped.append(hex);
                    } else {
                        escaped.append(c);
                    }
                }
            }
        }
        return escaped.toString();
    }
}
