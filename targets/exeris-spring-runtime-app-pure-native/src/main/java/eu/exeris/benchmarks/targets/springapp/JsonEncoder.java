package eu.exeris.benchmarks.targets.springapp;

import org.springframework.stereotype.Component;
import tools.jackson.databind.ObjectMapper;

/**
 * Response encoding for the pure-mode handlers.
 *
 * <p>In compatibility mode Spring MVC's message converters do this via a Jackson message
 * converter. In pure mode there is no MVC layer, so the handlers encode explicitly — but through
 * the SAME Jackson line the rest of the stack uses, injected as Spring's autoconfigured
 * {@link ObjectMapper}. Encoding must not become a second variable on the axis under test.
 *
 * <p><b>Jackson 3 ({@code tools.jackson.databind}), not Jackson 2.</b> Spring Boot 4 moved the
 * JSON stack: {@code JacksonAutoConfiguration} no longer contributes a
 * {@code com.fasterxml.jackson.databind.ObjectMapper}, so the Boot 3 form of this class failed
 * the context outright ("Parameter 0 of constructor in JsonEncoder required a bean of type
 * com.fasterxml.jackson.databind.ObjectMapper", 2026-08-06).
 *
 * <p>Two things follow, and both are wanted rather than merely tolerated:
 *
 * <ul>
 *   <li>{@code exeris-community-app} already encodes with Jackson 3. Before this change the
 *       pure-native-vs-community pair carried a Jackson 2 / Jackson 3 difference in the response
 *       path of every request; it no longer does.</li>
 *   <li>All four arms now sit on one Jackson line, because the Tomcat arm gets Jackson 3 from
 *       Boot 4.1.0 too.</li>
 * </ul>
 *
 * <p><b>Fence.</b> Serialisation library is in the per-request path and weighs most on the light
 * contract. No number measured before this change transfers across it.
 *
 * <p>Jackson 3 throws unchecked {@code JacksonException} rather than the checked
 * {@code JsonProcessingException}, so the wrapper below no longer exists to satisfy the compiler
 * — it is kept only so an encoding failure surfaces with this class named in the trace.
 */
@Component
public class JsonEncoder {

    private final ObjectMapper objectMapper;

    public JsonEncoder(ObjectMapper objectMapper) {
        this.objectMapper = objectMapper;
    }

    public byte[] encode(Object value) {
        try {
            return objectMapper.writeValueAsBytes(value);
        } catch (RuntimeException exception) {
            throw new IllegalStateException("Failed to encode response body", exception);
        }
    }
}
