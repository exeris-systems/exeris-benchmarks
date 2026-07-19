package eu.exeris.benchmarks.targets.blackbird;

import eu.exeris.kernel.community.json.JsonMapperCustomizer;
import eu.exeris.kernel.community.json.JsonMapperScope;

import tools.jackson.databind.json.JsonMapper;
import tools.jackson.module.blackbird.BlackbirdModule;

/**
 * ADR-052 {@link JsonMapperCustomizer} (discovered via {@link java.util.ServiceLoader}) that adds the
 * Jackson-3 Blackbird module to every Community JSON scope.
 *
 * <p>Purpose: the 2026-07-19 CPU profile showed the exeris-community response-encode hot path spends
 * ~20% of CPU in {@code Invokers$Holder.invokeExact_MT}, i.e. Jackson 3's default {@code MethodHandle}
 * property accessor ({@code BeanPropertyWriter.get}) going megamorphic across property/types so C2
 * cannot inline it. Blackbird emits a dedicated {@code invokedynamic} accessor per property, which is
 * monomorphic and inlinable — the classic remedy (ADR-052 explicitly leaves whether it wins to an
 * experiment; this is that experiment).
 *
 * <p>This customizer's mere presence on the classpath is the toggle: the {@code exeris-blackbird}
 * benchmark target launches {@code app.jar} PLUS this uber-jar, so ServiceLoader finds it and Blackbird
 * applies; {@code exeris-default} launches the pristine app jar alone, so no customizer applies and the
 * mapper is byte-identical to the pre-seam default. Both arms run the same 0.10.1 app jar → the only
 * difference measured is the Blackbird accessor path.
 *
 * <p>Applied once per scope at bootstrap (never on the request path), per the seam contract.
 */
public final class BenchmarkBlackbirdJsonMapperCustomizer implements JsonMapperCustomizer {

    @Override
    public void customize(JsonMapperScope scope, JsonMapper.Builder builder) {
        // appliesTo defaults to every scope; HTTP_RESPONSE_ENCODE (exchange.respond) is the only hot
        // one for entity-read-by-id, so the measured effect isolates the response-encode accessor path.
        builder.addModule(new BlackbirdModule());
    }
}
