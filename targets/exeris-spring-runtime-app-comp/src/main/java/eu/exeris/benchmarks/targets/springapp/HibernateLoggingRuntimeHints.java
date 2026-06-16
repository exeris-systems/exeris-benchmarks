package eu.exeris.benchmarks.targets.springapp;

import org.springframework.aot.hint.MemberCategory;
import org.springframework.aot.hint.RuntimeHints;
import org.springframework.aot.hint.RuntimeHintsRegistrar;

final class HibernateLoggingRuntimeHints implements RuntimeHintsRegistrar {

    private static final String[] LOGGER_IMPLEMENTATIONS = {
        "org.hibernate.action.internal.ActionLogging_$logger",
        "org.hibernate.boot.BootLogging_$logger",
        "org.hibernate.boot.archive.scan.internal.ScannerLogger_$logger",
        "org.hibernate.boot.beanvalidation.BeanValidationLogger_$logger",
        "org.hibernate.boot.jaxb.JaxbLogger_$logger",
        "org.hibernate.cache.spi.SecondLevelCacheLogger_$logger",
        "org.hibernate.context.internal.CurrentSessionLogging_$logger",
        "org.hibernate.dialect.DialectLogging_$logger",
        "org.hibernate.engine.internal.SessionMetricsLogger_$logger",
        "org.hibernate.engine.internal.VersionLogger_$logger",
        "org.hibernate.engine.jdbc.JdbcLogging_$logger",
        "org.hibernate.engine.jdbc.batch.JdbcBatchLogging_$logger",
        "org.hibernate.engine.jdbc.spi.SQLExceptionLogging_$logger",
        "org.hibernate.event.internal.EventListenerLogging_$logger",
        "org.hibernate.internal.CoreMessageLogger_$logger",
        "org.hibernate.internal.SessionFactoryLogging_$logger",
        "org.hibernate.internal.SessionFactoryRegistryMessageLogger_$logger",
        "org.hibernate.internal.SessionLogging_$logger",
        "org.hibernate.internal.log.ConnectionAccessLogger_$logger",
        "org.hibernate.internal.log.ConnectionInfoLogger_$logger",
        "org.hibernate.internal.log.DeprecationLogger_$logger",
        "org.hibernate.internal.log.IncubationLogger_$logger",
        "org.hibernate.internal.log.StatisticsLogger_$logger",
        "org.hibernate.internal.log.UrlMessageBundle_$logger",
        "org.hibernate.jpa.internal.JpaLogger_$logger",
        "org.hibernate.metamodel.mapping.MappingModelCreationLogging_$logger",
        "org.hibernate.query.QueryLogging_$logger",
        "org.hibernate.query.hql.HqlLogging_$logger",
        "org.hibernate.resource.beans.internal.BeansMessageLogger_$logger",
        "org.hibernate.resource.jdbc.internal.LogicalConnectionLogging_$logger",
        "org.hibernate.resource.jdbc.internal.ResourceRegistryLogger_$logger",
        "org.hibernate.resource.transaction.backend.jta.internal.JtaLogging_$logger",
        "org.hibernate.resource.transaction.internal.SynchronizationLogging_$logger",
        "org.hibernate.service.internal.ServiceLogger_$logger",
        "org.hibernate.sql.exec.SqlExecLogger_$logger",
        "org.hibernate.sql.model.ModelMutationLogging_$logger",
        "org.hibernate.sql.results.LoadingLogger_$logger",
        "org.hibernate.sql.results.ResultsLogger_$logger"
    };

    private static final String[] POSTGRESQL_DYNAMIC_TYPES = {
        "org.postgresql.util.PGobject",
        "org.hibernate.dialect.type.PostgreSQLStructPGObjectJdbcType",
        "org.hibernate.dialect.type.PostgreSQLIntervalSecondJdbcType",
        "org.hibernate.dialect.type.PostgreSQLInetJdbcType",
        "org.hibernate.dialect.type.PostgreSQLJsonPGObjectJsonType",
        "org.hibernate.dialect.type.PostgreSQLJsonPGObjectJsonbType",
        "org.hibernate.dialect.type.PostgreSQLJsonArrayPGObjectJsonJdbcTypeConstructor",
        "org.hibernate.dialect.type.PostgreSQLJsonArrayPGObjectJsonbJdbcTypeConstructor"
    };

    @Override
    public void registerHints(RuntimeHints hints, ClassLoader classLoader) {
        for (String className : LOGGER_IMPLEMENTATIONS) {
            hints.reflection().registerTypeIfPresent(
                classLoader,
                className,
                MemberCategory.INVOKE_DECLARED_CONSTRUCTORS
            );
        }

        for (String className : POSTGRESQL_DYNAMIC_TYPES) {
            hints.reflection().registerTypeIfPresent(
                classLoader,
                className,
                MemberCategory.INVOKE_PUBLIC_CONSTRUCTORS
            );
        }

        hints.reflection().registerTypeIfPresent(
            classLoader,
            "org.hibernate.boot.models.annotations.internal.CacheAnnotation",
            MemberCategory.INVOKE_DECLARED_CONSTRUCTORS
        );
    }
}