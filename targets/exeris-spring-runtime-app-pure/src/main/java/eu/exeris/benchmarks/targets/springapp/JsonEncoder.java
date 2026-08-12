package eu.exeris.benchmarks.targets.springapp;

import tools.jackson.databind.ObjectMapper;
import org.springframework.stereotype.Component;

/**
 * Response encoding for the pure-mode handlers.
 *
 * <p>In compatibility mode Spring MVC's message converters do this via
 * {@code MappingJackson2HttpMessageConverter}. In pure mode there is no MVC layer, so the
 * handlers encode explicitly — but through the SAME Jackson databind line the compat arm
 * uses, injected as Spring's autoconfigured {@link ObjectMapper}. Encoding must not become a
 * second variable on the Pure-vs-Compat axis: the axis is the dispatch path.
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
