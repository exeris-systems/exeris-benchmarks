package eu.exeris.benchmarks.targets.springapp;

import java.util.Map;

import org.hibernate.boot.model.relational.ColumnOrderingStrategyLegacy;
import org.springframework.boot.autoconfigure.orm.jpa.HibernatePropertiesCustomizer;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;

@Configuration(proxyBeanMethods = false)
class HibernateColumnOrderingConfiguration {

    @Bean
    HibernatePropertiesCustomizer hibernateColumnOrderingStrategyCustomizer() {
        return (Map<String, Object> hibernateProperties) -> hibernateProperties.put(
            "hibernate.column_ordering_strategy",
            ColumnOrderingStrategyLegacy.INSTANCE
        );
    }
}