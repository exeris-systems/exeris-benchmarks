package eu.exeris.benchmarks.targets.springapp;

import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import tools.jackson.databind.ObjectMapper;
import tools.jackson.databind.json.JsonMapper;

/**
 * Supplies the {@link ObjectMapper} that {@link JsonEncoder} writes responses with.
 *
 * <p>Spring Boot's {@code JacksonAutoConfiguration} does not run here. This arm sets
 * {@code spring.main.web-application-type=none} and carries no web or JSON starter — the mapper
 * used to arrive transitively with {@code spring-boot-starter-data-jpa} / {@code -jdbc}, the same
 * modules that were removed to cut the persistence axis. Without them the context failed with
 * "Parameter 0 of constructor in JsonEncoder required a bean of type ObjectMapper" (2026-08-06).
 *
 * <p>This is the third thing this arm silently lost to that removal, after logback and
 * {@code PersistenceEngineProvider}. All three shared one shape: a dependency nobody declared,
 * because a starter had always been declaring it. Anything this arm needs is now declared here
 * explicitly rather than inherited.
 *
 * <p>Declaring the mapper is also the better benchmark posture. An autoconfigured mapper carries
 * whatever defaults the Boot version of the day applies; a constructed one pins serialisation
 * configuration the same way the kernel line and the Boot line are pinned, so it cannot drift
 * under the measurement.
 *
 * <p><b>Jackson 3</b> ({@code tools.jackson}), matching {@code exeris-community-app} and the
 * Tomcat arm on Boot 4.1.0 — one serialisation line across the whole ladder. Built with defaults
 * on purpose: any customisation here would be a per-request difference from the arms this one is
 * compared against.
 */
@Configuration
public class JsonConfiguration {

    @Bean
    public ObjectMapper objectMapper() {
        return JsonMapper.builder().build();
    }
}
